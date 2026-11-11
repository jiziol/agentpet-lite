import XCTest
@testable import AgentPetCore

final class AntigravityCancellationBoundaryTests: XCTestCase {
    private let hookAt = Date(timeIntervalSince1970: 203)

    private func invocation(_ count: Int?, at: Date? = nil) -> AgentEvent {
        var payload: [String: Any] = ["conversationId": "native", "invocationNum": 0]
        if let count { payload["initialNumSteps"] = count }
        return AntigravityHookPayload.decode(from: try! JSONSerialization.data(withJSONObject: payload))!.makeEvent(now: at ?? hookAt)!
    }

    private func cancellation(index: Int = 26, fence: Date? = nil) -> AntigravityHumanInput.Cancellation {
        var value = AntigravityHumanInput.Cancellation(identity: "execution", lastStepIndex: index, timestamp: Date(timeIntervalSince1970: 200))
        value.expectedHookAt = fence
        value.observedAt = Date(timeIntervalSince1970: 206)
        return value
    }

    func testNativeBoundaryStopsThinkingCreatedBeforeHook() {
        let store = SessionStore()
        store.apply(invocation(27), now: hookAt)
        let stopped = store.reconcileAntigravityCancellation(id: "native", cancellation: cancellation(fence: hookAt))!
        XCTAssertEqual(stopped.indicator, .read)
        XCTAssertEqual(stopped.message, "任务已停止")
        XCTAssertEqual(stopped.turnEndedAt, Date(timeIntervalSince1970: 206))
        XCTAssertNil(stopped.readAt)
        XCTAssertFalse(stopped.hasUnread)
    }

    func testOldDatabaseCancellationCannotStopNewInvocation() {
        let store = SessionStore()
        store.apply(invocation(2), now: hookAt)
        XCTAssertNil(store.reconcileAntigravityCancellation(id: "native", cancellation: cancellation(index: 0, fence: hookAt)))
        XCTAssertEqual(store.session(id: "native")!.indicator, .running)
        XCTAssertEqual(store.reconcileAntigravityCancellation(id: "native", cancellation: cancellation(index: 1, fence: hookAt))?.indicator, .read)
    }

    func testQueuedCallbackRejectedAfterAnotherHook() {
        let store = SessionStore()
        store.apply(invocation(27), now: hookAt)
        let later = hookAt.addingTimeInterval(1)
        store.apply(invocation(27, at: later), now: later)
        XCTAssertNil(store.reconcileAntigravityCancellation(id: "native", cancellation: cancellation(fence: hookAt)))
        XCTAssertEqual(store.session(id: "native")!.state, .working)
        XCTAssertEqual(store.reconcileAntigravityCancellation(id: "native", cancellation: cancellation(fence: later))?.indicator, .read)
    }

    func testInvocationWithoutBoundaryClearsOldBoundary() {
        let store = SessionStore()
        store.apply(invocation(27), now: hookAt)
        let later = hookAt.addingTimeInterval(1)
        store.apply(invocation(nil, at: later), now: later)
        XCTAssertNil(store.session(id: "native")!.antigravityStepFloor)
        XCTAssertNil(store.reconcileAntigravityCancellation(id: "native", cancellation: cancellation(fence: later)))
    }

    func testToolsAdvanceBoundaryAndOlderHooksDoNotRegressIt() {
        let store = SessionStore()
        store.apply(invocation(27), now: hookAt)
        var tool = AgentEvent(sessionId: "native", agentKind: .antigravity, eventName: "working", timestamp: hookAt.addingTimeInterval(1))
        tool.antigravityStepFloor = 28
        store.apply(tool, now: tool.timestamp)
        tool.timestamp = hookAt.addingTimeInterval(2); tool.antigravityStepFloor = 27
        store.apply(tool, now: tool.timestamp)
        XCTAssertEqual(store.session(id: "native")!.antigravityStepFloor, 28)
        XCTAssertNil(store.reconcileAntigravityCancellation(id: "native", cancellation: cancellation(index: 27, fence: tool.timestamp)))
    }

    func testInvalidCountsKeepConservativeFallback() {
        XCTAssertEqual(invocation(1).antigravityStepFloor, 0)
        for count in [0, -1, Int(Int32.max) + 1] {
            XCTAssertNil(invocation(count).antigravityStepFloor)
        }
        let tool = AntigravityHookPayload.decode(from: Data(#"{"conversationId":"native","stepIdx":0}"#.utf8))!.makeEvent(now: hookAt)!
        XCTAssertEqual(tool.antigravityStepFloor, 0)
        XCTAssertFalse(cancellation().matches(stepFloor: nil, latestHookAt: hookAt))
    }

    func testBoundaryIsPersistedWhenWorkingStateIsUnchanged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(); store.persistenceURL = dir.appendingPathComponent("state.json")
        store.apply(invocation(1), now: hookAt)
        let later = hookAt.addingTimeInterval(1)
        store.apply(invocation(2, at: later), now: later)
        let restored = SessionStore(); restored.persistenceURL = store.persistenceURL
        restored.restoreCodexSessions()
        XCTAssertEqual(restored.session(id: "native")!.antigravityStepFloor, 1)
        XCTAssertEqual(restored.session(id: "native")!.antigravityEventAt, later)
    }
}
