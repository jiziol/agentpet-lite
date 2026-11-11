import AppKit
import AgentPetCore
import XCTest
@testable import agentpet

@MainActor
final class IdleSpeechRotationTests: XCTestCase {
    func testBlockedIntervalsDoNotAccumulateAndResumeWithNewToken() throws {
        var allowed = true
        var advances = 0
        let rotation = IdleSpeechRotation(eligible: { allowed }, advance: { advances += 1 })
        defer { rotation.stop() }
        rotation.start()
        let first = try XCTUnwrap(rotation.generation)
        rotation.reconcile()
        XCTAssertEqual(rotation.generation, first, "ordinary layout updates must not postpone chatter")
        allowed = false
        rotation.reconcile()
        XCTAssertNil(rotation.generation)
        rotation.fire(first)
        XCTAssertEqual(advances, 0)
        allowed = true
        rotation.reconcile()
        let resumed = try XCTUnwrap(rotation.generation)
        XCTAssertNotEqual(resumed, first)
        rotation.fire(first)
        XCTAssertEqual(advances, 0)
        rotation.fire(resumed)
        XCTAssertEqual(advances, 1)
        XCTAssertNotEqual(rotation.generation, resumed)
    }

    func testPriorityChangesAtFireAndStoppedCallbacksCannotSpeak() throws {
        var allowed = true
        var advances = 0
        let rotation = IdleSpeechRotation(eligible: { allowed }, advance: { advances += 1 })
        rotation.start()
        let first = try XCTUnwrap(rotation.generation)
        allowed = false // notice/task arrived before its layout callback
        rotation.fire(first)
        XCTAssertEqual(advances, 0)
        XCTAssertNil(rotation.generation)
        allowed = true
        rotation.reconcile()
        let next = try XCTUnwrap(rotation.generation)
        rotation.stop()
        rotation.fire(next)
        rotation.reconcile()
        XCTAssertFalse(rotation.isRunning)
        XCTAssertNil(rotation.generation)
        XCTAssertEqual(advances, 0)
    }

    func testNativeTimerAutomaticallyAdvances() async {
        var advances = 0
        let rotation = IdleSpeechRotation(delay: 0.1, eligible: { true }, advance: { advances += 1 })
        rotation.start()
        defer { rotation.stop() }
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertGreaterThanOrEqual(advances, 1)
    }
}

extension IdleSpeechRotationTests {
    func testNativeVisibilityBlocksTasksRepliesNoticesAndHiddenPets() async {
        _ = NSApplication.shared
        let controller = PetWindowController()
        let settings = BubbleSettings.shared
        let old = settings.superchatEnabled
        settings.superchatEnabled = true
        var advances = 0
        let rotation = IdleSpeechRotation(delay: 0.1,
            eligible: { controller.hasVisibleIdleChatter }, advance: { advances += 1 })
        defer { rotation.stop(); controller.stop(); settings.superchatEnabled = old }
        let specs = PetWindowPlanner.plan(sessions: [], split: false, mappings: [], defaultPetID: "rotation-fixture")
        func sync(_ state: PetWindowController.WindowState) {
            controller.sync(specs: specs) { _ in state }
        }
        let idle = PetWindowController.WindowState(petID: "rotation-fixture", mood: .idle,
            sessions: [], count: 0, chatLine: "一句闲聊", idleText: "一句闲聊")
        sync(idle)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(controller.hasVisibleIdleChatter)
        rotation.start()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertGreaterThan(advances, 0)

        let session = AgentSession(id: "idle-priority", agentKind: .codex,
            state: .working, source: .hook, updatedAt: Date())
        let row = PetSpeechState.Row(id: UUID(), session: .init(session), label: "@Codex[1]",
            itemID: "reply", text: "公开回复", expiresAt: Date().addingTimeInterval(5))
        for state in [
            PetWindowController.WindowState(petID: "rotation-fixture", mood: .working, sessions: [session],
                count: 1, chatLine: "", idleText: "一句闲聊"),
            PetWindowController.WindowState(petID: "rotation-fixture", mood: .idle, sessions: [],
                count: 0, chatLine: "", speechRows: [row], idleText: "一句闲聊"),
            PetWindowController.WindowState(petID: "rotation-fixture", mood: .idle, sessions: [],
                count: 0, chatLine: "", quotaText: "重要提醒", idleText: "一句闲聊")
        ] {
            sync(state)
            try? await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertFalse(controller.hasVisibleIdleChatter)
            rotation.reconcile()
            let count = advances
            try? await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(advances, count)
        }
        sync(idle)
        try? await Task.sleep(nanoseconds: 150_000_000)
        controller.isVisible = false
        XCTAssertFalse(controller.hasVisibleIdleChatter)
        rotation.reconcile()
        XCTAssertNil(rotation.generation)
        controller.isVisible = true
        try? await Task.sleep(nanoseconds: 150_000_000)
        rotation.reconcile()
        XCTAssertNotNil(rotation.generation)
    }
}
