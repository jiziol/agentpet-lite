import XCTest
@testable import AgentPetCore

final class OpencodeVisibleMessageTests: XCTestCase {
    static func data(_ changes: [String: Any] = [:]) throws -> Data {
        var frame: [String: Any] = ["schema": OpencodeVisibleMessage.schema, "session_id": "ses_Test",
            "parent_id": "msg_User", "message_id": "msg_Assistant", "part_id": "prt_Text",
            "process_id": 123, "revision": 1, "timestamp": 1000, "mode": "snapshot", "text": "可见正文",
            "role": "assistant", "part_type": "text", "synthetic": false, "ignored": false]
        frame.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: frame)
    }
    func testStrictVisibilityAndBounds() throws {
        XCTAssertEqual(OpencodeVisibleMessage.decode(try Self.data())?.text, "可见正文")
        for changes: [String: Any] in [["role": "user"], ["part_type": "reasoning"], ["synthetic": true],
            ["ignored": true], ["parent_id": "turn:1"], ["session_id": "../ses_Test"], ["process_id": 0],
            ["revision": -1], ["revision": 1.5], ["text": String(repeating: "字", count: 700)],
            ["mode": "withdraw"], ["schema": "future"]] {
            XCTAssertNil(OpencodeVisibleMessage.decode(try Self.data(changes)))
        }
        XCTAssertEqual(OpencodeVisibleMessage.decode(try Self.data(["mode": "withdraw", "text": ""]))?.mode, .withdraw)
    }
    func testBoundedCoalescingAndOutOfOrderInput() throws {
        let inbox = OpencodeSpeechInbox()
        XCTAssertTrue(inbox.offer(try XCTUnwrap(OpencodeVisibleMessage.decode(Self.data()))))
        for revision in 2...1000 {
            XCTAssertFalse(inbox.offer(try XCTUnwrap(OpencodeVisibleMessage.decode(Self.data(["revision": revision])))))
        }
        XCTAssertFalse(inbox.offer(try XCTUnwrap(OpencodeVisibleMessage.decode(Self.data(["revision": 2])))))
        let messages = inbox.take()
        XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages.first?.revision, 1000)
        for n in 0..<1000 {
            _ = inbox.offer(try XCTUnwrap(OpencodeVisibleMessage.decode(Self.data(["session_id": "ses_S\(n)"]))))
        }
        XCTAssertEqual(inbox.take().count, 128)
        XCTAssertTrue(inbox.offer(try XCTUnwrap(OpencodeVisibleMessage.decode(Self.data()))))
        inbox.clear(); XCTAssertTrue(inbox.take().isEmpty)
    }
    func testSocketOnlyRoutingNeverFallsBackToLifecycleOrDiskReplay() throws {
        let path = "/tmp/ap-speech-" + UUID().uuidString + ".sock"
        let server = EventSocketServer(path: path); defer { server.stop() }
        let speech = expectation(description: "speech"); let lifecycle = expectation(description: "lifecycle")
        try server.start(onVisibleMessage: { value in
            XCTAssertEqual(value.partID, "prt_Text"); speech.fulfill()
        }) { value in XCTAssertEqual(value.sessionId, "real-event"); lifecycle.fulfill() }
        let peer = try SocketTransportScenarios.Peer(path)
        var malformed = try JSONSerialization.jsonObject(with: EventCoding.encoder.encode(
            AgentEvent(sessionId: "must-not-route", agentKind: .opencode, eventName: "working", timestamp: Date()))) as! [String: Any]
        malformed["schema"] = "agentpet.opencode.speech.v2"
        var data = try Self.data(); data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: malformed)); data.append(10)
        let event = AgentEvent(sessionId: "real-event", agentKind: .opencode, eventName: "working", timestamp: Date(timeIntervalSince1970: 1000))
        data.append(try EventSender.encodeLine(event))
        XCTAssertTrue(peer.send(data))
        wait(for: [speech, lifecycle], timeout: 2)
        var queued: [AgentEvent] = []
        EventSocketServer.decodeLines(data) { queued.append($0) }
        XCTAssertEqual(queued, [event])
        server.stop()
        try server.start(onVisibleMessage: { _ in XCTFail("old listener callback survived restart") }) { _ in }
    }
}
