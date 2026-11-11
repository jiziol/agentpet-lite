import AppKit
import SwiftUI
import XCTest
@testable import AgentPetCore
@testable import agentpet

final class TaskBubbleClickThroughPolicyTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_000)

    private func session(_ kind: AgentKind, _ id: String, _ state: AgentState = .working) -> AgentSession {
        AgentSession(id: id, agentKind: kind, state: state, source: .hook, updatedAt: at)
    }

    private func failedSession(_ kind: AgentKind, _ id: String) -> AgentSession {
        var value = session(kind, id, .done)
        value.notificationVersion = 1
        switch kind {
        case .dsh:
            value.dsh = DSHObservation(
                schema: 1, profileID: String(repeating: "a", count: 24),
                hostID: "11111111-1111-4111-8111-111111111111",
                hostStartedAt: at.addingTimeInterval(-10), nativeSessionID: id,
                revision: 1, nativeSeq: 1, turn: 1, phase: .done, result: .failed,
                pending: [], startedAt: at, endedAt: at.addingTimeInterval(1),
                baseline: false, heartbeat: false, gap: false, navigationSocket: nil)
        case .antigravity:
            value.antigravityTurnResult = .failed
        case .opencode:
            value.opencodeTurnResult = .failed
        case .pi:
            value.piTurnResult = .failed
        default:
            value.codexTurnResult = .failed
        }
        return value
    }

    func testPreferenceOffStaysInteractiveAndOnNeedsAVisibleBubble() {
        XCTAssertEqual(TaskBubbleClickThroughPolicy.status(
            preferenceEnabled: false, bubbleVisible: true, requiresManualHandling: false), .off)
        XCTAssertEqual(TaskBubbleClickThroughPolicy.status(
            preferenceEnabled: true, bubbleVisible: false, requiresManualHandling: true), .off)
        XCTAssertEqual(TaskBubbleClickThroughPolicy.status(
            preferenceEnabled: true, bubbleVisible: true, requiresManualHandling: false), .active)
        XCTAssertEqual(TaskBubbleClickThroughPolicy.status(
            preferenceEnabled: true, bubbleVisible: true, requiresManualHandling: true), .suspended)
    }

    func testFeedbackNeverClaimsPassThroughWhileManualHandlingIsDisplayed() {
        XCTAssertEqual(TaskBubbleClickThroughPolicy.feedback(
            preferenceEnabled: false, requiresManualHandling: true), .disabled)
        XCTAssertEqual(TaskBubbleClickThroughPolicy.feedback(
            preferenceEnabled: true, requiresManualHandling: true), .suspended)
        XCTAssertEqual(TaskBubbleClickThroughPolicy.feedback(
            preferenceEnabled: true, requiresManualHandling: false), .enabled)
    }

    func testEverySupportedSourceSuspendsOnWaitingAndFailure() {
        let kinds: [AgentKind] = [.codex, .antigravity, .opencode, .dsh, .pi, .claude, .unknown]
        for kind in kinds {
            let waiting = session(kind, "waiting-\(kind.rawValue)", .waiting)
            XCTAssertTrue(BubblePresentation.Row(session: waiting).requiresManualHandling,
                          "waiting \(kind.rawValue)")

            let failed = failedSession(kind, "failed-\(kind.rawValue)")
            XCTAssertEqual(failed.taskResult, .failed, "\(kind.rawValue) fixture result")
            XCTAssertTrue(BubblePresentation.Row(session: failed).requiresManualHandling,
                          "failed \(kind.rawValue)")

            var approval = session(kind, "approval-\(kind.rawValue)", .waiting)
            approval.pendingApproval = .init(requestId: "req-\(kind.rawValue)",
                                             toolName: "Bash", summary: "deploy")
            XCTAssertTrue(BubblePresentation.Row(session: approval).requiresManualHandling,
                          "approval \(kind.rawValue)")
        }
    }

    func testCompletedReadAndCancelledRowsDoNotSuspend() {
        var completed = session(.codex, "completed", .done)
        completed.codexTurnResult = .completed
        completed.notificationVersion = 1
        XCTAssertFalse(BubblePresentation.Row(session: completed).requiresManualHandling)

        var readFailure = failedSession(.codex, "read-failure")
        readFailure.readThroughVersion = readFailure.notificationVersion
        readFailure.readAt = at
        readFailure.readDisplayRevision = readFailure.displayRevision ?? 0
        XCTAssertTrue(BubblePresentation.Row(session: readFailure).requiresManualHandling,
                      "A displayed failed result remains a human-handling row until it leaves the bubble")

        var cancelled = session(.codex, "cancelled", .done)
        cancelled.codexTurnResult = .cancelled
        XCTAssertFalse(BubblePresentation.Row(session: cancelled).requiresManualHandling)
    }

    func testItemsBeyondTheDisplayCapResumeOnlyWhenTheSameBubbleExpands() {
        var first = session(.codex, "cap-working-1", .working)
        first.title = "first"
        var second = session(.codex, "cap-working-2", .working)
        second.title = "second"
        let failed = failedSession(.codex, "cap-failed-hidden")
        let configuration = BubblePresentation.Configuration(
            sessionGrouping: .allSessions, displayMode: .list, maxSessions: 2,
            now: at.addingTimeInterval(1), readResultRetention: .threeSeconds)
        let collapsed = BubblePresentation.groups([first, second, failed],
                                                   settings: configuration, expanded: false)
        XCTAssertEqual(collapsed.count, 2)
        XCTAssertFalse(TaskBubbleClickThroughPolicy.requiresManualHandling(collapsed),
                       "An item beyond the existing display cap is not part of the collapsed bubble")
        XCTAssertEqual(TaskBubbleClickThroughPolicy.status(
            preferenceEnabled: true, bubbleVisible: true,
            requiresManualHandling: TaskBubbleClickThroughPolicy.requiresManualHandling(collapsed)),
                       .active)

        // Hovering the pet sets messageListExpanded; the same display cap then
        // opens and the now-visible failed row restores interaction.
        let expanded = BubblePresentation.groups([first, second, failed],
                                                  settings: configuration, expanded: true)
        XCTAssertEqual(expanded.count, 3)
        XCTAssertTrue(TaskBubbleClickThroughPolicy.requiresManualHandling(expanded))
        XCTAssertEqual(TaskBubbleClickThroughPolicy.status(
            preferenceEnabled: true, bubbleVisible: true,
            requiresManualHandling: TaskBubbleClickThroughPolicy.requiresManualHandling(expanded)),
                       .suspended)
    }

    func testTeamLeadPromptSuspendsButLeadlessUnknownDoesNot() {
        var lead = session(.codex, "team-lead", .waiting)
        lead.pendingApproval = .init(requestId: "team-req", toolName: "Bash", summary: "ship")
        let leadRow = BubblePresentation.Row(session: lead, team: .init(
            id: "team_a", name: "Team Alpha", leaderMissing: false))
        XCTAssertTrue(leadRow.requiresManualHandling)

        var member = session(.codex, "team-member", .waiting)
        member.pendingApproval = .init(requestId: "member-req", toolName: "Bash", summary: "ship")
        let leadlessRow = BubblePresentation.Row(session: member, team: .init(
            id: "team_a", name: "Team Alpha", leaderMissing: true))
        XCTAssertFalse(leadlessRow.requiresManualHandling,
                       "A lead-less Team row shows only the explicit unknown state, not a member's prompt")
    }
}

