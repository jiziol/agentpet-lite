import AppKit
import SwiftUI
import XCTest
import AgentPetCore
@testable import agentpet

@MainActor
final class TaskCleanupUITests: XCTestCase {
    override nonisolated func setUpWithError() throws { try TestIsolation.require() }

    private func session(_ id: String, state: AgentState = .done) -> AgentSession {
        var value = AgentSession(id: id, agentKind: .codex, title: id,
            state: state, source: .hook, updatedAt: Date())
        value.project = "/fixture/remote-project"
        value.notificationVersion = 1
        value.codexTurnID = "turn-1"
        if state == .done { value.codexTurnResult = .completed }
        return value
    }

    private func mount<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 20, y: 20), size: host.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func bitmap(_ view: NSView, rect: NSRect? = nil) throws -> Data {
        let rect = rect ?? view.bounds
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: image)
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    private func save(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"] else { return }
        try bitmap(view).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    private func clickFooter(_ host: NSView, window: NSWindow) throws {
        // The footer sits above the 7pt tail and 9pt bottom padding. Exercise
        // the actual SwiftUI Button through native events, including hit testing.
        let point = host.convert(CGPoint(x: host.bounds.maxX - 65,
            y: host.isFlipped ? host.bounds.maxY - 27 : 27), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    func testLongMenuFitsScreenAndClearButtonStaysOutsideScrollingRows() throws {
        let backlog = (0..<600).map { session("remote-\($0)") }
        for availableHeight: CGFloat in [600, 900] {
            let (window, host) = mount(MenuContentView(dismiss: {}, availableHeight: availableHeight,
                                                       sessionsOverride: backlog))
            defer { window.close() }
            XCTAssertLessThanOrEqual(host.fittingSize.height, availableHeight)
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
            XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height * 10)
            let header = NSRect(x: 0, y: host.isFlipped ? 0 : host.bounds.height - 100,
                                width: host.bounds.width, height: 100)
            let initialHeader = try bitmap(host, rect: header)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 2_000))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
            XCTAssertEqual(try bitmap(host, rect: header), initialHeader,
                           "The menu title and clear action must stay fixed while rows scroll")
            try save(host, name: "menu-backlog-\(Int(availableHeight))")
        }
    }

    func testBubbleButtonClearsBacklogBeyondDisplayCapAndProtectsActiveRows() throws {
        let settings = BubbleSettings.shared
        let saved = (settings.displayMode, settings.sessionGrouping, settings.maxSessions, settings.hiddenKinds)
        defer {
            settings.displayMode = saved.0; settings.sessionGrouping = saved.1
            settings.maxSessions = saved.2; settings.hiddenKinds = saved.3
        }
        settings.displayMode = .list; settings.sessionGrouping = .allSessions
        settings.maxSessions = 2; settings.hiddenKinds = []
        let backlog = (0..<90).map { session("ended-\($0)") }
        let active = session("working", state: .working)
        let waiting = session("waiting", state: .waiting)
        var cleared: Set<String> = []
        let (window, host) = mount(AgentBubble(sessions: [active, waiting] + backlog,
            interactionOverride: .init(clearEnded: { cleared = $0 })))
        defer { window.close() }
        try save(host, name: "task-bubble-clear")
        try clickFooter(host, window: window)
        XCTAssertEqual(cleared, Set(backlog.map(\.id)))
    }

    func testActiveOnlyBubbleHasNoClearAction() throws {
        var cleared: Set<String> = []
        let (window, host) = mount(AgentBubble(sessions: [session("working", state: .working)],
            interactionOverride: .init(clearEnded: { cleared = $0 })))
        defer { window.close() }
        try clickFooter(host, window: window)
        XCTAssertTrue(cleared.isEmpty)
    }

    func testFilteredHistoryCannotTriggerCleanupForThreeCurrentTasks() throws {
        let settings = BubbleSettings.shared
        let saved = (settings.displayMode, settings.sessionGrouping, settings.maxSessions,
                     settings.hiddenKinds, settings.readResultRetention)
        defer {
            settings.displayMode = saved.0; settings.sessionGrouping = saved.1
            settings.maxSessions = saved.2; settings.hiddenKinds = saved.3
            settings.readResultRetention = saved.4
        }
        settings.displayMode = .list; settings.sessionGrouping = .allSessions
        settings.maxSessions = 10; settings.hiddenKinds = []; settings.readResultRetention = .fiveSeconds
        let active = (0..<3).map { session("current-\($0)", state: .working) }
        let history = (0..<12).map { index -> AgentSession in
            var value = session("read-history-\(index)")
            value.readThroughVersion = value.notificationVersion
            value.readAt = Date().addingTimeInterval(-60)
            value.readDisplayRevision = value.displayRevision ?? 0
            return value
        }
        XCTAssertEqual(AgentBubble.visible(active + history, settings: settings).map(\.id).sorted(), active.map(\.id).sorted())
        var cleared: Set<String> = []
        let (window, host) = mount(AgentBubble(sessions: active + history,
            interactionOverride: .init(clearEnded: { cleared = $0 })))
        defer { window.close() }
        try clickFooter(host, window: window)
        XCTAssertTrue(cleared.isEmpty, "Expired, invisible history must not create a clear button for three active tasks")
        for count in [5, 6] {
            let eligible = (0..<count).map { session("eligible-\($0)") }
            cleared = []
            let (candidate, candidateHost) = mount(AgentBubble(sessions: eligible + history,
                interactionOverride: .init(clearEnded: { cleared = $0 })))
            try clickFooter(candidateHost, window: candidate)
            candidate.close()
            XCTAssertEqual(cleared, count > 5 ? Set(eligible.map(\.id)) : [],
                           "Only >5 eligible tasks can reveal cleanup, and hidden history must stay untouched")
        }
    }
}
