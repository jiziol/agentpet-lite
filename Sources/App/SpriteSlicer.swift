import AppKit

/// A pet pack backed by a spritesheet (pet.json + image), e.g. the Codex/petdex
/// pet format. Sliced at load time into clips (one per sheet row); each clip is
/// a separate animation the user can bind to a state.
struct ImagePetPack: Identifiable {
    let id: String
    let displayName: String
    let description: String?
    let clips: [[NSImage]]
    let directory: URL
    var videoClips: [PetVideoClip] = []
    var animationGroups: [String: [String]] = [:]
    var animationIssues: [String] = []
    var animationRevision: UInt64 = 0
    /// Optional pack-owned static edge-peek art (`edge-peek.png`).
    var peekAsset: EdgePeekAsset? = nil

    /// A shared edge sticker is presentation only, never a native animation.
    var effectivePeekAsset: EdgePeekAsset? { peekAsset ?? EdgePeekAsset.bundledFallback }

    var clipCount: Int { clips.count + videoClips.count }

    var animationIDs: [String] {
        clips.indices.map { "sheet:\($0)" } + videoClips.map(\.id)
    }

    /// No semantic claim is made about sprite row numbers. Unmapped packs
    /// share their own first native action across all nine application uses.
    var nativeDefaultID: String? {
        clips.isEmpty ? videoClips.first(where: { $0.source == .native })?.id : "sheet:0"
    }

    func nativeFallbackID(for key: String) -> String? {
        let candidates = candidateIDs(for: key)
        if let preferred = nativeDefaultID, candidates.contains(preferred) { return preferred }
        return candidates.first { $0.hasPrefix("sheet:") || video(for: $0)?.source == .native }
    }

    func candidateIDs(for key: String) -> [String] {
        let available = Set(animationIDs)
        if let explicit = animationGroups[key] {
            return explicit.filter { available.contains($0) }
        }
        // A native purpose map is already curated membership. Do not inject
        // every old sheet row into it. Stored valid choices are preserved by
        // the bindings store and merged when membership is first persisted.
        let mapped = videoClips.filter { $0.source == .native && $0.purposes.contains(key) }.map(\.id)
        if !mapped.isEmpty { return mapped }
        let sheets = clips.indices.map { "sheet:\($0)" }
        let videos = videoClips.filter { $0.source == .native && ($0.purposes.isEmpty || $0.purposes.contains(key)) }.map(\.id)
        return sheets + videos
    }

    mutating func loadAnimations() {
        let native = PetAnimationCatalog.loadResult(directory: directory)
        let imported = PetAnimationLibrary.load(directory: directory, nativeIDs: Set(native.clips.map(\.id)))
        videoClips = native.clips + imported.clips.prefix(max(0, PetAnimationLimits.clips - native.clips.count))
        animationGroups = imported.groups
        animationIssues = native.issues + imported.issues
        if native.clips.count + imported.clips.count > PetAnimationLimits.clips {
            animationIssues.append("视频总数超过512上限，超额自定义项未加载；原始文件和清单保留。")
        }
    }

    func clipID(at index: Int) -> String {
        guard !animationIDs.isEmpty else { return "sheet:0" }
        return animationIDs[min(max(index, 0), max(clipCount - 1, 0))]
    }

    func animationName(at index: Int) -> String {
        if index < clips.count { return "原精灵片段 \(index + 1)" }
        let video = videoClips[index - clips.count]
        return video.displayName ?? video.name
    }

    func category(at index: Int) -> String {
        index < clips.count ? "原精灵片段" : videoClips[index - clips.count].category
    }

    func index(for id: String) -> Int? { animationIDs.firstIndex(of: id) }
    func video(for id: String) -> PetVideoClip? { videoClips.first { $0.id == id } }

    func clip(_ index: Int) -> [NSImage] {
        if index >= clips.count, videoClips.indices.contains(index - clips.count) {
            return videoClips[index - clips.count].poster.map { [$0] } ?? []
        }
        guard !clips.isEmpty else { return [] }
        return clips[min(max(index, 0), clips.count - 1)]
    }
}

private struct PetManifest: Decodable {
    enum Layout: String, Decodable { case single }
    let id: String
    let displayName: String
    let description: String?
    let spritesheetPath: String
    /// A poster can be a complete fallback frame, including detached details.
    /// Missing layout keeps the existing transparent-gutter grid format.
    let spritesheetLayout: Layout?
}