@MainActor
final class TaskBubbleClickThroughCompactRenderTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 3_000)

    override nonisolated func setUpWithError() throws {
        try TestIsolation.require()
    }

    private func member(_ state: AgentState = .waiting) -> AgentSession {
        var value = AgentSession(id: "compact-member", agentKind: .codex, state: state,
                                 source: .hook, updatedAt: at)
        value.title = "compact member"
        value.aionUiConversation = .init(id: "chat-compact", nativeSessionID: value.id,
                                         agentKind: .codex, teamID: "team_compact",
                                         teamName: "Compact Team", teamRole: .teammate)
        value.pendingApproval = .init(requestId: "compact-req", toolName: "Bash", summary: "deploy")
        return value
    }

    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.environment(\.animationsEnabled, false))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// The production Allow/Deny row uses fixed green/red action tints. Counting
    /// those pixels checks what the compact hierarchy actually draws rather
    /// than only re-reading the policy helper.
    private func actionColorCounts(_ bitmap: NSBitmapImageRep) throws -> (green: Int, red: Int) {
        var green = 0, red = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y))?.usingColorSpace(.deviceRGB),
                      c.alphaComponent > 0.4 else { continue }
                if c.greenComponent > 0.55, c.redComponent < 0.35, c.blueComponent < 0.55 { green += 1 }
                if c.redComponent > 0.65, c.greenComponent < 0.4, c.blueComponent < 0.4 { red += 1 }
            }
        }
        return (green, red)
    }

    private func withReadableSettings(_ body: () throws -> Void) throws {
        let settings = BubbleSettings.shared
        let old = (settings.opacity, settings.textOpacity, settings.theme, settings.fontSize)
        settings.opacity = 0.4; settings.textOpacity = 1
        settings.theme = .dark; settings.fontSize = .large
        defer {
            settings.opacity = old.0; settings.textOpacity = old.1
            settings.theme = old.2; settings.fontSize = old.3
        }
        try body()
    }

    func testLeadlessCompactDrawsUnknownNotMemberApprovalAndStaysPassThrough() throws {
        _ = NSApplication.shared
        try withReadableSettings {
            let carrier = member()
            let group = GroupedSession(session: carrier, count: 1,
                                       team: .init(id: "team_compact", name: "Compact Team",
                                                   leaderMissing: true))
            // Sensitivity control: the same carrier without Team identity does
            // draw the Allow/Deny action colors.
            let plain = try actionColorCounts(try render(
                SessionBubbleRow(session: carrier)
                    .environmentObject(BubbleSettings.shared).padding(24)))
            XCTAssertGreaterThan(plain.green, 10)
            XCTAssertGreaterThan(plain.red, 10)

            let compact = try actionColorCounts(try render(
                BubbleCompactLayout(groups: [group], totalCount: 1)
                    .environmentObject(BubbleSettings.shared).padding(24)))
            XCTAssertEqual(compact.green, 0,
                           "Compact must not draw a member's Allow control for a leadless Team")
            XCTAssertEqual(compact.red, 0,
                           "Compact must not draw a member's Deny control for a leadless Team")

            XCTAssertFalse(TaskBubbleClickThroughPolicy.requiresManualHandling([group]))
            XCTAssertEqual(TaskBubbleClickThroughPolicy.status(
                preferenceEnabled: true, bubbleVisible: true,
                requiresManualHandling: TaskBubbleClickThroughPolicy.requiresManualHandling([group])),
                           .active)
        }
    }

    func testLeadedCompactDrawsApprovalAndPolicyRestoresInteraction() throws {
        _ = NSApplication.shared
        try withReadableSettings {
            let lead = member()
            let group = GroupedSession(session: lead, count: 1,
                                       team: .init(id: "team_compact", name: "Compact Team",
                                                   leaderMissing: false))
            let compact = try actionColorCounts(try render(
                BubbleCompactLayout(groups: [group], totalCount: 1)
                    .environmentObject(BubbleSettings.shared).padding(24)))
            XCTAssertGreaterThan(compact.green, 10)
            XCTAssertGreaterThan(compact.red, 10)
            XCTAssertTrue(TaskBubbleClickThroughPolicy.requiresManualHandling([group]))
            XCTAssertEqual(TaskBubbleClickThroughPolicy.status(
                preferenceEnabled: true, bubbleVisible: true,
                requiresManualHandling: TaskBubbleClickThroughPolicy.requiresManualHandling([group])),
                           .suspended)
        }
    }

    func testLeadedCompactWaitingAndFailureAreManualHandlingRows() {
        var waiting = member(.waiting)
        waiting.pendingApproval = nil
        XCTAssertTrue(BubblePresentation.Row(
            session: waiting,
            team: .init(id: "team_compact", name: "Compact Team", leaderMissing: false)
        ).requiresManualHandling)

        var failed = member(.done)
        failed.pendingApproval = nil
        failed.notificationVersion = 1
        failed.codexTurnResult = .failed
        XCTAssertTrue(BubblePresentation.Row(
            session: failed,
            team: .init(id: "team_compact", name: "Compact Team", leaderMissing: false)
        ).requiresManualHandling)
    }
}

