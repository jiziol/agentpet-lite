import AppKit
import SwiftUI
import XCTest
@testable import agentpet

@MainActor
final class AppAppearanceTests: XCTestCase {
    private let key = "agentpet.bubble.theme"
    private var savedTheme: Any?
    private var savedAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        savedTheme = UserDefaults.standard.object(forKey: key)
        savedAppearance = NSApplication.shared.appearance
    }

    override func tearDown() {
        UserDefaults.standard.set(savedTheme, forKey: key)
        NSApplication.shared.appearance = savedAppearance
        super.tearDown()
    }

    func testLightOverridesDarkAppAppearance() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let settings = BubbleSettings()
        settings.theme = .light
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        XCTAssertEqual(settings.theme.colorScheme, .light)
    }

    func testDarkOverridesLightAppAppearance() {
        NSApp.appearance = NSAppearance(named: .aqua)
        let settings = BubbleSettings()
        settings.theme = .dark
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        XCTAssertEqual(settings.theme.colorScheme, .dark)
    }

    func testSystemReleasesBothOverridesAfterSwitching() {
        let settings = BubbleSettings()
        settings.theme = .dark
        settings.theme = .light
        settings.theme = .system
        XCTAssertNil(NSApp.appearance)
        XCTAssertNil(settings.theme.colorScheme)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "system")
    }

    func testHostedContentReturnsToInheritedLightAfterDark() {
        assertHostedTransitions(inherited: .light, forced: .dark)
    }

    func testHostedContentReturnsToInheritedDarkAfterLight() {
        assertHostedTransitions(inherited: .dark, forced: .light)
    }

    private func assertHostedTransitions(inherited: ColorScheme, forced: BubbleSettings.Theme,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let settings = BubbleSettings.shared
        let original = settings.theme
        defer { settings.theme = original }
        settings.theme = .system
        let recorder = SchemeRecorder()
        // Offscreen host tests the SwiftUI environment, not just preference values.
        let host = NSHostingView(rootView: SchemeProbe(recorder: recorder)
            .appAppearance().environment(\.colorScheme, inherited))
        host.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        XCTAssertEqual(recorder.scheme, inherited, file: file, line: line)
        for _ in 0..<3 {
            settings.theme = forced
            settle()
            XCTAssertEqual(recorder.scheme, forced.colorScheme, file: file, line: line)
            settings.theme = .system
            settle()
            XCTAssertEqual(recorder.scheme, inherited, file: file, line: line)
            XCTAssertNil(NSApp.appearance, file: file, line: line)
        }
    }

    func testSavedThemeAppliesBeforeWindowsAreCreated() {
        UserDefaults.standard.set("light", forKey: key)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let settings = BubbleSettings()
        settings.applyAppearance()
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        XCTAssertEqual(BubbleSettings().theme, .light)
    }

    func testUnknownSavedValueFallsBackToSystem() {
        UserDefaults.standard.set("future-theme", forKey: key)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let settings = BubbleSettings()
        settings.applyAppearance()
        XCTAssertEqual(settings.theme, .system)
        XCTAssertNil(NSApp.appearance)
    }
}

@MainActor
private final class SchemeRecorder {
    var scheme: ColorScheme?
}

private struct SchemeProbe: View {
    @Environment(\.colorScheme) private var scheme
    let recorder: SchemeRecorder
    var body: some View {
        recorder.scheme = scheme
        return Rectangle().fill(scheme == .dark ? Color.black : Color.white)
    }
}
