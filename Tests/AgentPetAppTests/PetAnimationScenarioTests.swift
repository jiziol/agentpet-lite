import XCTest
import AgentPetCore
@testable import agentpet

final class PetAnimationScenarioTests: XCTestCase {
    private var bindings: PetAnimationBindings {
        .init(byKey: Dictionary(uniqueKeysWithValues: PetAnimationBindings.selectionKeys.map {
            ($0, .init(mode: .rotate, clipIDs: [$0 + "-a", $0 + "-b"]))
        }))
    }
    private var ids: Set<String> { Set(bindings.byKey.values.flatMap(\.clipIDs)) }
    private func session(_ id: String, _ state: AgentState, _ result: CodexTurnResult? = nil, end: Double = 100) -> AgentSession {
        var s = AgentSession(id: id, agentKind: .codex, state: state, source: .hook,
                             updatedAt: Date(timeIntervalSince1970: end))
        s.codexTurnResult = result; s.notificationVersion = 1; s.displayRevision = 1
        s.turnStartedAt = Date(timeIntervalSince1970: 50)
        if state == .done { s.turnEndedAt = Date(timeIntervalSince1970: end) }
        return s
    }
    private func read(_ s: inout AgentSession) {
        s.readThroughVersion = s.notificationVersion; s.readDisplayRevision = s.displayRevision
        s.readAt = Date(timeIntervalSince1970: 200)
    }
    private func update(_ p: inout PetAnimationPlayback, _ sessions: [AgentSession],
                        drag: Bool = false, tap: Int = 0, cue: PetAnimationCue? = nil, draw: Int = 0) {
        p.update(mood: .working, dragging: drag, tapRevision: tap, bindings: bindings,
                 available: ids, context: .init(sessions: sessions, cue: cue), random: { _ in draw })
    }

