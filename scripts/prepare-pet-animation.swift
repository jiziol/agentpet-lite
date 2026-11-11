// Native macOS validation/thumbnail generation for the pinned transparent MOV pack.
import Foundation
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift prepare-pet-animation.swift MOV_DIRECTORY OUTPUT_JSON")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let fm = FileManager.default
let movies = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "mov" && !$0.lastPathComponent.hasPrefix("._") }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
let posterDir = directory.deletingLastPathComponent().appendingPathComponent("posters")
try fm.createDirectory(at: posterDir, withIntermediateDirectories: true)
var rows: [[String: Any]] = []

for movie in movies {
    try autoreleasepool {
        let asset = AVURLAsset(url: movie)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "PetAnimation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video: \(movie.lastPathComponent)"])
        }
        let duration = asset.duration.seconds
        let dimensions = track.naturalSize.applying(track.preferredTransform)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        var transparent = 0, visible = 0
        var poster: CGImage?
        for seconds in [min(0.3, duration / 3), duration / 2, max(0, duration - 0.3)] {
            let frame = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            let w = frame.width, h = frame.height
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let counts: (Int, Int) = pixels.withUnsafeMutableBytes { bytes in
                let ctx = CGContext(data: bytes.baseAddress, width: w, height: h,
                                    bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
                let p = bytes.bindMemory(to: UInt8.self)
                var clear = 0, solid = 0
                for i in stride(from: 3, to: p.count, by: 4) {
                    if p[i] < 16 { clear += 1 }
                    if p[i] > 240 { solid += 1 }
                }
                return (clear, solid)
            }
            transparent = max(transparent, counts.0)
            visible = max(visible, counts.1)
            if poster == nil && counts.1 > 0 { poster = frame }
        }
        guard duration.isFinite, duration > 0, transparent > 0, visible > 0, let poster else {
            throw NSError(domain: "PetAnimation", code: 2, userInfo: [NSLocalizedDescriptionKey: "No visible alpha decode: \(movie.lastPathComponent)"])
        }
        let name = movie.deletingPathExtension().lastPathComponent
        let posterURL = posterDir.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(posterURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "PetAnimation", code: 3)
        }
        CGImageDestinationAddImage(destination, poster, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PetAnimation", code: 4) }
        rows.append(["name": name, "file": movie.lastPathComponent, "poster": name + ".png",
                     "duration": duration, "width": Int(abs(dimensions.width)), "height": Int(abs(dimensions.height)),
                     "nativeAlphaCharacteristic": track.hasMediaCharacteristic(.containsAlphaChannel),
                     "transparentPixels": transparent, "visiblePixels": visible])
    }
}
let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output, options: .atomic)
print("PASS: \(rows.count) movies, 3 native alpha samples each; thumbnails generated")
