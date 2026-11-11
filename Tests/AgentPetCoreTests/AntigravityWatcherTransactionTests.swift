import Foundation
import XCTest
@testable import AgentPetCore
import CSQLite

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []
    let ready = DispatchSemaphore(value: 0)
    func add() { lock.lock(); values.append(DispatchTime.now().uptimeNanoseconds); lock.unlock(); ready.signal() }
    func latest() -> UInt64 { lock.lock(); defer { lock.unlock() }; return values.last! }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
private func field(_ n: Int, _ data: Data) -> Data { Data([UInt8(n << 3 | 2), UInt8(data.count)]) + data }
private func hex(_ data: Data) -> String { data.map { String(format:"%02x", $0) }.joined() }
private func sql(_ db: OpaquePointer?, _ text: String) { precondition(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK, "fixture SQL") }
private func fixture(_ path: String, cancelled: Bool) -> OpaquePointer? {
    var db: OpaquePointer?; precondition(sqlite3_open(path,&db) == SQLITE_OK)
    let meta = field(12,Data("latency-probe".utf8)) + field(1,Data([8,100]))
    let payload = Data([8,1,32,3])
    sql(db,"CREATE TABLE steps(idx INTEGER PRIMARY KEY,step_type INTEGER,status INTEGER,metadata BLOB,step_payload BLOB)")
    sql(db,"INSERT INTO steps VALUES(0,1,3,X'\(hex(meta))',X'\(hex(payload))')")
    sql(db,"CREATE TABLE executor_metadata(idx INTEGER PRIMARY KEY,data BLOB)")
    setReason(db,cancelled:cancelled)
    return db
}
private func setReason(_ db: OpaquePointer?, cancelled: Bool) {
    let data=Data([8, cancelled ? 2:4]) + field(9,Data("latency-probe".utf8))
    sql(db,"INSERT OR REPLACE INTO executor_metadata VALUES(0,X'\(hex(data))')")
}
private func watcher(_ path: String, _ probe: Probe) -> AntigravityHumanInputWatcher {
    let value=AntigravityHumanInputWatcher(cancellationHandler:{ _,_ in probe.add() },handler:{ _,_,_ in })
    value.watch(sessionID:"own-fixture",path:path,latestHookAt:Date(timeIntervalSince1970:101),stepFloor:0)
    return value
}
final class AntigravityWatcherTransactionTests: XCTestCase {
    private func withFixture(_ body: (String, OpaquePointer?) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("transaction.db").path
        let db = fixture(path, cancelled: false)
        defer { sqlite3_close(db) }
        try body(path, db)
    }

    func testActiveTransactionIsIgnoredThenCommitIsObservedOnce() throws {
        try withFixture { path, db in
            sql(db, "BEGIN IMMEDIATE"); setReason(db, cancelled: true)
            let p = Probe(); let w = watcher(path, p)
            XCTAssertEqual(p.ready.wait(timeout: .now() + 0.12), .timedOut)
            XCTAssertNil(AntigravityHumanInput.readSnapshot(path: path))
            sql(db, "COMMIT")
            XCTAssertEqual(p.ready.wait(timeout: .now() + 2), .success)
            for _ in 0..<5 { sql(db, "BEGIN IMMEDIATE"); setReason(db, cancelled: true); sql(db, "COMMIT") }
            XCTAssertEqual(p.ready.wait(timeout: .now() + 0.2), .timedOut)
            XCTAssertEqual(p.count, 1)
            w.retain(sessionIDs: [])
        }
    }

    func testRolledBackCancellationIsNeverReported() throws {
        try withFixture { path, db in
            sql(db, "BEGIN IMMEDIATE"); setReason(db, cancelled: true)
            let p = Probe(); let w = watcher(path, p)
            XCTAssertEqual(p.ready.wait(timeout: .now() + 0.12), .timedOut)
            sql(db, "ROLLBACK")
            XCTAssertEqual(p.ready.wait(timeout: .now() + 0.3), .timedOut)
            XCTAssertNil(AntigravityHumanInput.readSnapshot(path: path)?.cancellation)
            setReason(db, cancelled: true)
            XCTAssertEqual(p.ready.wait(timeout: .now() + 2), .success)
            w.retain(sessionIDs: [])
        }
    }

    func testRemovedSessionCannotDeliverQueuedRetry() throws {
        try withFixture { path, db in
            sql(db, "BEGIN IMMEDIATE"); setReason(db, cancelled: true)
            let p = Probe(); let w = watcher(path, p)
            XCTAssertEqual(p.ready.wait(timeout: .now() + 0.12), .timedOut)
            w.retain(sessionIDs: [])
            sql(db, "COMMIT")
            XCTAssertEqual(p.ready.wait(timeout: .now() + 0.3), .timedOut)
            XCTAssertEqual(p.count, 0)
        }
    }
}
