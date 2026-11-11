import XCTest
@testable import AgentPetCore

final class ManualStopTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100)

    func testCancellationIsGreenWithoutInventedNavigationReceipt() {
        for kind: AgentKind in [.codex, .antigravity, .opencode] {
            var session = AgentSession(id: "test", agentKind: kind, state: .done, source: .hook, updatedAt: start)
            session.notificationVersion = 2
            switch kind {
            case .codex: session.codexTurnResult = .cancelled
            case .antigravity: session.antigravityTurnResult = .cancelled
            default: session.opencodeTurnResult = .cancelled
            }
            XCTAssertEqual(session.indicator, .read)
            XCTAssertFalse(session.hasUnread)
            XCTAssertFalse(session.hasReadReceipt)
            XCTAssertNil(session.readAt)
            session.state = .working
            XCTAssertEqual(session.indicator, .running)
        }
    }

    func testCompletionFailureAndUnknownStillUnread() {
        for result: CodexTurnResult? in [.completed, .failed, nil] {
            var session = AgentSession(id: "test", agentKind: .antigravity, state: .done, source: .hook, updatedAt: start)
            session.antigravityTurnResult = result
            session.notificationVersion = 1
            XCTAssertTrue(session.hasUnread)
            XCTAssertEqual(session.indicator, .unread)
        }
    }

    func testNativeCancellationClearsWaitingAndRejectsOldWork() {
        let store = SessionStore()
        store.apply(AgentEvent(sessionId: "test", agentKind: .antigravity, eventName: "working", timestamp: start), now: start)
        var asked = AgentEvent(sessionId: "test", agentKind: .antigravity, eventName: "HumanInput", timestamp: start.addingTimeInterval(1))
        asked.humanIntervention = HumanIntervention(action: .asked, requests: [HumanRequest(id: "question", kind: .choice, createdAt: asked.timestamp)])
        store.apply(asked, now: asked.timestamp)
        let cancellation = AntigravityHumanInput.Cancellation(identity: "execution", lastStepIndex: 12, timestamp: start.addingTimeInterval(2))
        let stopped = store.reconcileAntigravityCancellation(id: "test", cancellation: cancellation)
        XCTAssertEqual(stopped?.state, .done)
        XCTAssertEqual(stopped?.message, "任务已停止")
        XCTAssertEqual(stopped?.humanRequests, [])
        XCTAssertEqual(stopped?.indicator, .read)
        XCTAssertNil(store.reconcileAntigravityCancellation(id: "test", cancellation: cancellation))
        let late = AgentEvent(sessionId: "test", agentKind: .antigravity, eventName: "working", timestamp: start.addingTimeInterval(3))
        XCTAssertNil(store.apply(late, now: late.timestamp))
        var lateStop = late; lateStop.eventName = "done"; lateStop.turnResult = .completed
        XCTAssertNil(store.apply(lateStop, now: lateStop.timestamp))
        XCTAssertEqual(store.session(id: "test")?.taskResult, .cancelled)
        var next = late; next.antigravityNewInvocation = true
        XCTAssertEqual(store.apply(next, now: next.timestamp)?.indicator, .running)
        XCTAssertNil(store.reconcileAntigravityCancellation(id: "test", cancellation: cancellation))
        XCTAssertEqual(store.session(id: "test")?.state, .working)
    }

    func testManualStopExpiresWithoutClickButCompletionRemains() {
        let store = SessionStore()
        for (id, result) in [("stop", CodexTurnResult.cancelled), ("done", .completed), ("failed", .failed)] {
            var e = AgentEvent(sessionId: id, agentKind: .antigravity, eventName: "done", timestamp: start)
            e.turnResult = result; store.apply(e, now: start)
        }
        store.prune(now: start.addingTimeInterval(31))
        XCTAssertEqual(store.session(id: "stop")?.state, .idle)
        XCTAssertEqual(store.session(id: "done")?.state, .done)
        XCTAssertEqual(store.session(id: "failed")?.state, .done)
    }
}
