import AppKit
import SwiftUI
import XCTest
import AgentPetCore
@testable import agentpet

@MainActor
final class DailyTokenUsageTooltipTests: XCTestCase {
    override nonisolated func setUpWithError() throws { try TestIsolation.require() }

    private var bundle: Bundle {
        ProcessInfo.processInfo.environment["AGENTPET_USAGE_LPROJ"].flatMap(Bundle.init(path:)) ?? .main
    }
    private func fixture() throws -> TokenUsageDay {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15))!
        return try .init(date: date, byAgent: [
            .dsh: .init(input: 1668, cacheRead: 2242, cacheWrite: 130, output: 1174),
            .codex: .init(input: 2460, cacheRead: 3305, cacheWrite: 192, output: 1729),
            .opencode: .init(input: 1397, cacheRead: 1877, cacheWrite: 109, output: 983),
            .agy: .init(input: 240, cacheRead: 323, cacheWrite: 19, output: 169)
        ], coverage: .complete)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

    private func trackingEvent(_ type: NSEvent.EventType, point: NSPoint, pointer: DailyTokenUsagePointerView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: pointer.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: pointer.window!.windowNumber,
            context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
    }
    private func enter(_ index: Int, pointer: DailyTokenUsagePointerView, staleLocation: Bool = false) throws {
        let area = try XCTUnwrap(pointer.trackingAreas.first { ($0.userInfo?["index"] as? Int) == index })
        let owner = try XCTUnwrap(area.owner as? NSResponder)
        owner.mouseEntered(with: try trackingEvent(.mouseEntered,
            point: staleLocation ? NSPoint(x: -1000, y: -1000) : NSPoint(x: area.rect.midX, y: area.rect.midY), pointer: pointer))
        settle()
    }
    private func leave(_ pointer: DailyTokenUsagePointerView) throws {
        for area in pointer.trackingAreas {
            (area.owner as? NSResponder)?.mouseExited(with: try trackingEvent(.mouseExited, point: NSPoint(x: -3, y: -3), pointer: pointer))
        }
        settle()
    }
    private func click(_ index: Int, pointer: DailyTokenUsagePointerView) throws {
        let area = try XCTUnwrap(pointer.trackingAreas.first { ($0.userInfo?["index"] as? Int) == index })
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: pointer.convert(NSPoint(x: area.rect.midX, y: area.rect.midY), to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: pointer.window!.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
            pointer.window!.sendEvent(event)
        }
        settle()
    }

    func testNativeTrackingShowsWithoutClickPinsPreviewsRestoresAndEscClosesOnlyTip() throws {
        _ = NSApplication.shared
        let template = try fixture()
        let days = (0..<30).map { index -> TokenUsageDay in
            .init(date: template.date.addingTimeInterval(Double(index) * 86_400),
                  byAgent: template.byAgent, coverage: template.coverage)
        }
        let host = NSHostingView(rootView: ScrollView { DailyTokenUsageView(snapshot: .init(days: days), bundle: bundle).padding(14).frame(width: 300).textSelection(.enabled).noFocusRing() }.frame(width: 300, height: 260))
        host.setFrameSize(host.fittingSize)
        let controller = PetStatsPanelController()
        controller.show(content: host, frame: NSRect(origin: NSPoint(x: 400, y: 300), size: host.frame.size), petBody: { nil }, animated: false)
        controller.makeKey()
        settle()
        let pointer = try XCTUnwrap(descendants(host).compactMap { $0 as? DailyTokenUsagePointerView }.first)
        defer { pointer.dispose(); controller.dismissImmediately() }
        XCTAssertEqual(pointer.bounds.width, 300 - 28 - 4 - 35 - 28, accuracy: 1, "Original outer margins, 30-day edge-label gutters and the external Y axis stay outside tracking columns")
        XCTAssertEqual(pointer.bounds.height, 112, accuracy: 1)
        XCTAssertTrue(pointer.window?.canBecomeKey == true)
        XCTAssertEqual(pointer.trackingAreas.count, 30)
        XCTAssertFalse(pointer.tip.isVisible)
        try enter(10, pointer: pointer, staleLocation: true)
        XCTAssertTrue(pointer.tip.isVisible, "Hover must show the real child card before any click")
        XCTAssertEqual(pointer.tip.displayedDate, days[10].date)
        XCTAssertTrue(controller.isShown, "Hover must not trigger outside-click dismissal")
        let parent = try XCTUnwrap(pointer.window)
        let child = try XCTUnwrap(parent.childWindows?.first)
        XCTAssertFalse(child.canBecomeKey); XCTAssertTrue(child.ignoresMouseEvents)
        XCTAssertFalse(child.hidesOnDeactivate, "A non-activating detail follows its visible Status parent even over other apps")
        try leave(pointer)
        XCTAssertFalse(pointer.tip.isVisible, "Unpinned hover closes on leaving the chart")

        try enter(10, pointer: pointer)
        try click(10, pointer: pointer)
        XCTAssertFalse(child.ignoresMouseEvents, "A pinned card stays open when the user clicks its contents")
        try enter(20, pointer: pointer)
        XCTAssertEqual(pointer.tip.displayedDate, days[20].date)
        let oldArea = try XCTUnwrap(pointer.trackingAreas.first { ($0.userInfo?["index"] as? Int) == 10 })
        (oldArea.owner as? NSResponder)?.mouseExited(with: try trackingEvent(.mouseExited,
            point: NSPoint(x: oldArea.rect.midX, y: oldArea.rect.midY), pointer: pointer))
        settle()
        XCTAssertEqual(pointer.tip.displayedDate, days[20].date, "A delayed exit from an older cell must not overwrite the current hover")
        try leave(pointer)
        XCTAssertEqual(pointer.tip.displayedDate, days[10].date, "Leaving a preview restores the pinned date")
        XCTAssertEqual(parent.childWindows?.count, 1, "Date changes reuse one child window")
        try click(10, pointer: pointer)
        XCTAssertFalse(pointer.tip.isVisible, "Clicking the pinned date again dismisses it")

        try enter(10, pointer: pointer)
        for (key, expected) in [(UInt16(123), days[9].date), (UInt16(124), days[10].date)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: parent.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
            NSApp.postEvent(event, atStart: true)
            if let delivered = NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) { NSApp.sendEvent(delivered) }
            settle()
            XCTAssertEqual(pointer.tip.displayedDate, expected)
        }
        try click(10, pointer: pointer)
        try enter(10, pointer: pointer)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        host.addSubview(field); parent.makeFirstResponder(field)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: parent.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        NSApp.postEvent(space, atStart: true)
        if let delivered = NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) { NSApp.sendEvent(delivered) }
        settle()
        XCTAssertTrue(child.ignoresMouseEvents, "Hover must not hijack another control's Space key and pin the chart")
        parent.makeFirstResponder(pointer); field.removeFromSuperview()
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: parent.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.postEvent(esc, atStart: true)
        if let delivered = NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) { NSApp.sendEvent(delivered) }
        settle()
        XCTAssertFalse(pointer.tip.isVisible)
        XCTAssertTrue(controller.isShown, "Escape dismisses the detail, leaving Status open")
        // Select 7 days through the real SwiftUI button, not a second preview.
        try enter(29, pointer: pointer); try click(29, pointer: pointer)
        XCTAssertTrue(pointer.tip.isVisible)
        func selectRange(x: CGFloat) throws {
            let location = host.convert(NSPoint(x: x, y: host.isFlipped ? 33 : host.bounds.height - 33), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: parent.windowNumber,
                    context: nil, eventNumber: 200, clickCount: 1, pressure: 1))
                parent.sendEvent(event)
            }
            settle()
        }
        try selectRange(x: 226)
        XCTAssertEqual(pointer.trackingAreas.count, 7, "The 7-day button must update the real tracking columns")
        XCTAssertFalse(pointer.tip.isVisible, "Changing range clears the old pinned card")
        try enter(0, pointer: pointer)
        XCTAssertEqual(pointer.tip.displayedDate, days[23].date)
        try selectRange(x: 263)
        XCTAssertEqual(pointer.trackingAreas.count, 30)
        XCTAssertFalse(pointer.tip.isVisible)

    }

    func testRangeChoiceSurvivesPanelRecreationAndPreviewDoesNotOverwriteIt() throws {
        _ = NSApplication.shared
        let suite = "AgentPet.Tests.Range." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let template = try fixture()
        let days = (0..<30).map { index in
            TokenUsageDay(date: template.date.addingTimeInterval(Double(index) * 86_400),
                byAgent: template.byAgent, coverage: template.coverage)
        }
        let frame = NSRect(x: 400, y: 300, width: 300, height: 300)
        func host(_ store: UserDefaults, window: DailyTokenUsagePresentation.Window? = nil) -> NSHostingView<some View> {
            NSHostingView(rootView: DailyTokenUsageView(snapshot: .init(days: days), bundle: bundle,
                window: window, preferences: store).padding(14).frame(width: 300))
        }
        func show(_ view: NSView) -> NSWindow {
            view.setFrameSize(view.fittingSize)
            let panel = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = view; panel.orderFront(nil); settle()
            return panel
        }
        func rangeClick(_ x: CGFloat, host: NSView, panel: NSWindow) throws {
            let point = host.convert(NSPoint(x: x, y: host.isFlipped ? 33 : host.bounds.height - 33), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 500, clickCount: 1, pressure: 1)))
            }
            settle()
        }
        let first = host(defaults), firstPanel = show(first)
        let firstPointer = try XCTUnwrap(descendants(first).compactMap { $0 as? DailyTokenUsagePointerView }.first)
        XCTAssertEqual(firstPointer.trackingAreas.count, 30)
        try rangeClick(226, host: first, panel: firstPanel)
        XCTAssertEqual(firstPointer.trackingAreas.count, 7)
        XCTAssertEqual(defaults.integer(forKey: DailyTokenUsagePresentation.windowPreferenceKey), 7)
        firstPanel.close(); defaults.synchronize()

        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        let second = host(reloaded), secondPanel = show(second)
        defer { secondPanel.close() }
        let secondPointer = try XCTUnwrap(descendants(second).compactMap { $0 as? DailyTokenUsagePointerView }.first)
        XCTAssertEqual(secondPointer.trackingAreas.count, 7, "A newly created panel must restore the last selection")
        try enter(0, pointer: secondPointer)
        XCTAssertEqual(secondPointer.tip.displayedDate, days[23].date)
        try leave(secondPointer)
        let preview = host(reloaded, window: .month), previewPanel = show(preview)
        let previewPointer = try XCTUnwrap(descendants(preview).compactMap { $0 as? DailyTokenUsagePointerView }.first)
        XCTAssertEqual(previewPointer.trackingAreas.count, 30)
        try rangeClick(263, host: preview, panel: previewPanel)
        XCTAssertEqual(reloaded.integer(forKey: DailyTokenUsagePresentation.windowPreferenceKey), 7,
                       "Explicit preview ranges must not overwrite the real preference")
        previewPanel.close()
        try rangeClick(263, host: second, panel: secondPanel)
        XCTAssertEqual(reloaded.integer(forKey: DailyTokenUsagePresentation.windowPreferenceKey), 30)
        secondPanel.close()
        reloaded.set(999, forKey: DailyTokenUsagePresentation.windowPreferenceKey)
        let fallback = host(reloaded), fallbackPanel = show(fallback)
        defer { fallbackPanel.close() }
        let fallbackPointer = try XCTUnwrap(descendants(fallback).compactMap { $0 as? DailyTokenUsagePointerView }.first)
        XCTAssertEqual(fallbackPointer.trackingAreas.count, 30, "Unsupported saved values fall back safely")
    }

    func testCompactCardKeepsOnlyDailyAndAgentTotalsInBothAppearances() throws {
        let day = try fixture()
        XCTAssertEqual(day.total, 18_017)
        let directory = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"].map { URL(fileURLWithPath: $0) }
        var variants: [(String, TokenUsageDay, Bundle, ColorScheme)] = [("tip-light", day, bundle, .light), ("tip-dark", day, bundle, .dark)]
        for language in ["en", "zh-Hant", "vi"] {
            if let lproj = ProcessInfo.processInfo.environment["AGENTPET_USAGE_LPROJ"],
               let localization = Bundle(path: URL(fileURLWithPath: lproj).deletingLastPathComponent().appendingPathComponent(language + ".lproj").path) {
                variants.append(("tip-" + language, day, localization, .light))
            }
        }
        var partial = day; partial.coverage = .partial
        variants += [("tip-partial", partial, bundle, .light),
                     ("tip-pinned", partial, bundle, .light),
                     ("tip-missing", .init(date: day.date, coverage: .unknown), bundle, .light),
                     ("tip-before-start", .init(date: day.date, coverage: .notStarted), bundle, .light),
                     ("tip-zero", .init(date: day.date, coverage: .complete), bundle, .light)]
        for (name, day, bundle, scheme) in variants {
            let host = NSHostingView(rootView: DailyTokenUsageTipView(day: day, pinned: name == "tip-pinned", bundle: bundle).environment(\.colorScheme, scheme))
            host.setFrameSize(host.fittingSize)
            XCTAssertEqual(host.fittingSize.width, 246, accuracy: 1)
            XCTAssertLessThan(host.fittingSize.height, 200, "Only the date, total, and Agent rows belong in the tooltip")
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.orderFront(nil); settle(); host.layoutSubtreeIfNeeded()
            if let directory {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
            }
            window.close()
        }
    }

    func testTipFitsDisplayEdgesAndPrefersSpaceBesideStatus() {
        for screen in [NSRect(x: 0, y: 25, width: 1440, height: 875), NSRect(x: -800, y: -300, width: 800, height: 600), NSRect(x: 0, y: 0, width: 320, height: 420)] {
            for x in [screen.minX + 8, screen.midX - 150, screen.maxX - 308] {
                for y in [screen.minY, screen.maxY - 300] {
                    let parent = NSRect(x: x, y: y, width: 300, height: 300)
                    let chart = NSRect(x: x + 14, y: y + 60, width: 272, height: 112)
                    let frame = DailyTokenUsageTipController.frame(column: chart, chart: chart, parent: parent,
                        size: NSSize(width: 246, height: 250), visible: screen)
                    XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
                }
            }
        }
        let parent = NSRect(x: 900, y: 100, width: 300, height: 500)
        let frame = DailyTokenUsageTipController.frame(column: parent, chart: parent, parent: parent,
            size: NSSize(width: 246, height: 250), visible: NSRect(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertLessThan(frame.maxX, parent.minX, "A right-edge Status should place its detail to the left")
    }
}
