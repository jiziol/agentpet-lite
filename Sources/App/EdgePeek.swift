import AppKit
import CoreGraphics
import AgentPetCore

/// A static edge-peek asset. The image is already cropped to its non-transparent
/// content bounds, so placement uses the character rather than the source
/// canvas. Packs without their own art use the bundled default edge sticker.
struct EdgePeekAsset {
    /// Content-cropped image (top-left origin, alpha preserved).
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let sourceName: String

    var contentSize: CGSize {
        CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
    }

    /// One raster/layout contract for the static view and every transition.
    /// Trim the inner side before mirroring, preserving the outer/right seam.
    func presentationImage(size: CGSize, side: PetEdgeSide, cropsInnerSide: Bool) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let width = cropsInnerSide
            ? min(CGFloat(image.width), CGFloat(image.height) * size.width / size.height)
            : CGFloat(image.width)
        guard let visible = image.cropping(to: CGRect(x: CGFloat(image.width) - width,
                y: 0, width: width, height: CGFloat(image.height))) else { return nil }
        return PetEdgeSnapshotter.orientedPeek(visible, side: side)
    }

    /// Shared presentation-only fallback. Never copied into a user's pet pack
    /// or added to its animation groups; dragging out restores that pet's body.
    static let bundledFallback: EdgePeekAsset? = {
        guard let directory = BundledDefaultPet.resourceDirectory else { return nil }
        return load(directory: directory)
    }()

    /// Documented optional convention: `edge-peek.png` beside `pet.json`.
    /// Rejects traversal/symlink escapes through the same helper as video files.
    static func load(directory: URL, fileName: String = "edge-peek.png") -> EdgePeekAsset? {
        guard let url = PetAnimationCatalog.localFile(fileName, directory: directory),
              let image = NSImage(contentsOf: url) else { return nil }
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              cg.width > 0, cg.height > 0, cg.width <= 8192, cg.height <= 8192,
              let bounds = alphaBounds(cg),
              bounds.width >= 2, bounds.height >= 2,
              let cropped = cg.cropping(to: bounds) else { return nil }
        return EdgePeekAsset(image: cropped,
                             pixelWidth: cropped.width,
                             pixelHeight: cropped.height,
                             sourceName: fileName)
    }

    /// Alpha bounds in CGImage's top-left pixel coordinates, matching
    /// `CGImage.cropping(to:)`. Nearly invisible fringe pixels are ignored.
    static func alphaBounds(_ image: CGImage, threshold: UInt8 = 1) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY,
                      width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

import SwiftUI

/// Per-window presentation state for the independent peek panel.
@MainActor
final class EdgePeekState: ObservableObject {
    @Published var asset: EdgePeekAsset?
    @Published var side: PetEdgeSide = .right
    @Published var cropsInnerSide = false

    func update(asset: EdgePeekAsset?, side: PetEdgeSide, cropsInnerSide: Bool) {
        if self.asset?.image !== asset?.image { self.asset = asset }
        if self.side != side { self.side = side }
        if self.cropsInnerSide != cropsInnerSide { self.cropsInnerSide = cropsInnerSide }
    }
}

/// Static peek art only. It intentionally has no hover expansion, no gesture
/// and no accessibility prerequisites; clicks and drags are routed by the
/// controller's existing local mouse monitor.
struct EdgePeekView: View {
    @ObservedObject var state: EdgePeekState

    var body: some View {
        GeometryReader { geometry in
            if let image = state.asset?.presentationImage(size: geometry.size,
                side: state.side, cropsInnerSide: state.cropsInnerSide) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                Color.clear
            }
        }
    }
}
