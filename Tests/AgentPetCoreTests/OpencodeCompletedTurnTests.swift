import XCTest
import CSQLite
@testable import AgentPetCore

final class OpencodeCompletedTurnTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1000)
    private func database(_ body: (OpaquePointer, String) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        defer { sqlite3_close(db); try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE session(id TEXT PRIMARY KEY,parent_id TEXT); CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,data TEXT); CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,data TEXT); INSERT INTO session VALUES('ses_Root',NULL);", nil, nil, nil), SQLITE_OK)
        try message(db, id: "msg_Current", role: "user", offset: 0)
        try body(db, url.path)
    }
    private func message(_ db: OpaquePointer, id: String, role: String, offset: Double,
                         parent: String? = nil, finish: String? = nil, completed: Double? = nil,
                         error: String? = nil) throws {
        var data: [String: Any] = ["role": role, "time": ["created": (1000 + offset) * 1000]]
        if let parent { data["parentID"] = parent }
        if let finish { data["finish"] = finish }
        if let completed { data["time"] = ["created": (1000 + offset) * 1000, "completed": (1000 + completed) * 1000] }
        if let error { data["error"] = ["name": error] }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO message VALUES(?,'ses_Root',?,?)", -1, &stmt, nil), SQLITE_OK)
        let statement = try XCTUnwrap(stmt); defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_double(statement, 2, (1000 + offset) * 1000)
        sqlite3_bind_text(statement, 3, json, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
    private func read(_ path: String, turn: String = "msg_Current") -> OpencodeCompletedTurn.Record? {
        OpencodeCompletedTurn.read(sessionID: "ses_Root", turnID: turn, databasePath: path,
                                   now: at.addingTimeInterval(20))
    }
    func testExactRootFinalStopIsReadWithoutModifyingDatabase() throws {
        try database { db, path in
            try message(db, id: "msg_Final", role: "assistant", offset: 5, parent: "msg_Current", finish: "stop", completed: 8)
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertEqual(read(path), .init(sessionID: "ses_Root", turnID: "msg_Current", completedAt: at.addingTimeInterval(8)))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        }
    }
    func testChildAndWrongParentCannotEndRootTurn() throws {
        try database { db, path in
            try message(db, id: "msg_Final", role: "assistant", offset: 5, parent: "msg_Other", finish: "stop", completed: 8)
            XCTAssertNil(read(path))
            sqlite3_exec(db, "UPDATE message SET data=json_set(data,'$.parentID','msg_Current'); UPDATE session SET parent_id='ses_Parent';", nil, nil, nil)
            XCTAssertNil(read(path))
        }
    }
    func testNewUserAndLaterIncompleteAssistantInvalidateOldFinal() throws {
        try database { db, path in
            try message(db, id: "msg_Final", role: "assistant", offset: 5, parent: "msg_Current", finish: "stop", completed: 8)
            try message(db, id: "msg_Later", role: "assistant", offset: 9, parent: "msg_Current")
            XCTAssertNil(read(path))
            sqlite3_exec(db, "DELETE FROM message WHERE id='msg_Later';", nil, nil, nil)
            try message(db, id: "msg_New", role: "user", offset: 10)
            XCTAssertNil(read(path)); XCTAssertNil(read(path, turn: "msg_New"))
        }
    }
    func testIntermediateTruncatedErroredAndFutureMessagesAreNotSuccess() throws {
        for (finish, completed, error) in [("tool-calls", 8.0, nil), ("length", 8.0, nil),
                                           ("stop", 8.0, "MessageAbortedError"), ("stop", 30.0, nil)] {
            try database { db, path in
                try message(db, id: "msg_Final", role: "assistant", offset: 5, parent: "msg_Current",
                            finish: finish, completed: completed, error: error)
                XCTAssertNil(read(path))
            }
        }
    }
    func testOutstandingToolPreventsSuccessUntilNativeToolCompletes() throws {
        try database { db, path in
            try message(db, id: "msg_Tool", role: "assistant", offset: 2, parent: "msg_Current", finish: "tool-calls", completed: 3)
            try message(db, id: "msg_Final", role: "assistant", offset: 5, parent: "msg_Current", finish: "stop", completed: 8)
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO part VALUES('prt_Tool','msg_Tool','{\"type\":\"tool\",\"state\":{\"status\":\"running\"}}');", nil, nil, nil), SQLITE_OK)
            XCTAssertNil(read(path))
            sqlite3_exec(db, "UPDATE part SET data=json_set(data,'$.state.status','completed');", nil, nil, nil)
            XCTAssertNotNil(read(path))
        }
    }
    func testMissingDatabaseIsNotCreated() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertNil(read(path)); XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    private func workingStore() throws -> SessionStore {
        let store = SessionStore()
        var event = AgentEvent(sessionId: "ses_Root", agentKind: .opencode, eventName: "working", timestamp: at)
        event.opencodeTurnID = "msg_Current"; event.opencodeNewTurn = true; event.opencodeProcessID = 1234
        _ = store.apply(event, now: at)
        let s = try XCTUnwrap(store.session(id: "ses_Root"))
        _ = store.updateAionUiMetadata(id: s.id, createdAt: s.createdAt,
            record: .init(conversation: .init(id: "conversation", nativeSessionID: s.id, agentKind: .opencode), title: "Root"))
        return store
    }
    func testRecoveryKeepsNativeFinishTimeAndCreatesOneUnreadReceipt() throws {
        let store = try workingStore()
        var heartbeat = AgentEvent(sessionId: "ses_Root", agentKind: .opencode, eventName: "heartbeat", timestamp: at.addingTimeInterval(10))
        heartbeat.opencodeTurnID = "msg_Current"; heartbeat.opencodeProcessID = 1234
        _ = store.apply(heartbeat, now: heartbeat.timestamp)
        let expected = try XCTUnwrap(store.session(id: "ses_Root"))
        let record = OpencodeCompletedTurn.Record(sessionID: expected.id, turnID: "msg_Current", completedAt: at.addingTimeInterval(8))
        let done = try XCTUnwrap(store.reconcileOpencodeCompletion(expected: expected, record: record, now: at.addingTimeInterval(12)))
        XCTAssertEqual(done.state, .done); XCTAssertEqual(done.turnEndedAt, record.completedAt)
        XCTAssertEqual(done.opencodeTurnResult, .completed); XCTAssertTrue(done.hasUnread)
        XCTAssertEqual(done.opencodeEventAt, heartbeat.timestamp)
        XCTAssertNil(store.reconcileOpencodeCompletion(expected: done, record: record, now: at.addingTimeInterval(13)))
        XCTAssertEqual(store.session(id: done.id)?.notificationVersion, done.notificationVersion)
        XCTAssertNil(store.apply(heartbeat, now: at.addingTimeInterval(14)))
    }
    func testNewTurnMetadataRaceWaitingAndStaleCompletionAreRejected() throws {
        for eventName in ["working", "metadata", "waiting"] {
            let store = try workingStore(); let expected = try XCTUnwrap(store.session(id: "ses_Root"))
            var event = AgentEvent(sessionId: expected.id, agentKind: .opencode, eventName: eventName, timestamp: at.addingTimeInterval(5))
            event.opencodeTurnID = eventName == "working" ? "msg_New" : "msg_Current"
            event.opencodeNewTurn = eventName == "working"
            _ = store.apply(event, now: event.timestamp)
            let record = OpencodeCompletedTurn.Record(sessionID: expected.id, turnID: "msg_Current", completedAt: at.addingTimeInterval(8))
            XCTAssertNil(store.reconcileOpencodeCompletion(expected: expected, record: record, now: at.addingTimeInterval(12)))
        }
        let store = try workingStore(); let expected = try XCTUnwrap(store.session(id: "ses_Root"))
        let wrong = OpencodeCompletedTurn.Record(sessionID: expected.id, turnID: "msg_Old", completedAt: at.addingTimeInterval(-1))
        XCTAssertNil(store.reconcileOpencodeCompletion(expected: expected, record: wrong, now: at.addingTimeInterval(12)))
    }
}