    func testUnreadResultLoopsOneRandomClipAndAcknowledgementFinishesCurrentCycle() {
        for result in [CodexTurnResult.completed, .failed] {
            var p = PetAnimationPlayback(), s = session("s", .done, result)
            update(&p, [s], draw: 1)
            let chosen = p.selection!
            XCTAssertEqual(chosen.key, result == .completed ? "success" : "failure")
            XCTAssertTrue(chosen.clipID.hasSuffix("-b")); XCTAssertTrue(chosen.loop)
            update(&p, [s], draw: 0); XCTAssertEqual(p.selection, chosen)
            read(&s); update(&p, [s])
            XCTAssertEqual(p.selection?.clipID, chosen.clipID)
            XCTAssertEqual(p.selection?.token, chosen.token)
            XCTAssertFalse(p.selection!.loop)
            p.finished(token: chosen.token)
            XCTAssertEqual(p.selection?.key, "idle")
        }
    }
    func testOtherWorkMakesResultOneShotThenWaitingTakesPriority() {
        var p = PetAnimationPlayback()
        let work = session("work", .working)
        update(&p, [work])
        let success = session("success", .done, .completed)
        update(&p, [work, success])
        XCTAssertEqual(p.selection?.key, "success"); XCTAssertFalse(p.selection!.loop)
        let once = p.selection!.token
        update(&p, [work, success, session("wait", .waiting)])
        p.finished(token: once)
        XCTAssertEqual(p.selection?.key, "waiting")
    }
    func testNewActiveSessionInterruptsHeldResultAndRejectsLateCallback() {
        var p = PetAnimationPlayback()
        var done = session("done", .done, .failed)
        update(&p, [done]); let old = p.selection!.token
        read(&done); update(&p, [done])
        update(&p, [done, session("new", .working)])
        let active = p.selection
        p.finished(token: old)
        XCTAssertEqual(p.selection, active); XCTAssertEqual(active?.key, "working")
    }
    func testAllEndedSwitchesToRemainingUnreadOnlyAtCurrentClipEnd() {
        var p = PetAnimationPlayback()
        var first = session("first", .done, .failed, end: 100)
        var last = session("last", .done, .completed, end: 200)
        update(&p, [first, last]); XCTAssertEqual(p.selection?.key, "success")
        let success = p.selection!.token
        read(&last); update(&p, [first, last]); XCTAssertEqual(p.selection?.key, "success")
        p.finished(token: success); XCTAssertEqual(p.selection?.key, "failure"); XCTAssertTrue(p.selection!.loop)
        let failure = p.selection!.token
        read(&first); update(&p, [first, last]); p.finished(token: failure)
        XCTAssertEqual(p.selection?.key, "idle")
    }
    func testOldResultsDoNotFlashOnLaunchWhileOtherWorkIsActive() {
        var p = PetAnimationPlayback()
        let old = session("old", .done, .completed)
        update(&p, [old, session("work", .working)])
        XCTAssertEqual(p.selection?.key, "working")
        update(&p, [old]); XCTAssertEqual(p.selection?.key, "success"); XCTAssertTrue(p.selection!.loop)
    }
    func testCancellationPlaysFailureOnceWithoutUnreadLoop() {
        var p = PetAnimationPlayback()
        update(&p, [session("s", .working)])
        let cancelled = session("s", .done, .cancelled)
        update(&p, [cancelled]); XCTAssertEqual(p.selection?.key, "failure"); XCTAssertFalse(p.selection!.loop)
        p.finished(token: p.selection!.token); XCTAssertEqual(p.selection?.key, "idle")
        var restarted = PetAnimationPlayback(); update(&restarted, [cancelled])
        XCTAssertEqual(restarted.selection?.key, "idle")
    }
    func testUnknownOrDisconnectedResultsNeverPlaySuccess() {
        let unknown = session("unknown", .done)
        var disconnected = session("disconnected", .done, .completed)
        disconnected.agentKind = .opencode; disconnected.opencodeTurnResult = .completed
        disconnected.opencodeDisconnectedAt = Date(timeIntervalSince1970: 100)
        var p = PetAnimationPlayback(); update(&p, [unknown, disconnected])
        XCTAssertEqual(p.selection?.key, "idle")
    }
    func testReadingWaitingRequestDoesNotMakeSemanticActivityIdle() {
        var waiting = session("waiting", .waiting); read(&waiting)
        var p = PetAnimationPlayback(); update(&p, [waiting, session("work", .working)])
        XCTAssertEqual(p.selection?.key, "waiting")
    }
    func testQuotaCuePlaysOnceThenRestoresHeldClipAndDoesNotOverwriteResult() {
        var p = PetAnimationPlayback(); let done = session("done", .done, .failed)
        update(&p, [done], draw: 1); let held = p.selection!.clipID
        let cue = PetAnimationCue(id: "account-window", key: "quota")
        update(&p, [done], cue: cue); XCTAssertEqual(p.selection?.key, "quota")
        let once = p.selection!.token; update(&p, [done], cue: cue)
        XCTAssertEqual(p.selection?.token, once)
        p.finished(token: once); XCTAssertEqual(p.selection?.clipID, held); XCTAssertTrue(p.selection!.loop)
        update(&p, [done], cue: cue); XCTAssertEqual(p.selection?.clipID, held)
    }
    func testTapAndDragResumeCurrentUnreadResultAndNeverAcknowledgeIt() {
        var p = PetAnimationPlayback(); let done = session("done", .done, .completed)
        update(&p, [done]); update(&p, [done], tap: 1)
        XCTAssertEqual(p.selection?.key, "tap"); p.finished(token: p.selection!.token)
        XCTAssertEqual(p.selection?.key, "success")
        update(&p, [done], drag: true, tap: 1); XCTAssertEqual(p.selection?.key, "drag")
        update(&p, [done], tap: 1); XCTAssertEqual(p.selection?.key, "success")
        XCTAssertTrue(done.hasUnread)
    }
    func testQuotaArrivingWithResultOrDuringDragIsNotLost() {
        let cue = PetAnimationCue(id: "window", key: "quota")
        let work = session("s", .working), done = session("s", .done, .completed)
        var p = PetAnimationPlayback(); update(&p, [work])
        update(&p, [done], cue: cue)
        XCTAssertEqual(p.selection?.key, "quota")
        p.finished(token: p.selection!.token)
        XCTAssertEqual(p.selection?.key, "success"); XCTAssertTrue(p.selection!.loop)
        var dragged = PetAnimationPlayback(); update(&dragged, [work], drag: true)
        update(&dragged, [work], drag: true, cue: cue)
        update(&dragged, [work])
        XCTAssertEqual(dragged.selection?.key, "quota")
        dragged.finished(token: dragged.selection!.token)
        XCTAssertEqual(dragged.selection?.key, "working")
    }
    func testBindingChangeAfterReadDoesNotRestoreUnreadLoop() {
        var p = PetAnimationPlayback(), done = session("s", .done, .failed)
        update(&p, [done]); read(&done)
        var changed = bindings; changed.byKey["failure"] = .init(mode: .rotate, clipIDs: ["failure-b"])
        p.update(mood: .working, bindings: changed, available: ids, context: .init(sessions: [done]))
        XCTAssertFalse(p.selection!.loop)
        p.finished(token: p.selection!.token); XCTAssertEqual(p.selection?.key, "idle")
    }
}
