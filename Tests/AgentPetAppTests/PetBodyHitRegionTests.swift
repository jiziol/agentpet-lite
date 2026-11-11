import AppKit
import SwiftUI
import XCTest
import AgentPetCore
@testable import agentpet

@MainActor
final class PetBodyHitRegionTests: XCTestCase {
    func testDetachedMeasurementCannotReplaceLivePetBodyMarker() throws {
        _ = NSApplication.shared
        let model = PetWindowModel(key: "measurement-hit-test")
        let source = NSPanel(contentRect: NSRect(x: -2000, y: -2000, width: 360, height: 240),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false
        defer { source.close() }
        let root = Color.clear.frame(width: 213, height: 120).background(PetBodyHitRegion(model: model))
        let host = ClickThroughHostingView(rootView: root)
        source.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let live = try XCTUnwrap(model.petBodyView)
        XCTAssertTrue(live.window === source)
        var measurement = Optional(NSHostingView(rootView: root))
        measurement?.setFrameSize(NSSize(width: 213, height: 120))
        measurement?.layoutSubtreeIfNeeded()
        _ = measurement?.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(model.petBodyView === live, "An unattached measurement must not overwrite a mounted marker")
        measurement = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(model.petBodyView === live, "Disposing a measurement must preserve the live marker")
    }

    func testAnimatedPetMarkerMatchesBodyAfterContentAndRevisionChanges() throws {
        _ = NSApplication.shared
        let model = PetWindowModel(key: "body-marker-regression")
        let image = NSImage(size: NSSize(width: 30, height: 30))
        var pack = ImagePetPack(id: "marker-test", displayName: "Test", description: nil,
            clips: [[image]], directory: URL(fileURLWithPath: "/tmp"))
        pack.videoClips = [.init(id: "video-test", name: "Test", category: "Test",
            url: URL(fileURLWithPath: "/tmp/agentpet-marker-test-missing.mov"), poster: image,
            duration: 1, width: 640, height: 360)]
        let source = NSPanel(contentRect: NSRect(x: -2000, y: -2000, width: 360, height: 240),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false
        defer { source.close() }
        let host = NSHostingView(rootView: PetAnimatedView(pack: pack, mood: .working, size: 120)
            .background(PetBodyHitRegion(model: model)).frame(width: 360, height: 240))
        source.contentView = host
        for revision in 0..<3 {
            pack.animationRevision = UInt64(revision)
            host.rootView = PetAnimatedView(pack: pack, mood: revision == 1 ? .waiting : .working, size: 120)
                .background(PetBodyHitRegion(model: model)).frame(width: 360, height: 240)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            let marker = try XCTUnwrap(model.petBodyView)
            XCTAssertTrue(marker.window === source)
            XCTAssertEqual(marker.bounds.width, 120 * 640 / 360, accuracy: 1)
            XCTAssertEqual(marker.bounds.height, 120, accuracy: 1)
            let point = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: source.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            XCTAssertTrue(PetStatsPanelController.isPetClick(event, petBody: marker))
        }
    }

    func testDetachingOldMarkerKeepsReplacementAndFinalDetachClearsIt() throws {
        _ = NSApplication.shared
        let model = PetWindowModel(key: "marker-replacement")
        func panel() -> NSPanel {
            let panel = NSPanel(contentRect: NSRect(x: -2000, y: -2000, width: 120, height: 120),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            return panel
        }
        let first = panel(), second = panel()
        defer { first.close(); second.close() }
        let root = Color.clear.frame(width: 120, height: 120).background(PetBodyHitRegion(model: model))
        let oldHost = NSHostingView(rootView: root), newHost = NSHostingView(rootView: root)
        first.contentView = oldHost
        oldHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let oldMarker = try XCTUnwrap(model.petBodyView)
        second.contentView = newHost
        newHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let replacement = try XCTUnwrap(model.petBodyView)
        XCTAssertFalse(replacement === oldMarker)
        XCTAssertTrue(replacement.window === second)
        first.contentView = nil
        XCTAssertTrue(model.petBodyView === replacement)
        second.contentView = nil
        XCTAssertNil(model.petBodyView)
    }
}
