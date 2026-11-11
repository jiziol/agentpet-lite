import AppKit
import SwiftUI
import XCTest
import AgentPetCore
@testable import agentpet

final class ClickThroughNoticeClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100)

    private func feedback(enabled: Bool, suspended: Bool = false) -> SystemNotice {
        .clickThrough(enabled: enabled, suspended: suspended)
    }

    func testFeedbackUpdatesInPlaceAndTheLatestExpiryWins() {
        var clock = SystemNoticeClock()
        clock.post(feedback(enabled: true), now: start)
        clock.advance(now: start, visible: true)
        clock.advance(now: start.addingTimeInterval(2), visible: true)
        XCTAssertEqual(clock.current?.notice.kind, .clickThroughOn)
        XCTAssertEqual(clock.current?.remaining, 6)

        clock.post(feedback(enabled: false), now: start.addingTimeInterval(2))
        XCTAssertEqual(clock.current?.notice.kind, .clickThroughOff)
        XCTAssertEqual(clock.current?.remaining, 8, "The latest feedback gets a fresh short window")
        XCTAssertNil(clock.pending)

        clock.advance(now: start.addingTimeInterval(2), visible: true)
        clock.advance(now: start.addingTimeInterval(9.9), visible: true)
        XCTAssertNotNil(clock.current)
        clock.advance(now: start.addingTimeInterval(10.1), visible: true)
        XCTAssertNil(clock.current, "The old feedback deadline cannot replay after an update")
    }

    func testPriorityNoticeIsNotReplacedOrQueuedBehindFeedback() {
        var clock = SystemNoticeClock()
        clock.post(.init(id: "important", kind: .pomodoro, title: "Timer", body: "Focus done", legacyText: "Focus done"), now: start)
        clock.post(feedback(enabled: true), now: start.addingTimeInterval(1))
        XCTAssertEqual(clock.current?.notice.id, "important")
        XCTAssertNil(clock.pending)

        var feedbackFirst = SystemNoticeClock()
        feedbackFirst.post(feedback(enabled: true), now: start)
        feedbackFirst.post(.init(id: "important-2", kind: .lowQuota, title: "Quota", body: "Low", legacyText: "Low"),
                           now: start.addingTimeInterval(1))
        XCTAssertEqual(feedbackFirst.current?.notice.id, "important-2",
                       "A priority notice preempts low-priority feedback")
    }

    func testFeedbackDoesNotDelayADeferredPriorityNotice() {
        var clock = SystemNoticeClock()
        clock.post(.init(id: "quota", kind: .lowQuota, title: "Quota", body: "Low", legacyText: "Low"), now: start)
        clock.post(.init(id: "timer", kind: .pomodoro, title: "Timer", body: "Focus done", legacyText: "Focus done"),
                   now: start.addingTimeInterval(1))
        XCTAssertEqual(clock.pending?.notice.id, "timer")
        clock.post(feedback(enabled: true), now: start.addingTimeInterval(2))
        XCTAssertEqual(clock.current?.notice.id, "quota")
        XCTAssertEqual(clock.pending?.notice.id, "timer")
    }

    func testFeedbackExpiresWithoutQueuingAReplay() {
        var clock = SystemNoticeClock()
        clock.post(feedback(enabled: true), now: start)
        clock.advance(now: start, visible: true)
        clock.advance(now: start.addingTimeInterval(8), visible: true)
        XCTAssertNil(clock.current)
        XCTAssertNil(clock.pending)
    }
}

@MainActor
final class SuperchatClickThroughFeedbackTests: XCTestCase {
    override nonisolated func setUpWithError() throws {
        try TestIsolation.require()
    }

    private func notice(_ kind: SystemNotice.Kind) -> SystemNotice {
        switch kind {
        case .clickThroughOn: return .clickThrough(enabled: true)
        case .clickThroughPaused: return .clickThrough(enabled: true, suspended: true)
        default: return .clickThrough(enabled: false)
        }
    }

    func testFeedbackFactoryHasDistinctOnOffAndPausedSemantics() {
        let on = notice(.clickThroughOn), off = notice(.clickThroughOff), paused = notice(.clickThroughPaused)
        XCTAssertEqual(on.id, SystemNotice.clickThroughFeedbackID)
        XCTAssertEqual(on.id, off.id)
        XCTAssertEqual(on.id, paused.id)
        XCTAssertEqual(on.kind, .clickThroughOn)
        XCTAssertEqual(off.kind, .clickThroughOff)
        XCTAssertEqual(paused.kind, .clickThroughPaused)
        XCTAssertFalse(on.requiresAcknowledgment)
        XCTAssertFalse(off.requiresAcknowledgment)
        XCTAssertFalse(paused.requiresAcknowledgment)
        XCTAssertNotEqual(on.accentRGB.0, off.accentRGB.0)
        XCTAssertNotEqual(on.accentRGB.1, off.accentRGB.1)
        XCTAssertEqual(paused.accentRGB.0, 0.91, accuracy: 0.0001)
        XCTAssertEqual(paused.accentRGB.1, 0.54, accuracy: 0.0001)
        XCTAssertEqual(paused.accentRGB.2, 0.21, accuracy: 0.0001)
    }