@MainActor
final class TaskBubbleClickThroughWindowTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 2_000)
    private var settings: BubbleSettings { .shared }
    nonisolated private static let anchorsKey = "agentpet.petAnchors.v1"
    private nonisolated(unsafe) var savedAnchors: Any?
    private nonisolated(unsafe) var didPrepareAnchors = false

    override nonisolated func setUpWithError() throws {
        didPrepareAnchors = false
        try TestIsolation.require()
        savedAnchors = UserDefaults.standard.object(forKey: Self.anchorsKey)
        didPrepareAnchors = true
        // These tests need a deterministic on-screen pet; other classes may
        // have left a saved top-edge anchor that prevents a task bubble from
        // fitting above the pet.
        UserDefaults.standard.removeObject(forKey: Self.anchorsKey)
    }

    override nonisolated func tearDown() {
        defer { super.tearDown() }
        guard didPrepareAnchors else { return }
        didPrepareAnchors = false
        if let savedAnchors {
            UserDefaults.standard.set(savedAnchors, forKey: Self.anchorsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.anchorsKey)
        }
    }

    private func session(_ id: String, _ state: AgentState = .working) -> AgentSession {
        var value = AgentSession(id: id, agentKind: .codex, state: state, source: .hook, updatedAt: at)
        value.title = id
        return value
    }

    private func sync(_ controller: PetWindowController, _ sessions: [AgentSession]) {
        let specs = PetWindowPlanner.plan(sessions: sessions, split: false, mappings: [],
                                          defaultPetID: "click-through-preview")
        controller.sync(specs: specs) { _ in
            .init(petID: "click-through-preview", mood: .working, sessions: sessions,
                  count: sessions.count, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    private func taskModel(_ window: NSWindow) throws -> PetWindowModel {
        let scroll = try XCTUnwrap(window.contentView as? NSScrollView)
        let host = try XCTUnwrap(scroll.documentView as? ClickThroughHostingView<PetTaskPanelView>)
        return host.rootView.model
    }

    private func bodyModel(_ window: NSWindow) throws -> PetWindowModel {
        let host = try XCTUnwrap(window.contentView as? ClickThroughHostingView<FloatingPetView>)
        return host.rootView.model
    }

    func testTaskPanelFollowsPreferenceAndManualRowsWithoutChangingThePreference() throws {
        _ = NSApplication.shared
        let savedPreference = settings.taskBubbleClickThrough
        let savedSuperchat = settings.superchatEnabled
        settings.taskBubbleClickThrough = false
        settings.superchatEnabled = true
        let notices = PetController.shared.systemNotices
        notices.clear()
        let controller = PetWindowController()
        defer {
            controller.stop(); notices.clear()
            settings.taskBubbleClickThrough = savedPreference
            settings.superchatEnabled = savedSuperchat
        }
        let before = Set(NSApp.windows.map(\.windowNumber))
        let working = session("click-through-working")
        sync(controller, [working])

        let newWindows = NSApp.windows.filter { !before.contains($0.windowNumber) }
        let body = try XCTUnwrap(newWindows.first { $0.title == "AgentPet Lite Body" })
        let task = try XCTUnwrap(newWindows.first { $0.title == "AgentPet Lite Tasks" })
        let host = try XCTUnwrap(body.contentView as? ClickThroughHostingView<FloatingPetView>)
        let model = host.rootView.model

        XCTAssertFalse(body.ignoresMouseEvents, "The pet body stays interactive")
        XCTAssertFalse(task.ignoresMouseEvents)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .off)

        settings.taskBubbleClickThrough = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertTrue(task.ignoresMouseEvents)
        XCTAssertFalse(body.ignoresMouseEvents)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .active)

        var waiting = working
        waiting.state = .waiting
        waiting.message = "Waiting for input"
        let otherWorking = session("click-through-other")
        sync(controller, [working, waiting, otherWorking])
        XCTAssertTrue(settings.taskBubbleClickThrough, "Manual handling must not overwrite the saved preference")
        XCTAssertFalse(task.ignoresMouseEvents, "One manual row makes the whole shared bubble interactive")
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .suspended)

        controller.toggleTaskBubbleClickThrough(forKey: "default")
        XCTAssertFalse(settings.taskBubbleClickThrough)
        XCTAssertFalse(task.ignoresMouseEvents)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .off)
        XCTAssertEqual(notices.current?.kind, .clickThroughOff)
        XCTAssertTrue(model.petReactionLine.isEmpty, "The old pet-line feedback is not used")

        controller.toggleTaskBubbleClickThrough(forKey: "default")
        XCTAssertTrue(settings.taskBubbleClickThrough)
        XCTAssertFalse(task.ignoresMouseEvents)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .suspended,
                       "Turning it on during manual handling still yields an interactive window")
        XCTAssertEqual(notices.current?.kind, .clickThroughPaused)
        XCTAssertEqual(notices.current?.body,
                       SystemNotice.text("Could not enable. Handle waiting tasks first", "开启失败，请优先处理等待任务"))

        sync(controller, [working])
        XCTAssertTrue(settings.taskBubbleClickThrough)
        XCTAssertTrue(task.ignoresMouseEvents)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .active)

        var failed = working
        failed.state = .done
        failed.codexTurnResult = .failed
        failed.notificationVersion = 1
        sync(controller, [failed])
        XCTAssertFalse(task.ignoresMouseEvents)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .suspended)

        var approval = working
        approval.state = .waiting
        approval.pendingApproval = .init(requestId: "req", toolName: "Bash", summary: "deploy")
        sync(controller, [approval])
        XCTAssertFalse(task.ignoresMouseEvents)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .suspended)

        sync(controller, [working])
        XCTAssertTrue(task.ignoresMouseEvents)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .active)

        settings.taskBubbleClickThrough = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertFalse(task.ignoresMouseEvents)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .off)
        XCTAssertFalse(body.ignoresMouseEvents)
    }

    func testPersistedPreferenceWithManualRowIsInteractiveOnFirstSyncAndAfterRebuild() throws {
        _ = NSApplication.shared
        let savedPreference = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = true
        let controller = PetWindowController()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = savedPreference
        }
        var waiting = session("first-frame-waiting", .waiting)
        waiting.message = "Waiting for approval"
        waiting.pendingApproval = .init(requestId: "first-frame-req", toolName: "Bash", summary: "ship")
        let specs = PetWindowPlanner.plan(sessions: [waiting], split: false, mappings: [],
                                          defaultPetID: "first-frame-preview")
        let state: (PetWindowSpec) -> PetWindowController.WindowState = { _ in
            .init(petID: "first-frame-preview", mood: .working, sessions: [waiting],
                  count: 1, chatLine: "")
        }
        let before = Set(NSApp.windows.map(\.windowNumber))
        controller.sync(specs: specs, stateFor: state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        func findTask() throws -> (NSWindow, PetWindowModel) {
            let task = try XCTUnwrap(NSApp.windows.first {
                $0.title == "AgentPet Lite Tasks" && !before.contains($0.windowNumber)
                    && ($0.isVisible)
            })
            return (task, try taskModel(task))
        }
        var (task, model) = try findTask()
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .suspended)
        XCTAssertFalse(task.ignoresMouseEvents,
                       "A persisted preference plus a displayed manual row is interactive on the first sync")
        XCTAssertTrue(task.isVisible)

        // Rebuild the same window from scratch; the first frame must use the
        // persisted preference and the manual row again, not a transient active.
        controller.sync(specs: [], stateFor: state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.sync(specs: specs, stateFor: state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        (task, model) = try findTask()
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .suspended)
        XCTAssertFalse(task.ignoresMouseEvents)
        let body = try XCTUnwrap(NSApp.windows.first {
            $0.title == "AgentPet Lite Body" && !before.contains($0.windowNumber) && $0.isVisible
        })
        XCTAssertFalse(body.ignoresMouseEvents)
    }

    func testMultiplePetWindowsFollowTheSharedPreferenceAndPerWindowManualRows() throws {
        _ = NSApplication.shared
        let savedPreference = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = false
        let controller = PetWindowController()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = savedPreference
        }
        let first = session("multi-first")
        var second = session("multi-second")
        let specs = [
            PetWindowSpec(key: "default", projectName: nil, petID: "multi-a",
                          sessionIDs: [first.id], mood: .working, count: 1),
            PetWindowSpec(key: "/project/multi", projectName: "multi", petID: "multi-b",
                          sessionIDs: [second.id], mood: .working, count: 1)
        ]
        func state(for spec: PetWindowSpec) -> PetWindowController.WindowState {
            let sessions = spec.key == "default" ? [first] : [second]
            return .init(petID: spec.petID, mood: .working, sessions: sessions,
                         count: 1, chatLine: "")
        }
        let before = Set(NSApp.windows.map(\.windowNumber))
        controller.sync(specs: specs, stateFor: state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var tasks = NSApp.windows.filter { $0.title == "AgentPet Lite Tasks"
            && !before.contains($0.windowNumber) && $0.isVisible }
        XCTAssertEqual(tasks.count, 2)
        var byKey: [String: (NSWindow, PetWindowModel)] = [:]
        for task in tasks {
            let model = try taskModel(task)
            byKey[model.key] = (task, model)
        }
        XCTAssertFalse(try XCTUnwrap(byKey["default"]).0.ignoresMouseEvents)
        XCTAssertFalse(try XCTUnwrap(byKey["/project/multi"]).0.ignoresMouseEvents)

        settings.taskBubbleClickThrough = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        for key in ["default", "/project/multi"] {
            let (task, model) = try XCTUnwrap(byKey[key])
            XCTAssertTrue(task.ignoresMouseEvents)
            XCTAssertEqual(model.taskBubbleClickThroughStatus, .active)
        }

        second = session("multi-second-waiting", .waiting)
        second.message = "Waiting"
        controller.sync(specs: specs, stateFor: state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        tasks = NSApp.windows.filter { $0.title == "AgentPet Lite Tasks"
            && !before.contains($0.windowNumber) && $0.isVisible }
        byKey.removeAll()
        for task in tasks {
            let model = try taskModel(task)
            byKey[model.key] = (task, model)
        }
        let (firstTask, firstModel) = try XCTUnwrap(byKey["default"])
        let (secondTask, secondModel) = try XCTUnwrap(byKey["/project/multi"])
        XCTAssertTrue(firstTask.ignoresMouseEvents)
        XCTAssertEqual(firstModel.taskBubbleClickThroughStatus, .active)
        XCTAssertFalse(secondTask.ignoresMouseEvents)
        XCTAssertEqual(secondModel.taskBubbleClickThroughStatus, .suspended)

        settings.taskBubbleClickThrough = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(firstTask.ignoresMouseEvents)
        XCTAssertFalse(secondTask.ignoresMouseEvents)
    }

    func testHoverExpansionRevealsBeyondCapManualRowAndRestoresInteraction() throws {
        _ = NSApplication.shared
        let saved = (settings.taskBubbleClickThrough, settings.displayMode,
                     settings.maxSessions, settings.sessionGrouping, settings.minStateFilter)
        settings.taskBubbleClickThrough = true
        settings.displayMode = .list
        settings.maxSessions = 2
        settings.sessionGrouping = .allSessions
        settings.minStateFilter = .all
        let controller = PetWindowController()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = saved.0
            settings.displayMode = saved.1
            settings.maxSessions = saved.2
            settings.sessionGrouping = saved.3
            settings.minStateFilter = saved.4
        }
        let first = session("cap-hover-first")
        let second = session("cap-hover-second")
        var failed = session("cap-hover-failed", .done)
        failed.codexTurnResult = .failed
        failed.notificationVersion = 1
        let before = Set(NSApp.windows.map(\.windowNumber))
        sync(controller, [first, second, failed])
        let newWindows = NSApp.windows.filter { !before.contains($0.windowNumber) }
        let task = try XCTUnwrap(newWindows.first { $0.title == "AgentPet Lite Tasks" })
        let body = try XCTUnwrap(newWindows.first { $0.title == "AgentPet Lite Body" })
        let model = try bodyModel(body)
        XCTAssertTrue(task.ignoresMouseEvents, "The failed row is beyond the collapsed display cap")
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .active)

        model.hoverBody(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(task.ignoresMouseEvents,
                       "Hover expansion makes the failed row part of the displayed bubble")
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .suspended)

        model.hoverBody(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(task.ignoresMouseEvents)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .active)
    }

    func testNoAnchorHidesTasksAndPublishesOffWithoutTouchingThePet() throws {
        _ = NSApplication.shared
        let savedPreference = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = true
        let controller = PetWindowController()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = savedPreference
        }
        let before = Set(NSApp.windows.map(\.windowNumber))
        sync(controller, [session("no-anchor-working")])
        let newWindows = NSApp.windows.filter { !before.contains($0.windowNumber) }
        let task = try XCTUnwrap(newWindows.first { $0.title == "AgentPet Lite Tasks" })
        let body = try XCTUnwrap(newWindows.first { $0.title == "AgentPet Lite Body" })
        let model = try taskModel(task)
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .active)
        XCTAssertTrue(task.ignoresMouseEvents)

        controller.clearTaskBubbleAnchorForTesting(key: "default")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(model.taskBubbleClickThroughStatus, .off)
        XCTAssertFalse(task.isVisible)
        XCTAssertFalse(body.ignoresMouseEvents, "The pet remains interactive")
    }

    func testPreferenceDefaultsOffPersistsAndRestoresWithoutManualRows() {
        let key = "agentpet.bubble.taskBubbleClickThrough"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(BubbleSettings().taskBubbleClickThrough)

        let saved = BubbleSettings()
        saved.taskBubbleClickThrough = true
        XCTAssertTrue(BubbleSettings().taskBubbleClickThrough)
        saved.taskBubbleClickThrough = false
        XCTAssertFalse(BubbleSettings().taskBubbleClickThrough)
    }

}