/// Loads a spritesheet pet pack and slices its frames by detecting the
/// transparent gutters between cells, so no grid metadata is required.
enum SpriteSlicer {
    /// Reads only the pack id from a directory's manifest, without slicing the
    /// spritesheet. Lets the store pick the prioritised pack to load first.
    static func manifestID(directory: URL) -> String? {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PetManifest.self, from: data)
        else { return nil }
        return manifest.id
    }

    static func loadPack(directory: URL, includeAnimations: Bool = true) -> ImagePetPack? {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PetManifest.self, from: data)
        else { return nil }

        guard let sheetURL = PetAnimationCatalog.localFile(manifest.spritesheetPath, directory: directory) else {
            NSLog("AgentPet: pet pack native fallback path is missing or unsafe: %@", directory.lastPathComponent)
            return nil
        }
        guard let nsImage = NSImage(contentsOf: sheetURL) else {
            NSLog("AgentPet: pet pack has no decodable native fallback: %@", directory.lastPathComponent)
            return nil
        }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }

        let sliced = slice(cg)
        guard !sliced.isEmpty else {
            NSLog("AgentPet: pet pack has no visible native fallback: %@", directory.lastPathComponent)
            return nil
        }
        let clips = manifest.spritesheetLayout == .single ? [[nsImage]] : sliced.map { row in
            row.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
        guard !clips.isEmpty else { return nil }
        var pack = ImagePetPack(id: manifest.id, displayName: manifest.displayName,
                            description: manifest.description, clips: clips, directory: directory,
                            peekAsset: EdgePeekAsset.load(directory: directory))
        if includeAnimations { pack.loadAnimations() }
        return pack
    }

    /// Slices a spritesheet into clips (one per sheet row) using alpha gutter
    /// detection, so no grid metadata is required. Columns are detected within
    /// each row, so ragged sheets (rows with different frame counts or unaligned
    /// columns, e.g. AI-generated sheets) slice correctly. Uniform grids are
    /// unaffected: every row finds the same columns.
    static func slice(_ image: CGImage, alphaThreshold: UInt8 = 16) -> [[CGImage]] {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let data = pixelData(image, width: w, height: h) else { return [] }

        var rowHas = [Bool](repeating: false, count: h)
        data.withUnsafeBufferPointer { buf in
            for y in 0..<h {
                let rowStart = y * w * 4
                for x in 0..<w where buf[rowStart + x * 4 + 3] > alphaThreshold {
                    rowHas[y] = true
                    break
                }
            }
        }
        let rowBands = segments(rowHas)
        guard !rowBands.isEmpty else { return [] }

        var clips: [[CGImage]] = []
        data.withUnsafeBufferPointer { buf in
            for row in rowBands {
                var colHas = [Bool](repeating: false, count: w)
                for y in row.lower..<row.upper {
                    let rowStart = y * w * 4
                    for x in 0..<w where buf[rowStart + x * 4 + 3] > alphaThreshold {
                        colHas[x] = true
                    }
                }
                var clip: [CGImage] = []
                for col in segments(colHas) {
                    let rect = CGRect(x: col.lower, y: row.lower,
                                      width: col.upper - col.lower, height: row.upper - row.lower)
                    guard let cropped = image.cropping(to: rect) else { continue }
                    let fw = Int(rect.width), fh = Int(rect.height)
                    let space = CGColorSpaceCreateDeviceRGB()
                    let info = CGImageAlphaInfo.premultipliedLast.rawValue
                    guard let ctx = CGContext(data: nil, width: fw, height: fh,
                                             bitsPerComponent: 8, bytesPerRow: fw * 4,
                                             space: space, bitmapInfo: info) else { continue }
                    ctx.draw(cropped, in: CGRect(origin: .zero, size: CGSize(width: fw, height: fh)))
                    guard let frame = ctx.makeImage() else { continue }
                    clip.append(frame)
                }
                if !clip.isEmpty { clips.append(clip) }
            }
        }
        return clips
    }

    private static func pixelData(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = data.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(data: ptr.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: info)
        }) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private static func segments(_ occupancy: [Bool]) -> [(lower: Int, upper: Int)] {
        var result: [(Int, Int)] = []
        var start: Int?
        for (i, filled) in occupancy.enumerated() {
            if filled, start == nil { start = i }
            else if !filled, let s = start { result.append((s, i)); start = nil }
        }
        if let s = start { result.append((s, occupancy.count)) }
        return result
    }
}
