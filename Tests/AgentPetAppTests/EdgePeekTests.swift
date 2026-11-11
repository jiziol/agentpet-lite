import XCTest
import AppKit
import SwiftUI
@testable import AgentPetCore
@testable import agentpet

@MainActor
final class EdgePeekTests: XCTestCase {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("edge-peek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testDefaultPackProvidesAlphaCroppedPeekAndSingleShotDrag() throws {
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
        XCTAssertEqual(pack.id, "deepseek")
        XCTAssertEqual(pack.videoClips.count, 33)
        XCTAssertEqual(Set(pack.videoClips.flatMap(\.purposes)), PetAnimationBindings.selectionKeys)
        let peek = try XCTUnwrap(pack.peekAsset)
        XCTAssertEqual(peek.pixelWidth, 535)
        XCTAssertEqual(peek.pixelHeight, 1140)
        XCTAssertLessThan(peek.contentSize.width / peek.contentSize.height, 0.5)
        XCTAssertEqual(EdgePeekAsset.alphaBounds(peek.image),
                       CGRect(x: 0, y: 0, width: 535, height: 1140),
                       "The peek image is stored as its non-transparent content only")
        let drag = try XCTUnwrap(pack.videoClips.first { $0.purposes == ["drag"] })
        XCTAssertEqual(drag.duration, 10.0, accuracy: 0.001)
        XCTAssertNotNil(drag.poster)
        XCTAssertTrue(FileManager.default.fileExists(atPath: drag.url.path))
    }


    func testWidePeekUsesTheSameOuterCropForStaticAndTransitionOnBothSides() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100,
            bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(x: 100, y: 0, width: 80, height: 100))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 180, y: 0, width: 20, height: 100))
        let asset = EdgePeekAsset(image: try XCTUnwrap(context.makeImage()),
                                  pixelWidth: 200, pixelHeight: 100, sourceName: "test")
        func pixel(_ image: CGImage, x: CGFloat) throws -> (Int, Int, Int) {
            let c = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self)
            let index = ((image.height / 2) * image.width + Int(CGFloat(image.width - 1) * x)) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }
        for side in PetEdgeSide.allCases {
            let raster = try XCTUnwrap(asset.presentationImage(size: CGSize(width: 44, height: 50),
                side: side, cropsInnerSide: true))
            XCTAssertEqual(raster.width, 88)
            XCTAssertEqual(raster.height, 100)
            let state = EdgePeekState()
            state.update(asset: asset, side: side, cropsInnerSide: true)
            let renderer = ImageRenderer(content: EdgePeekView(state: state).frame(width: 44, height: 50))
            renderer.scale = 2
            let view = try XCTUnwrap(renderer.cgImage)
            for image in [raster, view] {
                let center = try pixel(image, x: 0.5)
                XCTAssertLessThan(center.0, 10, "The cropped inner red half must not be squeezed into the peek")
                XCTAssertGreaterThan(center.1, 240)
                let outer = try pixel(image, x: side == .right ? 0.95 : 0.05)
                XCTAssertGreaterThan(outer.2, 240, "Preserve and mirror the outer blue seam")
            }
        }
    }

    func testRendersPeekContentAtPetSize70ForEvidence() throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTPET_EDGE_EVIDENCE"] else {
            return
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let asset = try XCTUnwrap(EdgePeekAsset.load(directory: try XCTUnwrap(BundledDefaultPet.resourceDirectory)))
        let layout = try XCTUnwrap(PetEdgeGeometry.peekLayout(
            anchor: NSPoint(x: 500, y: 100), petSize: 70, contentSize: asset.contentSize,
            visible: CGRect(x: 0, y: 0, width: 500, height: 400), side: .right))
        for (name, side, dark) in [("right-light", PetEdgeSide.right, false),
                                   ("left-dark", .left, true)] {
            let state = EdgePeekState()
            state.update(asset: asset, side: side, cropsInnerSide: layout.cropsInnerSide)
            let renderer = ImageRenderer(content: EdgePeekView(state: state)
                .frame(width: layout.frame.width, height: layout.frame.height)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 4
            let image = try XCTUnwrap(renderer.cgImage)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("peek-\(name).png"))
        }
    }

    func testMissingEmptyOrInvalidPeekIsRejected() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(EdgePeekAsset.load(directory: root))
        try Data("not a png".utf8).write(to: root.appendingPathComponent("edge-peek.png"))
        XCTAssertNil(EdgePeekAsset.load(directory: root))
        // A valid but fully transparent image has no content to position.
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage()))
            .representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("edge-peek.png"))
        XCTAssertNil(EdgePeekAsset.load(directory: root))
    }

    func testSymlinkedPeekOutsideThePackIsRejected() throws {
        let root = try sandbox()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
            .appendingPathComponent("edge-peek.png")
        try FileManager.default.copyItem(at: source, to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("edge-peek.png"),
                                                   withDestinationURL: outside)
        XCTAssertNil(EdgePeekAsset.load(directory: root))
    }

    func testPackWithoutPeekStillLoadsAllExistingAnimations() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        for item in ["pet.json", "posters", "animations.json", "videos"] {
            let from = source.appendingPathComponent(item)
            let to = root.appendingPathComponent(item)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from, to: to)
        }
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: root))
        XCTAssertNil(pack.peekAsset, "No pack-owned sticker was invented or written")
        let fallback = try XCTUnwrap(pack.effectivePeekAsset)
        XCTAssertEqual(fallback.pixelWidth, 535)
        XCTAssertEqual(fallback.pixelHeight, 1140)
        XCTAssertEqual(pack.videoClips.count, 33)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("edge-peek.png").path))
    }

    func testPackOwnedPeekWinsAndInvalidPeekUsesBundledPresentationOnly() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 30,
            bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        let own = EdgePeekAsset(image: try XCTUnwrap(context.makeImage()),
                               pixelWidth: 20, pixelHeight: 30, sourceName: "own.png")
        var pack = ImagePetPack(id: "external", displayName: "External", description: nil,
            clips: [[NSImage(cgImage: own.image, size: .zero)]], directory: root, peekAsset: own)
        XCTAssertEqual(pack.effectivePeekAsset?.sourceName, "own.png")
        try Data("invalid".utf8).write(to: root.appendingPathComponent("edge-peek.png"))
        pack.peekAsset = EdgePeekAsset.load(directory: root)
        XCTAssertNil(pack.peekAsset)
        XCTAssertEqual(pack.effectivePeekAsset?.pixelHeight, 1140)
        XCTAssertEqual(pack.animationIDs, ["sheet:0"])
        for key in PetAnimationBindings.selectionKeys {
            XCTAssertEqual(pack.nativeFallbackID(for: key), "sheet:0",
                "The default edge sticker must not replace this pet's own native action")
        }
    }

}