    func testFeedbackNoticeRendersOnLightAndDarkBackgrounds() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let old = (settings.theme, settings.opacity, settings.textOpacity)
        settings.theme = .light; settings.opacity = 1; settings.textOpacity = 1
        defer {
            settings.theme = old.0; settings.opacity = old.1; settings.textOpacity = old.2
        }
        let center = SystemNoticeCenter(visible: { _ in false }, changed: {})
        for dark in [false, true] {
            settings.theme = dark ? .dark : .light
            for kind: SystemNotice.Kind in [.clickThroughOn, .clickThroughOff, .clickThroughPaused] {
                let renderer = ImageRenderer(content: SystemNoticeView(source: center, notice: notice(kind))
                    .environment(\.colorScheme, dark ? .dark : .light))
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                XCTAssertLessThanOrEqual(bitmap.pixelsWide, 760)
                XCTAssertGreaterThan(bitmap.pixelsWide, 160)
                XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 106)
                if kind != .clickThroughPaused {
                    XCTAssertEqual(bitmap.pixelsHigh, 106, "A short on/off message fits on one line")
                }
                if let directory = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"],
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("operation-\(kind)-\(dark ? "dark" : "light").png"))
                }
                var accentPixels = 0
                let rgb = notice(kind).accentRGB
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y))?.usingColorSpace(.deviceRGB) else { continue }
                        if c.alphaComponent > 0.4,
                           abs(c.redComponent - rgb.0) < 0.08,
                           abs(c.greenComponent - rgb.1) < 0.08,
                           abs(c.blueComponent - rgb.2) < 0.08 { accentPixels += 1 }
                    }
                }
                XCTAssertGreaterThan(accentPixels, 20, "\(kind) must remain visible on \(dark ? "dark" : "light")")
            }
        }
    }

    func testToggleUsesSuperchatOnlyAndNoPetLine() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let pet = PetController.shared
        let old = (settings.taskBubbleClickThrough, settings.superchatEnabled)
        settings.taskBubbleClickThrough = false
        settings.superchatEnabled = true
        pet.systemNotices.clear()
        let controller = PetWindowController(refreshStatsUsage: {})
        let before = Set(NSApp.windows.map(\.windowNumber))
        var session = AgentSession(id: "superchat-working", agentKind: .codex, state: .working,
                                   source: .hook, updatedAt: Date())
        session.title = "Superchat feedback"
        let specs = PetWindowPlanner.plan(sessions: [session], split: false, mappings: [],
                                          defaultPetID: "superchat-preview")
        func syncNotice() {
            controller.sync(specs: specs, noticeSource: pet.systemNotices) { _ in
                .init(petID: "superchat-preview", mood: .working, sessions: [session], count: 1,
                      chatLine: "", quotaText: pet.systemNotices.current?.legacyText ?? "")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        syncNotice()
        let body = try XCTUnwrap(NSApp.windows.first {
            $0.title == "AgentPet Lite Body"
                && ($0.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model.key == "default"
                && $0.isVisible
        })
        let model = try XCTUnwrap((body.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model)
        defer {
            controller.stop(); pet.systemNotices.clear()
            settings.taskBubbleClickThrough = old.0; settings.superchatEnabled = old.1
        }

        controller.toggleTaskBubbleClickThrough(forKey: "default")
        syncNotice()
        XCTAssertEqual(pet.systemNotices.current?.kind, .clickThroughOn)
        XCTAssertEqual(pet.systemNotices.current?.id, SystemNotice.clickThroughFeedbackID)
        XCTAssertTrue(model.petReactionLine.isEmpty, "The old pet-line feedback must not also appear")
        XCTAssertEqual(pet.systemNotices.current?.requiresAcknowledgment, false)
        let speech = try XCTUnwrap(NSApp.windows.first {
            !before.contains($0.windowNumber) && $0.title == "AgentPet Lite Pet Messages" && $0.isVisible
        })
        XCTAssertTrue(speech.ignoresMouseEvents, "Operation feedback must not create a new mouse obstruction")

        controller.toggleTaskBubbleClickThrough(forKey: "default")
        syncNotice()
        XCTAssertEqual(pet.systemNotices.current?.kind, .clickThroughOff)
        XCTAssertEqual(pet.systemNotices.current?.id, SystemNotice.clickThroughFeedbackID)
        XCTAssertNil(pet.systemNotices.current?.confirmationLabel)
        XCTAssertTrue(speech.ignoresMouseEvents)
    }

    func testSuspendedFeedbackIsAccurateAndPriorityNoticeWins() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let pet = PetController.shared
        let old = (settings.taskBubbleClickThrough, settings.superchatEnabled)
        settings.taskBubbleClickThrough = false
        settings.superchatEnabled = true
        pet.systemNotices.clear()
        let controller = PetWindowController(refreshStatsUsage: {})
        var waiting = AgentSession(id: "superchat-waiting", agentKind: .codex, state: .waiting,
                                   source: .hook, updatedAt: Date())
        waiting.message = "Waiting for approval"
        let other = AgentSession(id: "superchat-other", agentKind: .codex, state: .working,
                                 source: .hook, updatedAt: Date())
        let specs = PetWindowPlanner.plan(sessions: [waiting, other], split: false, mappings: [],
                                          defaultPetID: "superchat-paused")
        controller.sync(specs: specs) { _ in
            .init(petID: "superchat-paused", mood: .waiting, sessions: [waiting, other],
                  count: 2, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        defer {
            controller.stop(); pet.systemNotices.clear()
            settings.taskBubbleClickThrough = old.0; settings.superchatEnabled = old.1
        }

        controller.toggleTaskBubbleClickThrough(forKey: "default")
        XCTAssertEqual(pet.systemNotices.current?.kind, .clickThroughPaused)
        XCTAssertEqual(pet.systemNotices.current?.body,
                       SystemNotice.text("Could not enable. Handle waiting tasks first", "开启失败，请优先处理等待任务"))

        pet.systemNotices.post(.init(id: "priority-notice", kind: .pomodoro, title: "Timer", body: "Focus done",
                                    legacyText: "Focus done"))
        controller.toggleTaskBubbleClickThrough(forKey: "default")
        XCTAssertEqual(pet.systemNotices.current?.id, "priority-notice",
                       "A priority notice must keep the display instead of low-priority feedback")
    }
    func testRejectedPreparationLeavesAnchorsUntouched() {
        let key = "agentpet.petAnchors.v1"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        // XCTest runs teardown even when setUpWithError rejects the test.
        // A never-prepared instance models exactly that state, inside our
        // verified disposable home rather than the user's preferences.
        let sentinel = Data("untouched-anchor".utf8)
        UserDefaults.standard.set(sentinel, forKey: key)
        let clicks = PetClickDisambiguationTests()
        clicks.tearDown()
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), sentinel)
        let bubbles = TaskBubbleClickThroughWindowTests()
        bubbles.tearDown()
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), sentinel)
    }

    func testFeedbackKeepsAgentRowsAndSingleClickDialogueVisible() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let old = (settings.agentMessagesEnabled, settings.superchatEnabled,
                   settings.hiddenKinds, settings.petBubbleEnabled)
        settings.superchatEnabled = true
        settings.hiddenKinds = []; settings.petBubbleEnabled = true
        let pet = PetController()
        pet.splitPet = false; pet.showChat = true
        defer {
            pet.systemNotices.clear(); pet.clearProgress(); PetWindowController.shared.stop()
            settings.superchatEnabled = old.1
            settings.hiddenKinds = old.2; settings.petBubbleEnabled = old.3
        }
        let at = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var session = AgentSession(id: "feedback-coexist", agentKind: .codex,
                                   state: .working, source: .hook, updatedAt: at)
        session.createdAt = at; session.turnStartedAt = at; session.codexTurnID = "turn"
        pet.update(sessions: [session])
        let message: [String: Any] = ["type": "response_item", "timestamp": at.timeIntervalSince1970,
            "payload": ["type": "message", "role": "assistant", "phase": "commentary",
                        "content": [["type": "output_text", "text": "agent row survives the operation"]]]]
        let decoded = try XCTUnwrap(CodexVisibleMessage.parse(
            JSONSerialization.data(withJSONObject: message), turnID: "turn"))
        pet.showProgress(decoded, session: session)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let body = try XCTUnwrap(NSApp.windows.first {
            $0.title == "AgentPet Lite Body" && $0.isVisible &&
                ($0.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model.noticeSource === pet.systemNotices
        })
        let model = try XCTUnwrap((body.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model)
        let rows = model.speechRows
        XCTAssertEqual(rows.count, 1)
        pet.showClickThroughFeedback(enabled: true, suspended: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.speechRows, rows, "Operation feedback cannot clear or consume an agent row")
        model.petTap()
        XCTAssertFalse(model.petReactionLine.isEmpty)
        XCTAssertEqual(PetSpeechView.notice(model), model.petReactionLine,
                       "A normal click remains visible during operation feedback")
        let source = pet.systemNotices
        let withDialogue = NSHostingView(rootView: PetSpeechView(model: model)).fittingSize
        let noticeOnly = NSHostingView(rootView: SystemNoticeView(source: source,
            notice: try XCTUnwrap(source.current), width: model.noticeWidth)).fittingSize
        XCTAssertGreaterThan(withDialogue.height, noticeOnly.height + 15,
                             "The native view must render the dialogue alongside the feedback")
        if let directory = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"] {
            let renderer = ImageRenderer(content: PetSpeechView(model: model))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("feedback-with-click-dialogue.png"))
        }
        source.post(.init(id: "real-priority", kind: .pomodoro,
                          title: "Timer", body: "Confirm", legacyText: "Confirm"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(model.speechRows.isEmpty, "Real important notices retain their exclusive behavior")
        XCTAssertEqual(PetSpeechView.notice(model), "Confirm")
    }

    func testNoticeHugsShortTextAndWrapsLongContent() throws {
        _ = NSApplication.shared
        let center = SystemNoticeCenter(visible: { _ in false }, changed: {})
        let short = SystemNotice(id: "short", kind: .clickThroughOff,
                                 title: "", body: "Off", legacyText: "Off")
        let long = SystemNotice(id: "long", kind: .clickThroughPaused, title: "",
                                body: String(repeating: "A longer operation needs attention. ", count: 8),
                                legacyText: "long")
        let a = NSHostingView(rootView: SystemNoticeView(source: center, notice: short)).fittingSize
        let b = NSHostingView(rootView: SystemNoticeView(source: center, notice: long)).fittingSize
        XCTAssertLessThan(a.width, 200, "A short message should not reserve 380pt")
        XCTAssertLessThanOrEqual(b.width, 380)
        XCTAssertGreaterThan(b.width, a.width)
        XCTAssertGreaterThan(b.height, a.height + 10, "Long text must wrap, not shrink or clip")
    }

    func testNativeFeedbackPanelResizesWithoutTakingFocusOrChangingTaskInput() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let old = (settings.superchatEnabled, settings.fontSize)
        settings.superchatEnabled = true
        let controller = PetWindowController(refreshStatsUsage: {})
        let center = SystemNoticeCenter(visible: { _ in true }, changed: {})
        defer {
            center.clear(); controller.stop()
            settings.superchatEnabled = old.0; settings.fontSize = old.1
        }
        let specs = PetWindowPlanner.plan(sessions: [], split: false, mappings: [], defaultPetID: "resizing")
        func sync() {
            controller.sync(specs: specs, noticeSource: center) { _ in
                .init(petID: "resizing", mood: .idle, sessions: [], count: 0, chatLine: "",
                      quotaText: center.current?.legacyText ?? "")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        center.post(.clickThrough(enabled: false)); sync()
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.title == "AgentPet Lite Pet Messages" && $0.isVisible &&
                ($0.contentView as? NSHostingView<PetSpeechView>)?.rootView.model.noticeSource === center
        })
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<PetSpeechView>)
        let keyWindow = NSApp.keyWindow
        let short = panel.frame.size
        XCTAssertEqual(short.width, host.fittingSize.width, accuracy: 1)
        XCTAssertLessThan(short.width, 380)
        XCTAssertTrue(panel.ignoresMouseEvents)
        center.post(.init(id: SystemNotice.clickThroughFeedbackID, kind: .clickThroughPaused,
                          title: "", body: String(repeating: "Please handle the pending task. ", count: 5),
                          legacyText: "Pending task")); sync()
        XCTAssertGreaterThan(panel.frame.width, short.width)
        XCTAssertGreaterThan(panel.frame.height, short.height)
        XCTAssertEqual(panel.frame.width, host.fittingSize.width, accuracy: 1)
        XCTAssertEqual(panel.frame.height, host.fittingSize.height, accuracy: 1)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        center.post(.clickThrough(enabled: false)); sync()
        XCTAssertEqual(panel.frame.width, short.width, accuracy: 1)
        let smallWidth = panel.frame.width
        settings.fontSize = .large; sync()
        XCTAssertGreaterThanOrEqual(panel.frame.width, smallWidth)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

}
