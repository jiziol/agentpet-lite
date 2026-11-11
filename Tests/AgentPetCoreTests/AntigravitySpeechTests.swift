import XCTest
import Foundation
import CSQLite
@testable import AgentPetCore

private func v(_ n: UInt64) -> Data {
    var n = n; var b: [UInt8] = []
    repeat { let x = UInt8(n & 127); n >>= 7; b.append(x | (n == 0 ? 0 : 128)) } while n != 0
    return Data(b)
}
private func scalar(_ n: Int, _ x: UInt64) -> Data { v(UInt64(n << 3)) + v(x) }
private func bytes(_ n: Int, _ x: Data) -> Data { v(UInt64(n << 3 | 2)) + v(UInt64(x.count)) + x }
private func text(_ n: Int, _ x: String) -> Data { bytes(n, Data(x.utf8)) }
private func ts(_ date: Date) -> Data {
    let t = date.timeIntervalSince1970; let seconds = floor(t)
    return scalar(1, UInt64(seconds)) + scalar(2, UInt64((t - seconds) * 1e9))
}
private func hex(_ x: Data) -> String { x.map { String(format: "%02x", $0) }.joined() }
private func sql(_ db: OpaquePointer?, _ s: String) { precondition(sqlite3_exec(db, s, nil, nil, nil) == SQLITE_OK, s) }
private func meta(_ date: Date, execution: String = "execution") -> Data {
    text(12, execution) + bytes(1, ts(date.addingTimeInterval(-1))) + bytes(6, ts(date)) + bytes(7, ts(date)) + bytes(8, ts(date))
}
private func payload(_ body: String, status: Int = 3, type: Int = 15) -> Data {
    scalar(1, UInt64(type)) + scalar(4, UInt64(status)) + bytes(20, text(1, body) + text(3, "PRIVATE_THINKING") + text(16, "PRIVATE_RAW_THINKING"))
}
private final class Messages: @unchecked Sendable {
    private let lock = NSLock(); private var values: [AntigravityVisibleMessage] = []
    let ready = DispatchSemaphore(value: 0)
    func append(_ m: AntigravityVisibleMessage) { lock.lock(); values.append(m); lock.unlock(); ready.signal() }
    var all: [AntigravityVisibleMessage] { lock.lock(); defer { lock.unlock() }; return values }
}
final class AntigravitySpeechTests: XCTestCase {
    private func session(_ at: Date) -> AgentSession {
        var s = AgentSession(id: "00000000-0000-4000-8000-000000000007", agentKind: .antigravity, state: .working, source: .hook, updatedAt: at)
        s.createdAt = at; s.turnStartedAt = at; s.antigravityEventAt = at; s.antigravityStepFloor = 10
        return s
    }
    private func withDB(_ body: (String, String, OpaquePointer?) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("native.db").path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sql(db, "CREATE TABLE steps(idx INTEGER PRIMARY KEY,step_type INTEGER,status INTEGER,metadata BLOB,step_payload BLOB)")
        sql(db, "CREATE TABLE executor_metadata(idx INTEGER PRIMARY KEY,data BLOB)")
        sql(db, "INSERT INTO executor_metadata VALUES(0,X'\(hex(scalar(1,4) + scalar(3,10) + text(9,"execution")))')")
        try body(path, dir.appendingPathComponent("host.db").path, db)
    }
    private func insert(_ db: OpaquePointer?, at: Date, index: Int = 10, execution: String = "execution", body: String = "正在检查布局", status: Int = 3) {
        sql(db, "INSERT OR REPLACE INTO steps VALUES(\(index),15,\(status),X'\(hex(meta(at, execution: execution)))',X'\(hex(payload(body, status: status)))')")
    }
    func testParserSelectsOnlyPublicCommittedTextAndRejectsMalformedFields() {
        let at = Date()
        XCTAssertEqual(AntigravityPublicResponse.step(index: 10, metadata: meta(at), payload: payload("公开正文"))?.text, "公开正文")
        XCTAssertNil(AntigravityPublicResponse.step(index: 10, metadata: meta(at), payload: payload("")))
        XCTAssertNil(AntigravityPublicResponse.step(index: 10, metadata: meta(at), payload: payload("公开正文", status: 2)))
        XCTAssertNil(AntigravityPublicResponse.step(index: 10, metadata: meta(at), payload: payload("工具结果", type: 132)))
        XCTAssertNil(AntigravityPublicResponse.step(index: 10, metadata: meta(at), payload: Data([0xA2, 0x01, 0xFF])))
        XCTAssertNil(AntigravityPublicResponse.fields(Data(repeating: 0, count: 1_048_577), selecting: [1]))
    }
    func testExactExecutorFloorAndCancellationRejectOldResponses() throws {
        try withDB { path, _, db in
            let at = Date(); let boundary = AntigravityVisibleMessage.Boundary(session: session(at.addingTimeInterval(-5)), enabledAt: at)!
            insert(db, at: at, execution: "old-execution")
            XCTAssertNil(AntigravityPublicResponse.read(path: path, boundary: boundary)?.step)
            insert(db, at: at, index: 9)
            XCTAssertNil(AntigravityPublicResponse.read(path: path, boundary: boundary)?.step)
            insert(db, at: at)
            XCTAssertEqual(AntigravityPublicResponse.read(path: path, boundary: boundary)?.step?.index, 10)
            sql(db, "UPDATE executor_metadata SET data=X'\(hex(scalar(1,2) + scalar(3,10) + text(9,"execution")))'")
            let cancelled = try XCTUnwrap(AntigravityPublicResponse.read(path: path, boundary: boundary))
            XCTAssertTrue(cancelled.cancelled); XCTAssertNil(cancelled.step)
        }
    }
    func testOnlyCommittedWritesReachWatcherAndHistoryNeverReplays() throws {
        try withDB { path, host, db in
            let at = Date(); insert(db, at: at.addingTimeInterval(-1))
            let messages = Messages(); let watcher = AntigravitySpeechWatcher(database: host) { _, m in messages.append(m) }
            watcher.watch(path: path, boundary: AntigravityVisibleMessage.Boundary(session: session(at.addingTimeInterval(-5)), enabledAt: at)!)
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 0.2), .timedOut)
            sql(db, "BEGIN IMMEDIATE"); insert(db, at: Date())
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 0.15), .timedOut)
            sql(db, "COMMIT")
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(messages.all.first?.text, "正在检查布局")
            XCTAssertFalse(messages.all.first!.text.contains("PRIVATE"))
            insert(db, at: Date())
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 0.2), .timedOut)
            XCTAssertEqual(messages.all.count, 1)
            watcher.retain(sessionIDs: [])
        }
    }
    func testRollbackAndRemovedWatchCannotPublish() throws {
        try withDB { path, host, db in
            let at = Date(); let messages = Messages()
            let w = AntigravitySpeechWatcher(database: host) { _, m in messages.append(m) }
            w.watch(path: path, boundary: AntigravityVisibleMessage.Boundary(session: session(at), enabledAt: at)!)
            sql(db, "BEGIN IMMEDIATE"); insert(db, at: Date())
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 0.15), .timedOut)
            sql(db, "ROLLBACK")
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 0.25), .timedOut)
            w.retain(sessionIDs: [])
            insert(db, at: Date())
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 0.3), .timedOut)
        }
    }
    func testBoundaryRejectsNewBirthTurnHookFloorCancelAndMissingFloor() {
        let at = Date(); let s = session(at); let b = AntigravityVisibleMessage.Boundary(session: s, enabledAt: at)!
        XCTAssertTrue(b.matches(s))
        var changed = s; changed.antigravityStepFloor = 11; XCTAssertFalse(b.matches(changed))
        changed = s; changed.antigravityEventAt = at.addingTimeInterval(1); XCTAssertFalse(b.matches(changed))
        changed = s; changed.createdAt = at.addingTimeInterval(1); XCTAssertFalse(b.matches(changed))
        changed = s; changed.turnStartedAt = at.addingTimeInterval(1); XCTAssertFalse(b.matches(changed))
        changed = s; changed.antigravityTurnResult = .cancelled; XCTAssertFalse(b.matches(changed))
        changed = s; changed.antigravityStepFloor = nil; XCTAssertNil(AntigravityVisibleMessage.Boundary(session: changed, enabledAt: at))
    }
    func testHostPublicRowRewriteHideAndExactConversation() throws {
        try withDB { _, host, _ in
            var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(host, &db), SQLITE_OK); defer { sqlite3_close(db) }
            sql(db, "CREATE TABLE conversations(id TEXT,name TEXT,type TEXT,extra TEXT,archived_at INTEGER)")
            sql(db, "CREATE TABLE acp_session(conversation_id TEXT,session_id TEXT)")
            sql(db, "CREATE TABLE messages(msg_id TEXT,conversation_id TEXT,content TEXT,hidden INTEGER,type TEXT,position TEXT,created_at INTEGER)")
            sql(db, "INSERT INTO conversations VALUES('host',NULL,'acp','{\"backend\":\"antigravity\"}',NULL)")
            let at = Date(); let s = session(at)
            sql(db, "INSERT INTO acp_session VALUES('host','\(s.id)')")
            sql(db, "INSERT INTO messages VALUES('m','host','{\"content\":\"公开正文\\n\"}',0,'text','left',\(Int64(at.timeIntervalSince1970 * 1000)))")
            let step = AntigravityPublicResponse.Step(index: 10, executionID: "execution", completedAt: at, text: "公开正文")
            func row(_ known: String? = nil) -> AntigravityHostVisibility.Row? {
                AntigravityHostVisibility.read(nativeID: s.id, step: step, startedAt: at.addingTimeInterval(-1), knownRow: known, database: host)
            }
            XCTAssertEqual(row()?.id, "m")
            sql(db, "UPDATE messages SET content='{\"content\":\"改写正文\"}'")
            XCTAssertEqual(row("m")?.text, "改写正文")
            XCTAssertNil(row()) // Different public body cannot establish a guessed association.
            sql(db, "UPDATE messages SET hidden=1")
            XCTAssertNil(row("m")?.text)
            sql(db, "UPDATE messages SET hidden=0,position='right'")
            XCTAssertNil(row("m")?.text)
            sql(db, "DELETE FROM acp_session")
            XCTAssertNil(AntigravityHostVisibility.read(nativeID: s.id, step: step, startedAt: at, knownRow: nil, previouslyHosted: true, database: host))
        }
    }
    func testHostWALCommitGatesPublicOutputAndWithdrawsHiddenRow() throws {
        try withDB { path, host, nativeDB in
            var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(host, &db), SQLITE_OK); defer { sqlite3_close(db) }
            sql(db, "PRAGMA journal_mode=WAL")
            sql(db, "CREATE TABLE conversations(id TEXT,name TEXT,type TEXT,extra TEXT,archived_at INTEGER)")
            sql(db, "CREATE TABLE acp_session(conversation_id TEXT,session_id TEXT)")
            sql(db, "CREATE TABLE messages(msg_id TEXT,conversation_id TEXT,content TEXT,hidden INTEGER,type TEXT,position TEXT,created_at INTEGER)")
            var s = session(Date().addingTimeInterval(-1))
            s.aionUiConversation = AionUiConversation(id: "host", nativeSessionID: s.id, agentKind: .antigravity)
            sql(db, "INSERT INTO conversations VALUES('host',NULL,'acp','{\"backend\":\"antigravity\"}',NULL)")
            sql(db, "INSERT INTO acp_session VALUES('host','\(s.id)')")
            let messages = Messages(); let w = AntigravitySpeechWatcher(database: host) { _, m in messages.append(m) }
            w.watch(path: path, boundary: AntigravityVisibleMessage.Boundary(session: s, enabledAt: Date())!)
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 0.15), .timedOut)
            let completed = Date(); insert(nativeDB, at: completed)
            sql(db, "INSERT INTO messages VALUES('public','host','{\"content\":\"正在检查布局\"}',1,'text','left',\(Int64(completed.timeIntervalSince1970 * 1000)))")
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 0.2), .timedOut)
            sql(db, "UPDATE messages SET hidden=0")
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(messages.all.last?.text, "正在检查布局")
            sql(db, "UPDATE messages SET content='{\"content\":\"宿主改写后的公开正文\"}'")
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(messages.all.last?.text, "宿主改写后的公开正文")
            XCTAssertEqual(messages.all.first?.timestamp, messages.all.last?.timestamp)
            sql(db, "UPDATE messages SET hidden=1")
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(messages.all.last?.mode, .withdraw)
            sql(db, "UPDATE messages SET hidden=0")
            XCTAssertEqual(messages.ready.wait(timeout: .now() + 0.2), .timedOut)
            w.retain(sessionIDs: [])
        }
    }
}
