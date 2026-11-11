import XCTest
import AgentPetCore
@testable import agentpet

final class OpencodeSpeechStateTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1000)
    private func message(_ changes: [String: Any] = [:]) throws -> OpencodeVisibleMessage {
        var frame: [String: Any] = ["schema": OpencodeVisibleMessage.schema, "session_id": "ses_Test",
            "parent_id": "msg_User", "message_id": "msg_Assistant", "part_id": "prt_Text",
            "process_id": 123, "revision": 1, "timestamp": 1000, "mode": "snapshot", "text": "正在检查窗口",
            "role": "assistant", "part_type": "text", "synthetic": false, "ignored": false]
        frame.merge(changes) { _, new in new }
        return try EventCoding.decoder.decode(OpencodeVisibleMessage.self, from: JSONSerialization.data(withJSONObject: frame))
    }
    private func session() -> AgentSession {
        var s = AgentSession(id: "ses_Test", agentKind: .opencode, state: .working, source: .hook, updatedAt: at)
        s.createdAt = at; s.turnStartedAt = at; s.opencodeTurnID = "msg_User"; s.opencodeProcessID = 123
        return s
    }
    private func candidate(_ message: OpencodeVisibleMessage, _ session: AgentSession) -> PetSpeechState.Candidate {
        .init(fence: .init(session, turnID: message.turnID), itemID: message.partID,
            timestamp: message.timestamp, revision: message.revision,
            content: message.mode == .withdraw ? .withdraw : .snapshot(message.text))
    }
    func testIndependentHookRaceAndExactOwner() throws {
        var state = OpencodeSpeechState(); state.reset(enabled: true, now: at)
        state.receive([try message()], now: at)
        XCTAssertTrue(state.drain(sessions: [], now: at).isEmpty); XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.drain(sessions: [session()], now: at).count, 1)
        state.receive([try message(["process_id": 124])], now: at)
        XCTAssertTrue(state.drain(sessions: [session()], now: at).isEmpty); XCTAssertEqual(state.count, 0)
        var reused = session(); reused.opencodeProcessStartedAt = at.addingTimeInterval(1)
        state.receive([try message()], now: at)
        XCTAssertTrue(state.drain(sessions: [reused], now: at).isEmpty)
    }
    func testChildTextCannotCreateIndependentBubbleAndLateParentFactWithdrawsIt() throws {
        var child = session(); child.opencodeParentSessionID = "ses_Parent"
        var state = OpencodeSpeechState(); state.reset(enabled: true, now: at)
        state.receive([try message()], now: at)
        XCTAssertTrue(state.drain(sessions: [child], now: at).isEmpty)
        var display = PetSpeechState()
        display.receive(candidate(try message(), child), session: child, now: at)
        XCTAssertTrue(display.rows.isEmpty)
        display.receive(candidate(try message(), session()), session: session(), now: at)
        XCTAssertEqual(display.rows.count, 1)
        display.reconcile([child], now: at)
        XCTAssertTrue(display.rows.isEmpty)
    }
    func testNewTurnMayPrecedeHookOfPreviouslyCancelledTurn() throws {
        var state = OpencodeSpeechState(); state.reset(enabled: true, now: at)
        var old = session(); old.opencodeTurnResult = .cancelled
        state.receive([try message(["parent_id": "msg_New", "timestamp": 1001])], now: at.addingTimeInterval(1))
        XCTAssertTrue(state.drain(sessions: [old], now: at.addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(state.count, 1)
        old.opencodeTurnID = "msg_New"; old.opencodeTurnResult = nil; old.turnStartedAt = at.addingTimeInterval(1)
        XCTAssertEqual(state.drain(sessions: [old], now: at.addingTimeInterval(1)).count, 1)
    }
    func testCancelDeletedDisableRestartAndStaleTextNeverReplay() throws {
        var state = OpencodeSpeechState(); state.reset(enabled: true, now: at)
        var cancelled = session(); cancelled.opencodeTurnResult = .cancelled
        state.receive([try message()], now: at)
        XCTAssertTrue(state.drain(sessions: [cancelled], now: at).isEmpty)
        state.receive([try message()], now: at)
        XCTAssertTrue(state.drain(sessions: [], now: at).isEmpty); XCTAssertEqual(state.count, 0)
        state.reset(enabled: false, now: at); state.receive([try message()], now: at)
        XCTAssertEqual(state.count, 0)
        state.reset(enabled: true, now: at.addingTimeInterval(1)); state.receive([try message()], now: at.addingTimeInterval(1))
        XCTAssertEqual(state.count, 0)
        state.receive([try message(["timestamp": 1001])], now: at.addingTimeInterval(1))
        XCTAssertTrue(state.drain(sessions: [session()], now: at.addingTimeInterval(6)).isEmpty)
        state.receive([try message(["timestamp": 1010])], now: at.addingTimeInterval(5))
        XCTAssertEqual(state.count, 0)
    }
    func testBoundedBurstRetainsLatestAndCannotAllocateMoreThan128() throws {
        var state = OpencodeSpeechState(); state.reset(enabled: true, now: at)
        for n in 1...1000 { state.receive([try message(["revision": n])], now: at) }
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.drain(sessions: [session()], now: at).first?.0.revision, 1000)
        for n in 1...1000 { state.receive([try message(["session_id": "ses_S\(n)"])], now: at) }
        XCTAssertEqual(state.count, 128)
        _ = state.drain(sessions: [], now: at.addingTimeInterval(5)); XCTAssertEqual(state.count, 0)
    }
    func testOpenCodeDisplayFenceWithdrawalAndFiveSecondLimit() throws {
        var display = PetSpeechState(); let s = session(); let first = try message()
        display.receive(candidate(first, s), session: s, now: at)
        XCTAssertEqual(display.rows.first?.label, "@OpenCode[1]")
        let row = try XCTUnwrap(display.rows.first)
        let updated = try message(["text": "正在检查窗口布局", "revision": 2, "timestamp": 1002])
        display.receive(candidate(updated, s), session: s, now: at.addingTimeInterval(2))
        XCTAssertEqual(display.rows.first?.id, row.id); XCTAssertEqual(display.rows.first?.expiresAt, at.addingTimeInterval(5))
        let withdraw = try message(["mode": "withdraw", "text": "", "revision": 3, "timestamp": 1002.1])
        display.receive(candidate(withdraw, s), session: s, now: at.addingTimeInterval(2.1))
        XCTAssertTrue(display.rows.isEmpty)
        display.receive(candidate(updated, s), session: s, now: at.addingTimeInterval(2.2)); XCTAssertTrue(display.rows.isEmpty)
        var next = s; next.opencodeTurnID = "msg_Next"; next.turnStartedAt = at.addingTimeInterval(2)
        display.reconcile([next], now: at.addingTimeInterval(2.2))
        display.receive(candidate(first, next), session: next, now: at.addingTimeInterval(2.2))
        XCTAssertTrue(display.rows.isEmpty)
        let fresh = try message(["parent_id": "msg_Next", "timestamp": 1002.2, "revision": 4])
        display.receive(candidate(fresh, next), session: next, now: at.addingTimeInterval(2.2))
        XCTAssertEqual(display.rows.first?.label, "@OpenCode[1]")
        display.advance(now: at.addingTimeInterval(7.2)); XCTAssertTrue(display.rows.isEmpty)
    }
    func testWithdrawOlderVisiblePartPreservesNewerPendingPart() throws {
        var display = PetSpeechState(); let s = session()
        display.receive(candidate(try message(), s), session: s, now: at)
        display.receive(candidate(try message(["part_id": "prt_Next", "timestamp": 1001, "revision": 2, "text": "新的片段"]), s), session: s, now: at.addingTimeInterval(1))
        XCTAssertEqual(display.rows.first?.itemID, "prt_Text")
        display.receive(candidate(try message(["timestamp": 1001.1, "revision": 3, "mode": "withdraw", "text": ""]), s), session: s, now: at.addingTimeInterval(1.1))
        XCTAssertTrue(display.rows.isEmpty)
        display.advance(now: at.addingTimeInterval(2))
        XCTAssertEqual(display.rows.first?.itemID, "prt_Next")
    }
}
