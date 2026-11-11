import XCTest
@testable import AgentPetCore

final class SessionObservationTests: XCTestCase {
    func testWirePayloadAndIndependentClocksRemainIntact() throws {
        let eventAt = Date(timeIntervalSince1970: 10), observedAt = Date(timeIntervalSince1970: 15)
        var event = AgentEvent(sessionId: "s", agentKind: .codex, eventName: "PermissionRequest", timestamp: eventAt)
        event.codexPermissionTurnID = "native-turn"
        event.humanIntervention = .init(action: .asked, requests: [.init(id: "request-1", kind: .permission, createdAt: eventAt)])
        event.antigravityStepFloor = 7
        let input = HookSourceAdapter().observe(event, at: observedAt)
        XCTAssertEqual(input.eventAt, eventAt)
        XCTAssertEqual(input.observedAt, observedAt)
        guard case .hook(let retained) = input.payload else { return XCTFail("channel lost") }
        XCTAssertEqual(retained, event)
        XCTAssertEqual(try EventCoding.decoder.decode(AgentEvent.self, from: EventCoding.encoder.encode(retained)), event)
    }
    func testNativeLifecycleInputRetainsTurnAndCancellationResult() {
        let at = Date(timeIntervalSince1970: 10)
        let store = SessionStore()
        store.apply(AgentEvent(sessionId: "s", agentKind: .codex, eventName: "UserPromptSubmit", timestamp: at), now: at)
        let native = CodexLifecycle(turnID: "t", timestamp: at.addingTimeInterval(1), startedAt: at, result: .cancelled)
        let result = store.apply(SessionObservation(.codexLifecycle(sessionID: "s", native), observedAt: at.addingTimeInterval(2)))
        XCTAssertEqual(result?.codexTurnID, "t")
        XCTAssertEqual(result?.taskResult, .cancelled)
        XCTAssertEqual(result?.indicator, .read)
        XCTAssertEqual(result?.turnEndedAt, native.timestamp)
    }
    func testSafeLabelsDiscardControlsAndNeverExposeArguments() {
        let message = SafeActivityFormatter.activity(event: "PreToolUse", tool: "read_file", input: ["path": "/secret/folder/a\n\u{0}b.swift", "prompt": "PRIVATE"])
        XCTAssertEqual(message, "正在读取 ab.swift")
        XCTAssertEqual(SafeActivityFormatter.activity(event: "PreToolUse", tool: "exec_command", input: ["cmd": "python3 --token PRIVATE"]), "正在运行 Python 脚本")
        XCTAssertFalse(message.contains("secret"))
        XCTAssertEqual(SafeActivityFormatter.activity(event: "PreToolUse", tool: "tool\nname", input: [:]), "正在调用 toolname")
    }
}
