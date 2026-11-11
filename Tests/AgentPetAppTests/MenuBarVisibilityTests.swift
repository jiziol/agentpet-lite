import AppKit
import XCTest
@testable import agentpet

@MainActor
final class MenuBarVisibilityTests: XCTestCase {
    func testActualNativeStatusItemHidesRestoresAndRespectsSavedHiddenChoice() {
        _ = NSApplication.shared
        let key = "agentpet.menuBarHidden"
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: key)
        defer {
            if let before { defaults.set(before, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let bar = StatusBarController()
        bar.menuBarHidden = false; bar.start()
        XCTAssertTrue(bar.menuBarIconVisible)
        bar.menuBarHidden = true
        XCTAssertFalse(bar.menuBarIconVisible)
        XCTAssertTrue(defaults.bool(forKey: key))
        bar.stop()
        let restored = StatusBarController(); restored.start()
        XCTAssertTrue(restored.menuBarHidden); XCTAssertFalse(restored.menuBarIconVisible)
        restored.menuBarHidden = false
        XCTAssertTrue(restored.menuBarIconVisible)
        restored.stop(); XCTAssertFalse(restored.menuBarIconVisible)
    }
}
