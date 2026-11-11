import XCTest
import CSQLite
@testable import AgentPetCore

final class CodexIntegrationTests: XCTestCase {
    private let a = "11111111-1111-4111-8111-111111111111"
    private let b = "22222222-2222-4222-8222-222222222222"

    func testDesktopURLRejectsInjectedPathsAndQueries() {
        XCTAssertEqual(CodexMetadata.threadURL(sessionID: a)?.absoluteString, "codex://threads/\(a)")
        for id in ["new", "../settings", a + "?prompt=run", "", a + "/"] {
            XCTAssertNil(CodexMetadata.threadURL(sessionID: id))
        }
    }

    func testMetadataUsesExactIDAndCurrentRenamedTitle() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,name TEXT,model TEXT,rollout_path TEXT,originator TEXT); INSERT INTO threads VALUES('\(a)','Original','Renamed','model-a','/synthetic/a.jsonl','Codex Desktop'); INSERT INTO threads VALUES('\(b)','Other',NULL,'model-b','/synthetic/b.jsonl','cli');", nil, nil, nil), SQLITE_OK)
        let record = CodexMetadata.read(sessionID: a, home: home.path)
        XCTAssertEqual(record?.title, "Renamed")
        XCTAssertEqual(record?.model, "model-a")
        XCTAssertEqual(record?.isDesktop, true)
        XCTAssertEqual(CodexMetadata.read(sessionID: b, home: home.path)?.isDesktop, false)
        sqlite3_exec(db, "UPDATE threads SET name='Renamed again' WHERE id='\(a)'", nil, nil, nil)
        XCTAssertEqual(CodexMetadata.read(sessionID: a, home: home.path)?.title, "Renamed again")
        XCTAssertNil(CodexMetadata.read(sessionID: "33333333-3333-4333-8333-333333333333", home: home.path))
    }

    func testMigratedCLIRequiresExactLocalDesktopActivityAndNonCLISource() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,originator TEXT,source TEXT); INSERT INTO threads VALUES('\(a)','Migrated','codex-tui','vscode'); INSERT INTO threads VALUES('\(b)','CLI','codex-tui','cli');", nil, nil, nil), SQLITE_OK)
        let file = home.appendingPathComponent(".codex-global-state.json")
        func writeActivity(_ activity: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": ["thread-user-activity-times-v1": activity]]).write(to: file)
        }
        XCTAssertEqual(CodexMetadata.read(sessionID: a, home: home.path)?.isDesktop, false)
        // Another thread, a remote identity, or a malformed key cannot authorize this local thread.
        for key in ["[\"local\",\"\(b)\"]", "[\"remote\",\"\(a)\"]", a] {
            try writeActivity([key: 1_700_000_000_000])
            XCTAssertEqual(CodexMetadata.read(sessionID: a, home: home.path)?.isDesktop, false)
        }
        let localKey = "[\"local\",\"\(a)\"]"
        for invalid: Any in [true, "1700000000000", 0, -1] {
            try writeActivity([localKey: invalid])
            XCTAssertEqual(CodexMetadata.read(sessionID: a, home: home.path)?.isDesktop, false)
        }
        // Persistent desktop use is navigation capability, not a short-lived activity lease.
        try writeActivity([localKey: 1_700_000_000_000, "[\"local\",\"\(b)\"]": 1_700_000_000_000])
        XCTAssertEqual(CodexMetadata.read(sessionID: a, home: home.path)?.isDesktop, true)
        XCTAssertEqual(CodexMetadata.read(sessionID: b, home: home.path)?.isDesktop, false)
        // Moving back to the CLI must discard the historical desktop fallback.
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET source='cli' WHERE id='\(a)'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(CodexMetadata.read(sessionID: a, home: home.path)?.isDesktop, false)
    }

    func testDesktopActivityFallbackFailsClosedOnUnsupportedOrOversizedState() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,originator TEXT,source TEXT); INSERT INTO threads VALUES('\(a)','Migrated','codex-tui','vscode'); INSERT INTO threads VALUES('\(b)','Desktop','Codex Desktop','vscode');", nil, nil, nil), SQLITE_OK)
        let file = home.appendingPathComponent(".codex-global-state.json")
        for data in [Data("{".utf8), Data("{\"electron-persisted-atom-state\":{\"thread-user-activity-times-v2\":{}}}".utf8), Data(repeating: 32, count: 4_194_305)] {
            try data.write(to: file)
            XCTAssertEqual(CodexMetadata.read(sessionID: a, home: home.path)?.isDesktop, false)
            XCTAssertEqual(CodexMetadata.read(sessionID: b, home: home.path)?.isDesktop, true)
        }
    }

    func testMigratedDesktopTabsSurviveActivityEvictionAndRejectInvalidMarkers() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,originator TEXT,source TEXT); INSERT INTO threads VALUES('\(a)','Migrated','codex-tui','vscode'); INSERT INTO threads VALUES('\(b)','CLI','codex-tui','cli');", nil, nil, nil), SQLITE_OK)
        let file = home.appendingPathComponent(".codex-global-state.json")
        func write(_ atoms: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": atoms]).write(to: file)
        }
        let valid: [String: Any] = ["version": 1, "routes": [], "topology": [:]]
        try write(["thread-tab-routes-v1:" + b: valid])
        XCTAssertEqual(CodexMetadata.read(sessionID: a, home: home.path)?.isDesktop, false)
        for invalid: Any in [[:], ["version": 2, "routes": [], "topology": [:]],
                             ["version": true, "routes": [], "topology": [:]],
                             ["version": 1.5, "routes": [], "topology": [:]],
                             ["version": 1, "routes": "invalid", "topology": [:]],
                             ["version": 1, "routes": [], "topology": []]] {
            try write(["thread-tab-routes-v1:" + a: invalid])
            XCTAssertEqual(CodexMetadata.read(sessionID: a, home: home.path)?.isDesktop, false)
        }
        try write(["thread-tab-routes-v1:" + a: valid, "thread-tab-routes-v1:" + b: valid])
        XCTAssertEqual(CodexMetadata.read(sessionID: a, home: home.path)?.isDesktop, true)
        XCTAssertEqual(CodexMetadata.read(sessionID: b, home: home.path)?.isDesktop, false)
    }

    func testCodexToolActivityDoesNotExposeCommandArguments() throws {
        let input: [String: Any] = ["session_id": a, "hook_event_name": "PreToolUse", "tool_name": "functions.exec_command", "tool_input": ["cmd": "curl -H 'Authorization: SECRET' https://example.invalid"], "model": "example-model"]
        let event = HookPayload.event(forAgent: .codex, stdin: try JSONSerialization.data(withJSONObject: input), now: Date())
        XCTAssertEqual(event?.message, "正在执行命令")
        XCTAssertEqual(event?.model, "example-model")
        XCTAssertFalse(event?.message?.contains("SECRET") ?? true)
        XCTAssertEqual(CodexHookPayload.activity(event: "PreToolUse", tool: "functions.read_file", input: ["path": "/private/project/Test.swift"]), "正在读取 Test.swift")
    }

    func testChildCompletionDoesNotCompleteParent() {
        let store = SessionStore()
        store.apply(event(a, "UserPromptSubmit", 1), now: date(1))
        XCTAssertNil(store.apply(event(a, "SubagentStop", 2), now: date(2)))
        XCTAssertEqual(store.session(id: a)?.state, .working)
    }

    func testUnreadSurvivesPruningRestartAndOldReadAcknowledgement() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore()
        store.persistenceURL = dir.appendingPathComponent("state.json")
        store.apply(event(a, "UserPromptSubmit", 1), now: date(1))
        store.apply(event(a, "PermissionRequest", 2), now: date(2))
        let clickedVersion = try XCTUnwrap(store.session(id: a)?.notificationVersion)
        store.apply(event(a, "PreToolUse", 3), now: date(3))
        store.apply(event(a, "Stop", 4), now: date(4))
        store.markRead(id: a, through: clickedVersion)
        store.prune(now: date(10000))
        XCTAssertEqual(store.session(id: a)?.state, .done)
        XCTAssertEqual(store.session(id: a)?.hasUnread, true)
        XCTAssertEqual(store.session(id: a)?.turnStartedAt, date(1))
        XCTAssertEqual(store.session(id: a)?.turnEndedAt, date(4))
        let restored = SessionStore()
        restored.persistenceURL = store.persistenceURL
        restored.restoreCodexSessions()
        XCTAssertEqual(restored.session(id: a), store.session(id: a))
        restored.markRead(id: a, through: 999)
        XCTAssertEqual(restored.session(id: a)?.hasUnread, false)
    }

    func testLateAndDuplicateEventsDoNotChangeCompletionOrUnreadVersion() {
        let store = SessionStore()
        store.apply(event(a, "UserPromptSubmit", 1), now: date(1))
        store.apply(event(a, "Stop", 4), now: date(4))
        store.apply(event(a, "PreToolUse", 3), now: date(5))
        store.apply(event(a, "Stop", 4), now: date(6))
        XCTAssertEqual(store.session(id: a)?.state, .done)
        XCTAssertEqual(store.session(id: a)?.notificationVersion, 1)
        store.apply(event(a, "UserPromptSubmit", 7), now: date(7))
        store.apply(event(a, "Stop", 8), now: date(8))
        XCTAssertEqual(store.session(id: a)?.notificationVersion, 2)
        XCTAssertEqual(store.session(id: a)?.turnStartedAt, date(7))
    }

    func testSameDirectoryKeepsIndependentSessions() {
        let store = SessionStore()
        store.apply(event(a, "Stop", 1), now: date(1))
        store.apply(event(b, "Stop", 2), now: date(2))
        store.markRead(id: a, through: 1)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.session(id: b)?.hasUnread, true)
    }

    func testNativeAcknowledgementRequiresKnownSchema() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(CodexMetadata.nativeUnread(sessionID: a, home: dir.path))
        let file = dir.appendingPathComponent(".codex-global-state.json")
        let data = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": ["synthetic": ["local": [a]]]]])
        try data.write(to: file)
        XCTAssertEqual(CodexMetadata.nativeUnread(sessionID: a, home: dir.path), true)
        XCTAssertEqual(CodexMetadata.nativeUnread(sessionID: b, home: dir.path), false)
    }

    func testNativeCompletionRepairsMissingStopAndRejectsLateActivity() throws {
        let store = SessionStore()
        store.apply(event(a, "UserPromptSubmit", 1), now: date(1))
        store.reconcileCodexLifecycle(id: a, event: try native("task_started", turn: "first", at: 1))
        store.reconcileCodexLifecycle(id: a, event: try native("task_complete", turn: "first", at: 4))
        store.apply(event(a, "PreToolUse", 5), now: date(5))
        store.apply(event(a, "Stop", 6), now: date(6))
        XCTAssertEqual(store.session(id: a)?.state, .done)
        XCTAssertEqual(store.session(id: a)?.codexTurnResult, .completed)
        XCTAssertEqual(store.session(id: a)?.notificationVersion, 1)
        XCTAssertEqual(store.session(id: a)?.turnEndedAt, date(4))
    }

    func testNativeAbortAndFailureKeepDistinctResults() throws {
        let store = SessionStore()
        store.apply(event(a, "UserPromptSubmit", 1), now: date(1))
        store.reconcileCodexLifecycle(id: a, event: try native("turn_aborted", turn: "first", at: 4))
        XCTAssertEqual(store.session(id: a)?.codexTurnResult, .cancelled)
        store.apply(event(a, "UserPromptSubmit", 5), now: date(5))
        store.reconcileCodexLifecycle(id: a, event: try native("task_complete", turn: "first", at: 4))
        XCTAssertEqual(store.session(id: a)?.state, .working)
        store.reconcileCodexLifecycle(id: a, event: try native("task_started", turn: "second", at: 5))
        store.apply(event(a, "Stop", 7), now: date(7))
        store.reconcileCodexLifecycle(id: a, event: try native("task_complete", turn: "second", at: 8, error: "usage_limit_exceeded"))
        XCTAssertEqual(store.session(id: a)?.codexTurnResult, .failed)
        XCTAssertEqual(store.session(id: a)?.notificationVersion, 2)
    }

    func testNativeAttachmentPreservesPendingPermissionAndResumeKeepsClock() throws {
        let store = SessionStore()
        store.apply(event(a, "UserPromptSubmit", 2), now: date(2))
        store.apply(event(a, "PermissionRequest", 3), now: date(3))
        store.reconcileCodexLifecycle(id: a, event: try native("task_started", turn: "first", at: 1))
        store.apply(event(a, "SessionStart", 4), now: date(4))
        XCTAssertEqual(store.session(id: a)?.state, .waiting)
        XCTAssertEqual(store.session(id: a)?.hasUnread, true)
        XCTAssertEqual(store.session(id: a)?.turnStartedAt, date(1))
    }

    private func native(_ type: String, turn: String, at: Double, error: String? = nil) throws -> CodexLifecycle {
        var payload: [String: Any] = ["type": type, "turn_id": turn]
        if let error { payload["error"] = ["codex_error_info": error] }
        let data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: date(at)), "payload": payload])
        return try XCTUnwrap(CodexLifecycle.parse(data))
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func event(_ id: String, _ name: String, _ seconds: Double) -> AgentEvent {
        AgentEvent(sessionId: id, agentKind: .codex, eventName: name, project: "/synthetic/shared", timestamp: date(seconds))
    }
}
