import AppKit
import XCTest
@testable import agentpet

@MainActor
final class PetWindowPositionTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 25, width: 1512, height: 900)

    private func withStore(_ body: (UserDefaults, PetWindowPositionStore) throws -> Void) rethrows {
        let name = "pet-position-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, PetWindowPositionStore(defaults: defaults))
    }

    func testRelaunchWithDifferentBubbleWidthsRestoresSamePetCenter() throws {
        try withStore { defaults, store in
            let anchor = NSPoint(x: 1370, y: 80)
            var placement = PetWindowPlacement(anchor: anchor)
            for width: CGFloat in [624, 312, 144, 480, 144] {
                let layout = try XCTUnwrap(placement.layout(size: NSSize(width: width, height: 300),
                                                          petWidth: 120, visible: visible))
                XCTAssertEqual(layout.frame.midX + layout.petOffset, anchor.x)
                XCTAssertFalse(placement.recordUserMove(frame: layout.frame, petOffset: layout.petOffset))
                store.save(try XCTUnwrap(placement.anchor), forKey: "default")
                // New store models a fresh process, starting with a bare panel.
                placement = PetWindowPlacement(anchor: PetWindowPositionStore(defaults: defaults)
                    .anchor(forKey: "default", legacyWindowWidth: 144))
                XCTAssertEqual(placement.anchor, anchor)
            }
        }
    }

    func testTallBubbleFitsTemporarilyThenReturnsToOriginalHeight() throws {
        let anchor = NSPoint(x: 750, y: 740)
        var placement = PetWindowPlacement(anchor: anchor)
        let tall = try XCTUnwrap(placement.layout(size: NSSize(width: 480, height: 500), petWidth: 120, visible: visible))
        XCTAssertEqual(tall.frame.minY, 425)
        XCTAssertFalse(placement.recordUserMove(frame: tall.frame, petOffset: tall.petOffset))
        XCTAssertEqual(placement.anchor, anchor)
        let small = try XCTUnwrap(placement.layout(size: NSSize(width: 144, height: 144), petWidth: 120, visible: visible))
        XCTAssertEqual(small.frame.minY, anchor.y)
        XCTAssertEqual(small.frame.midX, anchor.x)
    }

    func testRealPanelMoveNotificationDoesNotSaveProgrammaticResize() throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { panel.close() }
        var placement = PetWindowPlacement(anchor: NSPoint(x: 1370, y: 80))
        var offset: CGFloat = 0
        var captured: [NSPoint] = []
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
            object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                if placement.recordUserMove(frame: panel.frame, petOffset: offset), let anchor = placement.anchor {
                    captured.append(anchor)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for width: CGFloat in [144, 624, 312, 144] {
            let layout = try XCTUnwrap(placement.layout(size: NSSize(width: width, height: 250),
                                                      petWidth: 120, visible: visible))
            offset = layout.petOffset
            panel.setFrame(layout.frame, display: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(captured.isEmpty, "Layout notifications must never be mistaken for a user drag")
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX - 100, y: 160))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(captured.last, NSPoint(x: 1270, y: 160))
        XCTAssertEqual(placement.anchor, captured.last)
        print("POSITION_TEST_DISPLAY_SCALES", NSScreen.screens.map(\.backingScaleFactor))
    }

    func testLegacyMigrationPreservesDataAndNewAnchorWins() throws {
        try withStore { defaults, store in
            let legacy = try JSONEncoder().encode(["default": [1204.0, 33.0], "/work": [300.0, 50.0]])
            defaults.set(legacy, forKey: PetWindowPositionStore.legacyKey)
            XCTAssertEqual(store.anchor(forKey: "default", legacyWindowWidth: 312), NSPoint(x: 1360, y: 33))
            store.save(NSPoint(x: 1360, y: 33), forKey: "default")
            store.save(NSPoint(x: -700, y: 90), forKey: "/work")
            XCTAssertEqual(store.anchor(forKey: "default", legacyWindowWidth: 144), NSPoint(x: 1360, y: 33))
            XCTAssertEqual(store.anchor(forKey: "/work", legacyWindowWidth: 144), NSPoint(x: -700, y: 90))
            XCTAssertEqual(defaults.data(forKey: PetWindowPositionStore.legacyKey), legacy)
        }
    }

    func testInvalidAndNonFinitePositionsAreRejected() throws {
        try withStore { defaults, store in
            defaults.set(Data("{\"default\":[1]}".utf8), forKey: PetWindowPositionStore.anchorsKey)
            XCTAssertNil(store.anchor(forKey: "default", legacyWindowWidth: 144))
            store.save(NSPoint(x: CGFloat.infinity, y: 10), forKey: "default")
            XCTAssertNil(store.anchor(forKey: "default", legacyWindowWidth: 144))
            defaults.set(Data("not-json".utf8), forKey: PetWindowPositionStore.anchorsKey)
            store.save(NSPoint(x: 80, y: 90), forKey: "default")
            XCTAssertEqual(store.anchor(forKey: "default", legacyWindowWidth: 144), NSPoint(x: 80, y: 90))
        }
    }

    func testMonitorRemovalClampsPetFootprintRatherThanTallBubble() throws {
        var placement = PetWindowPlacement(anchor: NSPoint(x: 2200, y: 1500))
        placement.fitAnchor(petSize: NSSize(width: 144, height: 144), visible: visible)
        let expected = NSPoint(x: 1440, y: 781)
        XCTAssertEqual(placement.anchor, expected)
        let tall = try XCTUnwrap(placement.layout(size: NSSize(width: 500, height: 600), petWidth: 120, visible: visible))
        XCTAssertEqual(tall.frame.minY, 325)
        XCTAssertEqual(placement.anchor, expected)
        let small = try XCTUnwrap(placement.layout(size: NSSize(width: 144, height: 144), petWidth: 120, visible: visible))
        XCTAssertEqual(small.frame.minY, expected.y)
    }

    func testNegativeScreenCoordinatesAndPetSizeChangeKeepAnchor() throws {
        let screen = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
        var placement = PetWindowPlacement(anchor: NSPoint(x: -1700, y: -120))
        for petWidth: CGFloat in [80, 120, 200] {
            placement.fitAnchor(petSize: NSSize(width: petWidth + 24, height: petWidth + 24), visible: screen)
            let layout = try XCTUnwrap(placement.layout(size: NSSize(width: 600, height: 300), petWidth: petWidth, visible: screen))
            XCTAssertEqual(layout.frame.midX + layout.petOffset, -1700)
            XCTAssertEqual(placement.anchor, NSPoint(x: -1700, y: -120))
        }
    }
}
