import AppKit
import AVFoundation
import CoreImage

/// Shared limits for installed catalogs and both user import entry points.
enum PetAnimationLimits {
    static let manifestBytes = 1_048_576
    static let clips = 512
    static let movieBytes = 256 * 1_024 * 1_024
    static let duration = 600.0
    static let dimension = 4096
    static let decodedPixels: Int64 = 2_000_000_000
    static let frames = 36_000
    static let decodeSeconds = 30.0
}

struct PetAnimationMediaInfo: Sendable {
    let duration: Double
    let width: Int
    let height: Int
    let posterPNG: Data
}

struct PetAnimationImportError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
    static let guidance = "请从含透明背景的源工程导出 QuickTime MOV / HEVC with Alpha（保留 Alpha）；普通 HEVC、H.264 或改扩展名不会生成透明通道。应用不会自动转码。"
}

/// Runs off the UI thread during imports. Decode the entire stream, not just a
/// container label or thumbnail, with bounded time/work and one frame in memory.
enum PetAnimationMedia {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: PetAnimationMediaInfo] = [:]
    }
    private static let cache = Cache()

    static func inspect(_ url: URL) throws -> PetAnimationMediaInfo {
        func reject(_ reason: String) -> PetAnimationImportError { .init(reason: reason) }
        guard url.pathExtension.lowercased() == "mov" else { throw reject("仅支持 HEVC with Alpha 的 .mov 文件。") }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard attributes.isRegularFile == true, let bytes = attributes.fileSize,
              bytes > 0, bytes <= PetAnimationLimits.movieBytes else { throw reject("文件必须为普通文件，大小须为 1 字节至 256 MiB。") }
        let stamp = "\(url.resolvingSymlinksInPath().path)|\(bytes)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing: attributes.fileResourceIdentifier))"
        cache.lock.lock()
        let cached = cache.values[stamp]
        cache.lock.unlock()
        if let cached { return cached }
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .video)
        guard asset.isPlayable, tracks.count == 1, let track = tracks.first else { throw reject("媒体损坏、不可播放或不是单视频轨文件。") }
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0, duration <= PetAnimationLimits.duration else { throw reject("动画时长须大于 0 且不超过 600 秒。") }
        guard let rawFormat = track.formatDescriptions.first else { throw reject("无法读取视频编码。") }
        let format = rawFormat as! CMFormatDescription
        let codec = CMFormatDescriptionGetMediaSubType(format)
        guard codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_HEVCWithAlpha else { throw reject("实际视频编码不是 HEVC with Alpha。") }
        let alpha = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool == true
        guard alpha || track.hasMediaCharacteristic(.containsAlphaChannel) || codec == kCMVideoCodecType_HEVCWithAlpha else { throw reject("视频不含 Alpha 透明通道。") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let width = Int(dimensions.width), height = Int(dimensions.height)
        guard (1...PetAnimationLimits.dimension).contains(width), (1...PetAnimationLimits.dimension).contains(height) else { throw reject("宽高须在 1–4096 像素内。") }
        let transform = track.preferredTransform
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy({ $0.isFinite }) else { throw reject("视频显示变换无效。") }
        let displaySize = CGRect(x: 0, y: 0, width: width, height: height).applying(transform).size
        guard displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width >= 1, displaySize.height >= 1,
              displaySize.width <= CGFloat(PetAnimationLimits.dimension), displaySize.height <= CGFloat(PetAnimationLimits.dimension) else { throw reject("视频显示尺寸须在 1–4096 像素内。") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw reject("无法创建透明视频解码器。") }
        reader.add(output)
        guard reader.startReading() else { throw reject("无法解码视频。") }
        let timeout = DispatchWorkItem { reader.cancelReading() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + PetAnimationLimits.decodeSeconds, execute: timeout)
        defer { timeout.cancel(); reader.cancelReading() }
        var count = 0
        var pixels: Int64 = 0
        var transparent = false
        var poster: Data?
        let started = Date()
        while reader.status == .reading {
            let found: Bool = try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw reject("解码未输出有效图像。") }
                count += 1
                pixels += Int64(CVPixelBufferGetWidth(buffer)) * Int64(CVPixelBufferGetHeight(buffer))
                guard count <= PetAnimationLimits.frames, pixels <= PetAnimationLimits.decodedPixels,
                      Date().timeIntervalSince(started) <= PetAnimationLimits.decodeSeconds else { throw reject("视频超出解码资源限制（36000 帧、20 亿像素或 30 秒处理时间）。") }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                var visible = false
                if (!transparent || poster == nil), let base = CVPixelBufferGetBaseAddress(buffer) {
                    let pointer = base.assumingMemoryBound(to: UInt8.self)
                    for y in 0..<CVPixelBufferGetHeight(buffer) {
                        for x in 0..<CVPixelBufferGetWidth(buffer) {
                            let a = pointer[y * CVPixelBufferGetBytesPerRow(buffer) + x * 4 + 3]
                            if a < 255 { transparent = true }
                            if a > 16 { visible = true }
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                if poster == nil, visible {
                    var image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                    let scale = min(1, 320 / max(image.extent.width, image.extent.height))
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    if let cg = CIContext().createCGImage(image, from: image.extent) {
                        poster = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                    }
                }
                return true
            }
            if !found { break }
        }
        guard reader.status == .completed, count > 0 else { throw reject("视频未能完整解码（损坏、不支持或处理超时）。") }
        guard transparent else { throw reject("解码后没有透明像素；请导出保留透明背景的 HEVC with Alpha。") }
        guard let poster else { throw reject("动画没有可见内容，无法生成海报。") }
        let result = PetAnimationMediaInfo(duration: duration, width: Int(displaySize.width), height: Int(displaySize.height), posterPNG: poster)
        cache.lock.lock()
        if cache.values.count >= PetAnimationLimits.clips { cache.values.removeAll() }
        cache.values[stamp] = result
        cache.lock.unlock()
        return result
    }
}
