import XCTest
@testable import AgentPetCore

final class AntigravityHookPayloadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ json: String) -> AgentEvent? {
        AntigravityHookPayload.decode(from: Data(json.utf8))?.makeEvent(now: now)
    }

    func testPreToolUseIsWorking() {
        let e = event(#"{"conversationId":"c1","workspacePaths":["/Users/me/proj"],"stepIdx":0,"toolCall":{"name":"run_command"}}"#)
        XCTAssertEqual(e?.agentKind, .antigravity)
        XCTAssertEqual(e?.sessionId, "c1")
        XCTAssertEqual(e?.eventName, "working")
        XCTAssertEqual(e?.project, "/Users/me/proj")
        XCTAssertEqual(e?.message, "正在执行命令")
        XCTAssertEqual(StateMapper.state(for: .antigravity, eventName: e!.eventName), .working)
    }

    func testDecodesModel() {
        let e = event(#"{"conversationId":"c1","workspacePaths":["/p"],"stepIdx":0,"toolCall":{"name":"run_command"},"model":{"display_name":"Gemini 3 Pro"}}"#)
        XCTAssertEqual(e?.model, "Gemini 3 Pro")
    }

    func testStopWithTerminationReasonIsDone() {
        let e = event(#"{"conversationId":"c2","executionNum":1,"terminationReason":"model_stop","fullyIdle":true}"#)
        XCTAssertEqual(e?.eventName, "done")
        XCTAssertEqual(StateMapper.state(for: .antigravity, eventName: e!.eventName), .done)
    }

    func testBackgroundWorkIsNotCompleted() {
        let e = event(#"{"conversationId":"c2","fullyIdle":false}"#)
        XCTAssertEqual(e?.eventName, "working")
    }

    func testExplicitCancellationEndsForegroundDespiteBackgroundFlag() {
        let e = event(#"{"conversationId":"c2","terminationReason":"user_canceled","fullyIdle":false}"#)
        XCTAssertEqual(e?.eventName, "done")
        XCTAssertEqual(e?.turnResult, .cancelled)
        XCTAssertEqual(e?.message, "任务已停止")
    }

    func testNativeUppercaseUserCanceledReasonIsGreenStop() {
        let e = event(#"{"conversationId":"c2","terminationReason":"USER_CANCELED","fullyIdle":false}"#)!
        XCTAssertEqual(e.eventName, "done")
        XCTAssertEqual(e.turnResult, .cancelled)
        let store = SessionStore(); store.apply(e, now: now)
        XCTAssertEqual(store.session(id: "c2")!.indicator, .read)
    }

    func testOnlyPreInvocationCanReopenCancelledTask() {
        XCTAssertEqual(event(#"{"conversationId":"c2","invocationNum":2}"#)?.antigravityNewInvocation, true)
        XCTAssertEqual(event(#"{"conversationId":"c2","stepIdx":8}"#)?.antigravityNewInvocation, false)
    }

    func testPreInvocationIsWorking() {
        let e = event(#"{"conversationId":"c3","invocationNum":2,"initialNumSteps":5}"#)
        XCTAssertEqual(e?.eventName, "working")
    }

    func testPostToolUseIsWorking() {
        let e = event(#"{"conversationId":"c4","stepIdx":3,"error":""}"#)
        XCTAssertEqual(e?.eventName, "working")
    }

    func testMissingConversationIdIsNil() {
        XCTAssertNil(event(#"{"stepIdx":0,"toolCall":{"name":"x"}}"#))
    }

    func testRoutedThroughHookPayloads() {
        let data = Data(#"{"conversationId":"c5","terminationReason":"model_stop"}"#.utf8)
        let e = HookPayload.event(forAgent: .antigravity, stdin: data, now: now)
        XCTAssertEqual(e?.agentKind, .antigravity)
        XCTAssertEqual(e?.eventName, "done")
    }
}
