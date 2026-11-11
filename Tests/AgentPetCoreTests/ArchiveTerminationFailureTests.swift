import XCTest
@testable import AgentPetCore

/// Actual filesystem failures in disposable directories; no production data.
final class ArchiveTerminationFailureTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func blockedStore() throws -> (SessionStore, SessionArchiveStore, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-end-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("history")
        // A regular file blocks both the daily archive and .pending directory.
        try Data("synthetic-blocker".utf8).write(to: history)
        let archive = SessionArchiveStore(baseURL: history)
        let store = SessionStore(); store.archiveStore = archive
        let snapshot = root.appendingPathComponent("codex-sessions-v1.json")
        store.persistenceURL = snapshot
        return (store, archive, history, snapshot)
    }

    private func recover(_ history: URL) throws {
        XCTAssertEqual(try Data(contentsOf: history), Data("synthetic-blocker".utf8))
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    }

    private func event(_ kind: AgentKind, _ name: String, _ offset: TimeInterval) -> AgentEvent {
        var e = AgentEvent(sessionId: "synthetic-session", agentKind: kind, eventName: name,
                           timestamp: start.addingTimeInterval(offset))
        if kind == .opencode {
            e.opencodeTurnID = offset < 15 ? "turn-1" : "turn-2"
            e.opencodeNewTurn = name == "working"
        }
        return e
    }

    private func trace(_ scenario: String, _ step: String, _ store: SessionStore, _ archive: SessionArchiveStore) throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTPET_ARCHIVE_FAILURE_TRACE"] else { return }
        struct Trace: Encodable {
            let scenario: String; let step: String; let sessions: [AgentSession]
            let pending: Int; let durablePending: Int; let archived: [SessionArchive]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(Trace(scenario: scenario, step: step,
            sessions: store.sessions.sorted { $0.id < $1.id }, pending: archive.pendingCount,
            durablePending: archive.durablePendingCount, archived: archive.records(for: start)))
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }

    func testSessionEndDoubleFailureRetainsClaudeAndPiUntilSafeRetry() throws {
        for kind: AgentKind in [.claude, .pi] {
            let (store, archive, history, _) = try blockedStore()
            let working = event(kind, "working", 0)
            let original = try XCTUnwrap(store.apply(working, now: start))
            let end = event(kind, kind == .claude ? "SessionEnd" : "session_shutdown", 10)
            try trace(kind.rawValue, "working", store, archive)
            XCTAssertNil(store.apply(end, now: end.timestamp))
            try trace(kind.rawValue, "double-failure", store, archive)
            XCTAssertEqual(store.session(id: working.sessionId), original, "No durable archive: retain the complete source session")
            XCTAssertEqual(archive.pendingCount, 1); XCTAssertEqual(archive.durablePendingCount, 0)
            XCTAssertNotNil(archive.lastFailure)
            try recover(history)
            store.prune(now: start.addingTimeInterval(11))
            XCTAssertEqual(archive.pendingCount, 0)
            let saved = try XCTUnwrap(archive.recordsChecked(for: start).first)
            XCTAssertEqual(saved.startedAt, start); XCTAssertEqual(saved.endedAt, end.timestamp)
            // Replayed termination may now remove the safely archived source.
            store.apply(end, now: start.addingTimeInterval(12))
            XCTAssertNil(store.session(id: working.sessionId))
            store.apply(end, now: start.addingTimeInterval(13))
            XCTAssertEqual(try archive.recordsChecked(for: start).count, 1)
            try trace(kind.rawValue, "safe-retry", store, archive)
        }
    }

    func testOpencodeDeletedDoubleFailurePreservesV1SnapshotAndOriginalArchiveTime() throws {
        let (store, archive, history, snapshot) = try blockedStore()
        let working = event(.opencode, "working", 0)
        let original = try XCTUnwrap(store.apply(working, now: start))
        let before = try Data(contentsOf: snapshot)
        let end = event(.opencode, "deleted", 10)
        try trace("opencode", "working", store, archive)
        XCTAssertNil(store.apply(end, now: end.timestamp))
        try trace("opencode", "double-failure", store, archive)
        XCTAssertEqual(store.session(id: working.sessionId), original)
        XCTAssertEqual(try Data(contentsOf: snapshot), before, "Failed archive must not save a deleted source into v1")
        XCTAssertEqual(archive.pendingCount, 1); XCTAssertEqual(archive.durablePendingCount, 0)
        let restored = SessionStore(); restored.persistenceURL = snapshot; restored.restoreCodexSessions()
        XCTAssertEqual(restored.session(id: working.sessionId), original)
        try recover(history)
        store.apply(end, now: start.addingTimeInterval(12))
        XCTAssertNil(store.session(id: working.sessionId))
        let saved = try XCTUnwrap(archive.recordsChecked(for: start).first)
        XCTAssertEqual(saved.endedAt, end.timestamp); XCTAssertEqual(saved.duration, 10)
        let empty = SessionStore(); empty.persistenceURL = snapshot; empty.restoreCodexSessions()
        XCTAssertTrue(empty.sessions.isEmpty)
        store.apply(end, now: start.addingTimeInterval(13))
        XCTAssertEqual(try archive.recordsChecked(for: start).count, 1)
        try trace("opencode", "safe-retry", store, archive)
    }

    func testPeriodicArchiveRetryDoesNotDeleteNewWorkWithTheSameID() throws {
        let (store, archive, history, _) = try blockedStore()
        let working = event(.opencode, "working", 0)
        store.apply(working, now: start)
        store.apply(event(.opencode, "deleted", 10), now: start.addingTimeInterval(10))
        let next = event(.opencode, "working", 20)
        let newTurn = try XCTUnwrap(store.apply(next, now: next.timestamp))
        try trace("new-turn", "working-after-failure", store, archive)
        try recover(history)
        store.prune(now: start.addingTimeInterval(21))
        XCTAssertEqual(store.session(id: next.sessionId), newTurn)
        XCTAssertEqual(newTurn.opencodeTurnID, "turn-2")
        XCTAssertEqual(try archive.recordsChecked(for: start).first?.endedAt, start.addingTimeInterval(10))
        XCTAssertEqual(archive.pendingCount, 0)
        try trace("new-turn", "old-archive-retried", store, archive)
    }
}
