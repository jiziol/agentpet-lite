import XCTest
import CSQLite
@testable import AgentPetCore

final class OpencodeSubagentTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1000)
    private func event(_ id: String, _ name: String = "working", offset: Double = 0) -> AgentEvent {
        var e = AgentEvent(sessionId: id, agentKind: .opencode, eventName: name, timestamp: at.addingTimeInterval(offset))
        e.opencodeTurnID = "msg_User"; e.opencodeNewTurn = name == "working"
        if name == "done" { e.turnResult = .completed }
        return e
    }
    func testNativeParentFieldDoesNotConfuseMessageParent() throws {
        var frame: [String: Any] = ["version": 1, "event": "metadata", "session_id": "ses_Child", "parent_session_id": "ses_Parent", "timestamp": 1000]
        XCTAssertEqual(OpencodeHookPayload.event(from: try JSONSerialization.data(withJSONObject: frame), now: at)?.opencodeParentSessionID, "ses_Parent")
        for invalid in ["msg_User", "ses_Child", "../ses_Parent", String(repeating: "a", count: 200)] {
            frame["parent_session_id"] = invalid
            XCTAssertNil(OpencodeHookPayload.event(from: try JSONSerialization.data(withJSONObject: frame), now: at)?.opencodeParentSessionID)
        }
    }
    func testNewChildNeverCreatesRowOrEndsParentAndOtherRootsRemainIndependent() {
        let store = SessionStore()
        _ = store.apply(event("ses_Parent"), now: at)
        _ = store.apply(event("ses_Other"), now: at)
        let parentBefore = store.session(id: "ses_Parent")
        for name in ["working", "waiting", "done", "metadata", "deleted", "heartbeat"] {
            var e = event("ses_Child", name, offset: 1); e.opencodeParentSessionID = "ses_Parent"
            XCTAssertNil(store.apply(e, now: e.timestamp))
        }
        XCTAssertNil(store.session(id: "ses_Child"))
        XCTAssertEqual(store.session(id: "ses_Parent"), parentBefore)
        XCTAssertEqual(Set(store.sorted.map(\.id)), ["ses_Parent", "ses_Other"])
    }
    func testLegacyChildRelationHidesWithoutRewritingReceiptsOrHost() throws {
        let store = SessionStore()
        _ = store.apply(event("ses_Parent"), now: at)
        _ = store.apply(event("ses_Child"), now: at)
        _ = store.apply(event("ses_Child", "done", offset: 2), now: at.addingTimeInterval(2))
        let original = try XCTUnwrap(store.session(id: "ses_Child"))
        let parent = store.session(id: "ses_Parent")
        var relation = event("ses_Child", "metadata", offset: 1) // Immutable fact may arrive out of order.
        relation.opencodeParentSessionID = "ses_Parent"
        XCTAssertNil(store.apply(relation, now: at.addingTimeInterval(3)))
        var expected = original; expected.opencodeParentSessionID = "ses_Parent"
        XCTAssertEqual(store.session(id: "ses_Child"), expected)
        XCTAssertEqual(store.session(id: "ses_Parent"), parent)
        XCTAssertEqual(store.sorted.map(\.id), ["ses_Parent"])
        XCTAssertEqual(store.sessions.count, 2, "saved child is retained rather than erased")
        XCTAssertTrue(SessionNotificationPolicy.effects(before: .working, session: expected).isEmpty)
        XCTAssertNil(store.apply(event("ses_Child", "working", offset: 4), now: at.addingTimeInterval(4)), "old loaded plugin cannot reopen a classified child")
        XCTAssertEqual(store.session(id: "ses_Child"), expected)
    }
    func testExactInstanceAndValidationForLegacyRepair() {
        let store = SessionStore(); _ = store.apply(event("ses_Child"), now: at)
        XCTAssertFalse(store.updateOpencodeParent(id: "ses_Child", createdAt: at.addingTimeInterval(1), parentID: "ses_Parent"))
        for invalid in ["ses_Child", "msg_User", "../ses_Parent"] {
            XCTAssertFalse(store.updateOpencodeParent(id: "ses_Child", createdAt: at, parentID: invalid))
        }
        XCTAssertTrue(store.updateOpencodeParent(id: "ses_Child", createdAt: at, parentID: "ses_Parent"))
        XCTAssertFalse(store.updateOpencodeParent(id: "ses_Child", createdAt: at, parentID: "ses_Other"))
    }
    func testChildHumanRequestsAreFilteredBeforeSharedRequestReducer() throws {
        let store = SessionStore(); _ = store.apply(event("ses_Parent"), now: at)
        var request = event("ses_Child", "waiting", offset: 1)
        request.opencodeParentSessionID = "ses_Parent"
        request.humanIntervention = .init(action: .asked, requests: [.init(id: "perm_Child", kind: .permission, createdAt: request.timestamp)])
        let parent = store.session(id: "ses_Parent")
        XCTAssertNil(store.apply(request, now: request.timestamp)); XCTAssertNil(store.session(id: "ses_Child"))
        _ = store.apply(event("ses_Child"), now: at)
        XCTAssertTrue(store.updateOpencodeParent(id: "ses_Child", createdAt: at, parentID: "ses_Parent"))
        let child = store.session(id: "ses_Child")
        request.opencodeParentSessionID = nil // Previously loaded .60 plugin.
        XCTAssertNil(store.apply(request, now: request.timestamp)); XCTAssertEqual(store.session(id: "ses_Child"), child)
        XCTAssertEqual(store.session(id: "ses_Parent"), parent)
    }
    func testSnapshotRoundTripPreservesLegacyDataAndAcceptsOldSnapshots() throws {
        var child = AgentSession(id: "ses_Child", agentKind: .opencode, state: .done, source: .hook, updatedAt: at)
        child.opencodeParentSessionID = "ses_Parent"; child.notificationVersion = 7; child.readThroughVersion = 5
        let data = try JSONEncoder().encode(child)
        XCTAssertEqual(try JSONDecoder().decode(AgentSession.self, from: data), child)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "opencodeParentSessionID")
        let old = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.isOpencodeSubagent); XCTAssertEqual(old.notificationVersion, 7)
        XCTAssertEqual(old.readThroughVersion, 5)
        let store = SessionStore(); let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(SessionSnapshotDTO(sessions: [child])).write(to: url)
        store.persistenceURL = url; store.restoreCodexSessions()
        XCTAssertTrue(store.sorted.isEmpty); XCTAssertEqual(store.session(id: child.id), child)
        store.persistCodexSessions()
        XCTAssertEqual(try JSONDecoder().decode(SessionSnapshotDTO.self, from: Data(contentsOf: url)).sessions, [child])
    }
    func testReadOnlyExactDatabaseParentLookupIncludingNestedChildren() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT); INSERT INTO session VALUES ('ses_Parent',NULL),('ses_Child','ses_Parent'),('ses_Nested','ses_Child'),('ses_Self','ses_Self'),('ses_Invalid','msg_User');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(OpencodeSessionMetadata.parentID(sessionID: "ses_Child", databasePath: url.path), "ses_Parent")
        XCTAssertEqual(OpencodeSessionMetadata.parentID(sessionID: "ses_Nested", databasePath: url.path), "ses_Child")
        for id in ["ses_Parent", "ses_Missing", "ses_Self", "ses_Invalid", "' OR 1=1"] {
            XCTAssertNil(OpencodeSessionMetadata.parentID(sessionID: id, databasePath: url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        let absent = url.path + "missing"
        XCTAssertNil(OpencodeSessionMetadata.parentID(sessionID: "ses_Child", databasePath: absent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent))
    }
}
