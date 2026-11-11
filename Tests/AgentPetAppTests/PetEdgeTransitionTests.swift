import XCTest
import AppKit
import AVFoundation
import QuartzCore
import SwiftUI
import CryptoKit
import AgentPetCore
@testable import agentpet

@MainActor
final class PetEdgeTransitionTests: XCTestCase {
    private func image(width: Int = 64, height: Int = 64) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.8).cgColor)
        context.fill(CGRect(x: 8, y: 8, width: width - 16, height: height - 16))
        return try XCTUnwrap(context.makeImage())
    }

    private func digest(_ image: CGImage) throws -> String {
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try XCTUnwrap(context.data).withMemoryRebound(to: UInt8.self, capacity: width * height * 4) {
            Data(bytes: $0, count: width * height * 4)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testEdgeMeshStartsAtPetAndEndsExactlyAtPeekForBothSides() throws {
        let from = NSRect(x: 400, y: 200, width: 120, height: 120)
        let right = NSRect(x: 1450, y: 300, width: 24, height: 50)
        for side in PetEdgeSide.allCases {
            let target = side == .right ? right : NSRect(x: 0, y: 300, width: 24, height: 50)
            let start = PetEdgeTransition.edgeFrames(from: from, to: target, side: side, progress: 0)
            let end = PetEdgeTransition.edgeFrames(from: from, to: target, side: side, progress: 1)
            XCTAssertEqual(start.count, 64)
            XCTAssertEqual(end.count, 64)
            let startUnion = start.reduce(start[0]) { $0.union($1) }
            let endUnion = end.reduce(end[0]) { $0.union($1) }
            XCTAssertEqual(startUnion.minX, from.minX, accuracy: 0.6)
            XCTAssertEqual(startUnion.maxX, from.maxX, accuracy: 0.6)
            XCTAssertEqual(startUnion.minY, from.minY, accuracy: 0.6)
            XCTAssertEqual(startUnion.maxY, from.maxY, accuracy: 0.6)
            XCTAssertEqual(endUnion.minX, target.minX, accuracy: 0.6)
            XCTAssertEqual(endUnion.maxX, target.maxX, accuracy: 0.6)
            XCTAssertEqual(endUnion.minY, target.minY, accuracy: 0.6)
            XCTAssertEqual(endUnion.maxY, target.maxY, accuracy: 0.6)
            if side == .right {
                XCTAssertEqual(end.last!.maxX, target.maxX, accuracy: 0.6)
            } else {
                XCTAssertEqual(end.first!.minX, target.minX, accuracy: 0.6)
            }
            for frame in end {
                XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite)
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, target.minX - 0.6)
                XCTAssertLessThanOrEqual(frame.maxX, target.maxX + 0.6)
            }
        }
    }

    func testEdgeMeshIsContinuousAndMonotonicAtMidProgress() {
        let from = NSRect(x: 0, y: 0, width: 200, height: 200)
        let right = NSRect(x: 900, y: 100, width: 30, height: 60)
        for step in 0...10 {
            let frames = PetEdgeTransition.edgeFrames(from: from, to: right, side: .right,
                                                      progress: CGFloat(step) / 10)
            for index in 1..<frames.count {
                XCTAssertEqual(frames[index].minX, frames[index - 1].maxX, accuracy: 0.6,
                               "Vertical source slices must stay adjacent")
            }
        }
    }

    func testDragPresentationRetainsConsumedCuesAcrossMouseUp() throws {
        try TestIsolation.require()
        _ = NSApplication.shared
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: try XCTUnwrap(BundledDefaultPet.resourceDirectory)))
        let state = PetAnimationViewState()
        let context = PetAnimationContext(cue: .init(id: "already-consumed-quota", key: "quota"))
        func view(dragging: Bool) -> AnyView {
            AnyView(PetAnimatedView(pack: pack, mood: .idle, dragging: dragging, dragSession: 1,
                                   context: context, state: state)
                .environment(\.animationsEnabled, true).id(dragging))
        }
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 240, height: 140),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view(dragging: false))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let quota = try XCTUnwrap(state.playback.selection)
        XCTAssertEqual(quota.key, "quota")
        state.finish(quota.token)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(state.playback.selection?.key, "idle")
        host.rootView = view(dragging: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(state.playback.selection?.key, "drag")
        host.rootView = view(dragging: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(state.playback.selection?.key, "idle",
                       "Reopening the body must not replay a consumed quota/levelup cue")
    }

    private func solid(_ color: NSColor, size: Int = 80) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try XCTUnwrap(context.makeImage())
    }

    private func colorMaxima(_ image: CGImage) throws -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var r = 0, g = 0, b = 0, a = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            r = max(r, Int(bytes[i])); g = max(g, Int(bytes[i + 1])); b = max(b, Int(bytes[i + 2])); a = max(a, Int(bytes[i + 3]))
        }
        return (r, g, b, a)
    }

    func testLateExpansionSnapshotContainsTheRevealedBodyAndMesh() throws {
        _ = NSApplication.shared
        let parent = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 160, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.red.cgColor
        parent.contentView = content
        parent.orderFront(nil)
        let transition = PetEdgeTransition()
        defer { transition.cancel(); parent.orderOut(nil) }
        let source = PetEdgeSnapshot(image: try solid(.blue),
            frame: NSRect(x: 280, y: 230, width: 40, height: 50))
        transition.holdExpansion(snapshot: source, in: parent)
        transition.animateExpand(snapshot: source,
            to: NSRect(x: 220, y: 220, width: 100, height: 80), side: .right,
            in: parent, duration: 1.0) {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.85))
        let composite = try XCTUnwrap(transition.visibleExpansionSnapshot())
        let colors = try colorMaxima(composite.image)
        print("LATE_EXPANSION_VISIBLE_COMPOSITE", colors)
        XCTAssertGreaterThan(colors.red, 80, "The visible body must be in the interrupted source")
        XCTAssertGreaterThan(colors.blue, 0, "The remaining mesh is part of the same visible source")
        XCTAssertGreaterThan(colors.alpha, 150, "Do not collapse from the faint mesh alone")
    }

    func testExpansionInterruptionUsesTheLatestProxyFrameAfterWindowMovement() throws {
        _ = NSApplication.shared
        let parent = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 160, height: 120),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        content.wantsLayer = true
        parent.contentView = content
        parent.orderFront(nil)
        let transition = PetEdgeTransition()
        defer { transition.cancel(); parent.orderOut(nil) }
        let peek = PetEdgeSnapshot(image: try solid(.blue),
            frame: NSRect(x: 280, y: 230, width: 40, height: 50))
        let body = PetEdgeSnapshot(image: try solid(.red),
            frame: NSRect(x: 220, y: 220, width: 100, height: 80))
        transition.holdExpansion(snapshot: peek, in: parent)
        transition.animateExpand(snapshot: peek, to: body.frame, side: .right,
                                 in: parent, duration: 1, body: body) {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        parent.setFrameOrigin(NSPoint(x: 280, y: 185))
        let updated = PetEdgeSnapshot(image: try solid(.green),
            frame: body.frame.offsetBy(dx: 80, dy: -15))
        transition.updateExpansionBody(updated)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let snapshot = try XCTUnwrap(transition.visibleExpansionSnapshot())
        let colors = try colorMaxima(snapshot.image)
        XCTAssertGreaterThan(colors.green, 80, "The compositor must display and capture the newest supplied body frame")
        XCTAssertLessThan(colors.red, 10, "The old body proxy must not survive a frame update")
        XCTAssertGreaterThan(colors.blue, 0)
        XCTAssertGreaterThan(snapshot.frame.minX, 280)
        XCTAssertGreaterThan(colors.alpha, 150)
    }

    func testCollapseCrossfadeSnapshotIncludesPeekAndMeshPixels() throws {
        _ = NSApplication.shared
        let transition = PetEdgeTransition()
        defer { transition.cancel() }
        let frame = NSRect(x: 400, y: 220, width: 24, height: 50)
        transition.animate(snapshot: PetEdgeSnapshot(image: try solid(.blue), frame: frame),
            to: frame, side: .right, collapsing: true, duration: 0.01,
            interactive: true, holdAtEnd: true) {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var completed = false
        transition.crossfade(to: PetEdgeSnapshot(image: try solid(.red), frame: frame), duration: 1) {
            completed = true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let snapshot = try XCTUnwrap(transition.visibleCollapseSnapshot())
        let colors = try colorMaxima(snapshot.image)
        print("COLLAPSE_CROSSFADE_VISIBLE_COMPOSITE", colors)
        XCTAssertGreaterThan(colors.red, 60, "Include the peek being revealed in the crossfade")
        XCTAssertGreaterThan(colors.blue, 20, "Include the mesh fading out in the same snapshot")
        XCTAssertGreaterThan(colors.alpha, 150)
        XCTAssertFalse(completed)
        XCTAssertEqual(transition.interactivePanel?.alphaValue, 1,
                       "The compositor owns opacity; do not split it across NSWindow alpha animations")
        transition.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(completed, "A cancelled crossfade must not run a late show-peek callback")
    }

    func testExportsInterruptedCompositorWithTheRealMovieMaterial() throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTPET_EDGE_EVIDENCE"] else { return }
        try TestIsolation.require()
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
        let clip = try XCTUnwrap(pack.videoClips.first { $0.purposes == ["drag"] })
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        let raw = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
        let peek = try XCTUnwrap(EdgePeekAsset.load(directory: directory))
        let parentFrame = NSRect(x: 200, y: 200, width: 124.444, height: 70)
        let parent = NSPanel(contentRect: parentFrame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        parent.hasShadow = false
        let content = NSView(frame: NSRect(origin: .zero, size: parentFrame.size))
        content.wantsLayer = true
        content.layer?.contents = raw
        content.layer?.contentsGravity = .resizeAspect
        parent.contentView = content
        parent.orderFront(nil)
        let transition = PetEdgeTransition()
        defer { transition.cancel(); parent.orderOut(nil) }
        let body = try XCTUnwrap(PetEdgeSnapshotter.crop(image: raw, frame: parentFrame))
        let source = PetEdgeSnapshot(image: peek.image,
            frame: NSRect(x: parentFrame.maxX - 23.5, y: body.frame.midY - 25, width: 23.5, height: 50))
        var frames: [String: String] = [:]
        func save(_ snapshot: PetEdgeSnapshot?, _ name: String) throws {
            let snapshot = try XCTUnwrap(snapshot)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: snapshot.image)
                .representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(name + ".png"))
            frames[name] = NSStringFromRect(snapshot.frame)
        }
        transition.holdExpansion(snapshot: source, in: parent)
        transition.animateExpand(snapshot: source, to: body.frame, side: .right,
                                 in: parent, duration: 1, body: body) {}
        try save(transition.visibleExpansionSnapshot(), "actual-expansion-000")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try save(transition.visibleExpansionSnapshot(), "actual-expansion-050")
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        try save(transition.visibleExpansionSnapshot(), "actual-expansion-085")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertNil(transition.expandPanel)
        let model = PetWindowModel(key: "r2-compositor-evidence")
        model.petBodyView = content
        try save(PetEdgeSnapshotter.captureStatic(model: model), "actual-expansion-live")
        parent.orderOut(nil)
        transition.animate(snapshot: body, to: source.frame, side: .right,
                           collapsing: true, duration: 0.05, interactive: true, holdAtEnd: true) {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        transition.crossfade(to: source, duration: 1) {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try save(transition.visibleCollapseSnapshot(), "actual-collapse-crossfade-050")
        try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("actual-capture-frames.json"))
    }

    func testVideoWithoutPosterStillExpandsAndCrossfadesInsteadOfReturningEarly() throws {
        try TestIsolation.require()
        _ = NSApplication.shared
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: try XCTUnwrap(BundledDefaultPet.resourceDirectory)))
        let original = try XCTUnwrap(pack.videoClips.first { $0.purposes == ["drag"] })
        let clip = PetVideoClip(id: original.id, name: original.name, category: original.category,
            url: original.url, poster: nil, duration: original.duration, width: original.width,
            height: original.height, purposes: original.purposes)
        let parent = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 320, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let video = PetVideoNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        parent.contentView = video
        parent.orderFront(nil)
        video.configure(clip: clip, loop: false, token: 1, animate: true,
            onFinished: nil, onFailure: nil, selectionKey: "drag", dragSession: 1)
        let transition = PetEdgeTransition()
        defer { transition.cancel(); video.teardown(); parent.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let source = PetEdgeSnapshot(image: try solid(.blue),
            frame: NSRect(x: 480, y: 230, width: 24, height: 50))
        transition.holdExpansion(snapshot: source, in: parent)
        var finished = false
        transition.animateExpand(snapshot: source, to: NSRect(x: 290, y: 220, width: 80, height: 100),
            side: .right, in: parent, duration: 0.2, body: nil) { finished = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(transition.visibleExpansionSnapshot(), "No-proxy video must retain the expanding visible source")
        XCTAssertFalse(finished, "Missing poster/sample must not hard-switch directly to the live movie")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(finished)
        XCTAssertEqual(video.layer?.opacity, 1)
        XCTAssertNil(transition.expandPanel)
    }

    func testExpansionFinishesWithACapturableProxyToLiveCrossfade() throws {
        _ = NSApplication.shared
        let parent = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 120, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.red.cgColor
        parent.contentView = content
        parent.orderFront(nil)
        let transition = PetEdgeTransition()
        defer { transition.cancel(); parent.orderOut(nil) }
        let source = PetEdgeSnapshot(image: try solid(.green),
            frame: NSRect(x: 280, y: 220, width: 24, height: 50))
        let proxy = PetEdgeSnapshot(image: try solid(.blue), frame: parent.frame)
        transition.holdExpansion(snapshot: source, in: parent)
        var finished = false
        transition.animateExpand(snapshot: source, to: proxy.frame, side: .right,
            in: parent, duration: 0.15, body: proxy) { finished = true }
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            let alpha = content.layer?.presentation()?.opacity ?? 0
            if alpha >= 0.45 && alpha <= 0.7 { break }
        }
        XCTAssertFalse(finished)
        let root = try XCTUnwrap(content.layer?.presentation())
        XCTAssertGreaterThan(root.opacity, 0)
        XCTAssertLessThan(root.opacity, 1)
        let snapshot = try XCTUnwrap(transition.visibleExpansionSnapshot())
        let colors = try colorMaxima(snapshot.image)
        XCTAssertGreaterThan(colors.red, 20, "Interrupted handoff contains the actual live parent")
        XCTAssertGreaterThan(colors.blue, 20, "Interrupted handoff also contains the fading proxy")
        transition.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertFalse(finished, "Cancelling handoff invalidates its completion")
        XCTAssertEqual(content.layer?.opacity, 1)
        XCTAssertNil(transition.expandPanel)
    }

    func testLiveMovieKeepsPlayingThroughProxyHandoff() throws {
        try TestIsolation.require()
        _ = NSApplication.shared
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: try XCTUnwrap(BundledDefaultPet.resourceDirectory)))
        let clip = try XCTUnwrap(pack.videoClips.first { $0.purposes == ["drag"] })
        let parent = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 320, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let video = PetVideoNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        parent.contentView = video
        parent.orderFront(nil)
        video.configure(clip: clip, loop: false, token: 1, animate: true,
            onFinished: nil, onFailure: nil, selectionKey: "drag", dragSession: 1)
        let transition = PetEdgeTransition()
        defer { transition.cancel(); video.teardown(); parent.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let before = try XCTUnwrap(video.currentSamplingPayload()).time.seconds
        // Test-only synchronous decode supplies deliberately older actual movie
        // pixels. Production keeps its existing asynchronous sampler.
        let proxy = try XCTUnwrap(PetEdgeSnapshotter.crop(
            image: XCTUnwrap(video.currentDisplayedFrame()), frame: XCTUnwrap(video.movieScreenFrame)))
        let source = PetEdgeSnapshot(image: try solid(.blue),
            frame: NSRect(x: 480, y: 230, width: 24, height: 50))
        transition.holdExpansion(snapshot: source, in: parent)
        var completed = false
        transition.animateExpand(snapshot: source, to: proxy.frame, side: .right,
            in: parent, duration: 0.15, body: proxy) { completed = true }
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            let alpha = video.layer?.presentation()?.opacity ?? 0
            if alpha >= 0.35 && alpha <= 0.7 { break }
        }
        XCTAssertNotNil(transition.expandPanel)
        let opacity = try XCTUnwrap(video.layer?.presentation()).opacity
        XCTAssertGreaterThan(opacity, 0)
        XCTAssertLessThan(opacity, 1)
        let during = try XCTUnwrap(video.currentSamplingPayload()).time.seconds
        XCTAssertGreaterThan(during, before + 0.12, "Do not seek or pause live video to align the proxy")
        XCTAssertFalse(completed)
        print("LIVE_MOVIE_HANDOFF timeBefore=\(before) timeDuring=\(during) opacity=\(opacity)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(completed)
        XCTAssertNil(transition.expandPanel)
        XCTAssertEqual(video.layer?.opacity, 1)
    }

    func testHeldExpansionHidesLiveBodyAndCancellationRestoresPixels() throws {
        _ = NSApplication.shared
        let parent = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 150, height: 100),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: 100))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.red.cgColor
        parent.contentView = content
        parent.orderFront(nil)
        let transition = PetEdgeTransition()
        defer { transition.cancel(); parent.orderOut(nil) }
        let source = PetEdgeSnapshot(image: try image(),
            frame: NSRect(x: 325, y: 220, width: 24, height: 50))
        transition.holdExpansion(snapshot: source, in: parent)
        XCTAssertEqual(content.layer?.opacity, 0,
                       "Full-size live body must not show outside the expanding peek")
        XCTAssertNotNil(transition.expandPanel)
        transition.animateExpand(snapshot: source, to: NSRect(x: 260, y: 220, width: 44, height: 52),
            side: .right, in: parent, duration: 0.5) {}
        XCTAssertEqual(content.layer?.opacity, 0, "The live parent stays masked while the compositor owns its pixels")
        let proxy = try XCTUnwrap(transition.expandPanel?.contentView?.layer?.sublayers?
            .first { $0.name == "petEdgeBodyProxy" })
        let reveal = try XCTUnwrap(proxy.animation(forKey: "petEdgeBodyReveal") as? CAKeyframeAnimation)
        let values = try XCTUnwrap(reveal.values as? [NSNumber])
        XCTAssertEqual(values.first?.doubleValue, 0)
        XCTAssertEqual(values[values.count / 2].doubleValue, 0)
        XCTAssertEqual(values.last?.doubleValue, 1)
        transition.cancel()
        XCTAssertEqual(content.layer?.opacity, 1)
        XCTAssertNil(content.layer?.animation(forKey: "petEdgeBodyReveal"))
        XCTAssertNil(transition.expandPanel)
    }

    func testCancellationNeverRunsTheOldCompletion() throws {
        _ = NSApplication.shared
        let transition = PetEdgeTransition()
        let snapshot = PetEdgeSnapshot(image: try image(),
                                       frame: NSRect(x: 300, y: 300, width: 120, height: 120))
        var completed = false
        transition.animate(snapshot: snapshot, to: NSRect(x: 600, y: 300, width: 24, height: 50),
                           side: .right, collapsing: true, duration: 0.5) {
            completed = true
        }
        transition.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        XCTAssertFalse(completed, "A cancelled transition must not run a stale show-peek completion")
    }



    func testRendersIntermediateEdgeMeshEvidenceFromTheActualMovie() throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTPET_EDGE_EVIDENCE"] else {
            return
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let resource = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: resource))
        let clip = try XCTUnwrap(pack.videoClips.first { $0.purposes == ["drag"] })
        let asset = AVURLAsset(url: clip.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let raw = try generator.copyCGImage(at: CMTime(seconds: 1.0, preferredTimescale: 600),
                                             actualTime: nil)
        let rawFrame = NSRect(x: 40, y: 120, width: 213, height: 120)
        let cropped = try XCTUnwrap(PetEdgeSnapshotter.crop(image: raw, frame: rawFrame))
        let peek = try XCTUnwrap(EdgePeekAsset.load(directory: resource))
        let peekFrame = NSRect(x: 616, y: 155, width: 24, height: 50)
        let bodyFrame = try XCTUnwrap(PetEdgeSnapshotter.crop(image: raw,
            frame: NSRect(x: 510, y: 120, width: 124.444, height: 70))).frame
        let canvas = NSRect(x: 0, y: 0, width: 640, height: 360)

        // The intermediate collapse evidence uses the same cropped source but
        // renders each stage explicitly.
        for (name, progress) in [("000", CGFloat(0)), ("050", CGFloat(0.5)), ("100", CGFloat(1))] {
            let count = 128
            let frames = PetEdgeTransition.edgeFrames(from: cropped.frame, to: peekFrame,
                                                       side: .right, progress: progress, count: count)
            let root = CALayer()
            root.frame = canvas
            root.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1).cgColor
            let dark = CALayer()
            dark.frame = CGRect(x: 320, y: 0, width: 320, height: 360)
            dark.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
            root.addSublayer(dark)
            for (index, frameRect) in frames.enumerated() {
                let strip = CALayer()
                strip.contents = cropped.image
                strip.contentsRect = CGRect(x: CGFloat(index) / CGFloat(count), y: 0,
                                            width: 1 / CGFloat(count), height: 1)
                strip.contentsGravity = .resize
                strip.frame = frameRect
                strip.allowsEdgeAntialiasing = true
                strip.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge]
                root.addSublayer(strip)
            }
            let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360,
                bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(canvas)
            root.render(in: context)
            let image = try XCTUnwrap(context.makeImage())
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("edge-right-\(name).png"))
        }
        do {
            let count = 128
            let frames = PetEdgeTransition.edgeFrames(from: cropped.frame, to: peekFrame,
                                                       side: .right, progress: 1, count: count)
            let root = CALayer()
            root.frame = canvas
            root.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1).cgColor
            let dark = CALayer()
            dark.frame = CGRect(x: 320, y: 0, width: 320, height: 360)
            dark.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
            root.addSublayer(dark)
            for (index, frameRect) in frames.enumerated() {
                let strip = CALayer()
                strip.contents = cropped.image
                strip.contentsRect = CGRect(x: CGFloat(index) / CGFloat(count), y: 0,
                                            width: 1 / CGFloat(count), height: 1)
                strip.contentsGravity = .resize
                strip.frame = frameRect
                strip.opacity = 0.5
                root.addSublayer(strip)
            }
            let peekLayer = CALayer()
            peekLayer.contents = peek.image
            peekLayer.contentsGravity = .resize
            peekLayer.frame = peekFrame
            peekLayer.opacity = 0.5
            root.addSublayer(peekLayer)
            let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360,
                bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(canvas)
            root.render(in: context)
            let image = try XCTUnwrap(context.makeImage())
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("crossfade-right-050.png"))
        }
        for (name, progress) in [("000", CGFloat(0)), ("050", CGFloat(0.5)), ("087", CGFloat(0.875)), ("100", CGFloat(1))] {
            let count = 128
            let frames = PetEdgeTransition.edgeFrames(from: peekFrame, to: bodyFrame,
                                                       side: .right, progress: progress, count: count)
            let root = CALayer()
            root.frame = canvas
            root.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1).cgColor
            let dark = CALayer()
            dark.frame = CGRect(x: 320, y: 0, width: 320, height: 360)
            dark.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
            root.addSublayer(dark)
            // Include the live-body surrogate too, using an actual MOV frame
            // and the very same reveal curve as the production animation.
            let body = CALayer()
            body.contents = cropped.image
            body.contentsGravity = .resize
            body.frame = bodyFrame
            let liveOpacity = PetEdgeTransition.expansionBodyOpacity(progress: progress)
            body.opacity = Float(liveOpacity)
            root.addSublayer(body)
            for (index, frameRect) in frames.enumerated() {
                let strip = CALayer()
                strip.contents = peek.image
                strip.opacity = Float(1 - liveOpacity)
                strip.contentsRect = CGRect(x: CGFloat(index) / CGFloat(count), y: 0,
                                            width: 1 / CGFloat(count), height: 1)
                strip.contentsGravity = .resize
                strip.frame = frameRect
                strip.allowsEdgeAntialiasing = true
                strip.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge]
                root.addSublayer(strip)
            }
            let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360,
                bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(canvas)
            root.render(in: context)
            let image = try XCTUnwrap(context.makeImage())
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("expand-composite-right-\(name).png"))
        }
    }

    func testSnapshotCropsAlphaContentAndConvertsItsScreenRect() throws {
        let size = 64
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(NSColor.red.cgColor)
        // Top-left content rect (10,12)-(30,42) in image coordinates.
        context.fill(CGRect(x: 10, y: size - 42, width: 20, height: 30))
        let image = try XCTUnwrap(context.makeImage())
        let frame = NSRect(x: 100, y: 200, width: 64, height: 64)
        let snapshot = try XCTUnwrap(PetEdgeSnapshotter.crop(image: image, frame: frame))
        XCTAssertEqual(snapshot.image.width, 20)
        XCTAssertEqual(snapshot.image.height, 30)
        XCTAssertEqual(snapshot.frame.minX, 110, accuracy: 0.01)
        XCTAssertEqual(snapshot.frame.minY, 222, accuracy: 0.01)
        XCTAssertEqual(snapshot.frame.width, 20, accuracy: 0.01)
        XCTAssertEqual(snapshot.frame.height, 30, accuracy: 0.01)
    }

    func testCollapseHoldCrossfadeRemovesOverlayOnlyAfterFade() throws {
        _ = NSApplication.shared
        let transition = PetEdgeTransition()
        let snapshot = PetEdgeSnapshot(image: try image(width: 80, height: 80),
                                       frame: NSRect(x: 300, y: 300, width: 80, height: 80))
        var meshDone = false, fadeDone = false
        transition.animate(snapshot: snapshot,
                           to: NSRect(x: 600, y: 300, width: 24, height: 50),
                           side: .right, collapsing: true, duration: 0.06,
                           interactive: true, holdAtEnd: true) {
            meshDone = true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(meshDone)
        XCTAssertNotNil(transition.interactivePanel,
                        "The final mesh remains for the crossfade instead of a hard cut")
        transition.fadeOut(duration: 0.03) { fadeDone = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(fadeDone)
        XCTAssertNil(transition.interactivePanel)
    }

    func testAsyncFrameSampleDoesNotBlockTheMainThreadAndReturnsRealFrame() throws {
        _ = NSApplication.shared
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
        let clip = try XCTUnwrap(pack.videoClips.first { $0.purposes == ["drag"] })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let view = PetVideoNSView(frame: container.bounds)
        container.addSubview(view)
        let body = NSView(frame: container.bounds)
        container.addSubview(body)
        window.contentView = container
        window.orderFront(nil)
        view.configure(clip: clip, loop: false, token: 1, animate: true,
                       onFinished: nil, onFailure: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let model = PetWindowModel(key: "async-sample")
        model.petBodyView = body
        defer {
            view.teardown()
            window.orderOut(nil)
        }
        var sample: PetEdgeSnapshot?
        let start = CFAbsoluteTimeGetCurrent()
        let task = PetEdgeSnapshotter.sampleAsync(model: model) { sample = $0 }
        let callElapsed = CFAbsoluteTimeGetCurrent() - start
        print("ASYNC_SAMPLE_MAIN_SECONDS \(callElapsed)")
        XCTAssertNotNil(task)
        XCTAssertLessThan(callElapsed, 0.02,
                          "Frame sampling must not synchronously decode 122ms on the main thread")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let snapshot = try XCTUnwrap(sample, "The detached sample returns the actual frame")
        XCTAssertGreaterThan(snapshot.image.width, 10)
        XCTAssertGreaterThan(snapshot.frame.width, 0)
    }

    func testStaticSnapshotBeforeMovieIsReadyUsesVisiblePoster() throws {
        _ = NSApplication.shared
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
        let clip = try XCTUnwrap(pack.videoClips.first { $0.purposes == ["drag"] })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let view = PetVideoNSView(frame: container.bounds)
        container.addSubview(view)
        let body = NSView(frame: container.bounds)
        container.addSubview(body)
        window.contentView = container
        window.orderFront(nil)
        // Do not play: the poster layer is the visible content.
        view.configure(clip: clip, loop: false, token: 1, animate: false,
                       onFinished: nil, onFailure: nil)
        let model = PetWindowModel(key: "poster-static")
        model.petBodyView = body
        defer {
            view.teardown()
            window.orderOut(nil)
        }
        let start = CFAbsoluteTimeGetCurrent()
        let snapshot = try XCTUnwrap(PetEdgeSnapshotter.captureStatic(model: model),
                                     "A not-ready movie still yields the visible poster snapshot")
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("POSTER_STATIC_CAPTURE_SECONDS \(elapsed) frame=\(snapshot.frame)")
        XCTAssertLessThan(elapsed, 0.08)
        XCTAssertGreaterThan(snapshot.image.width, 10)
        XCTAssertEqual(snapshot.frame.width, 134, accuracy: 1,
                       "Poster content is alpha-cropped, not the full 320pt window")
        XCTAssertEqual(snapshot.frame.height, 156, accuracy: 1)
        XCTAssertGreaterThan(snapshot.frame.minX, 80)
        XCTAssertLessThan(snapshot.frame.maxX, 240)
    }

    func testDragMovieHoldsItsLastFrameAfterTheTenSecondClip() throws {
        _ = NSApplication.shared
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
        let clip = try XCTUnwrap(pack.videoClips.first { $0.purposes == ["drag"] })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = PetVideoNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        window.contentView = view
        window.orderFront(nil)
        defer {
            view.teardown()
            window.orderOut(nil)
        }
        var finished = 0
        view.configure(clip: clip, loop: false, token: 1, animate: true,
                       onFinished: { _ in finished += 1 }, onFailure: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(10.45))
        XCTAssertEqual(finished, 1, "A single-shot 10s drag movie finishes once")
        let last = try XCTUnwrap(view.currentDisplayedFrame(),
                                 "The movie must keep showing its last frame")
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        let stillLast = try XCTUnwrap(view.currentDisplayedFrame())
        XCTAssertEqual(finished, 1, "No loop/restart after the clip ends")
        XCTAssertEqual(try digest(last), try digest(stillLast),
                       "The visible frame stays on the final pose, not a restarted first frame")
        let poster = try XCTUnwrap(clip.poster?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertNotEqual(try digest(last), try digest(poster),
                          "The held frame is the real final movie frame, not the poster")
    }

    func testActualMovieFrameIsCapturedForTheTransition() throws {
        _ = NSApplication.shared
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
        let clip = try XCTUnwrap(pack.videoClips.first { $0.purposes == ["drag"] })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = PetVideoNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        window.contentView = view
        window.orderFront(nil)
        view.configure(clip: clip, loop: false, token: 1, animate: true,
                       onFinished: nil, onFailure: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let captured = view.currentDisplayedFrame()
        let frame = try XCTUnwrap(captured,
                                  "The transition must capture the real AVPlayer frame, not a poster")
        defer {
            view.teardown()
            window.orderOut(nil)
        }
        XCTAssertGreaterThan(frame.width, 300)
        XCTAssertGreaterThan(frame.height, 150)
        XCTAssertNotEqual(frame.alphaInfo, .none,
                          "The captured movie frame must retain its alpha channel")
        let width = frame.width, height = frame.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var transparent = 0, opaque = 0
        for y in Swift.stride(from: 0, to: height, by: 5) {
            for x in Swift.stride(from: 0, to: width, by: 5) {
                let alpha = bytes[(y * width + x) * 4 + 3]
                if alpha == 0 { transparent += 1 } else if alpha > 250 { opaque += 1 }
            }
        }
        XCTAssertGreaterThan(transparent, 0)
        XCTAssertGreaterThan(opaque, 0)
        let poster = try XCTUnwrap(clip.poster?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertNotEqual(try digest(frame), try digest(poster),
                          "The captured image must be the playing frame, not the poster")
    }
}
