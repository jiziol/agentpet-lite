import Foundation
import CSQLite

final class LifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(String, CodexLifecycle)] = []
    let signal = DispatchSemaphore(value: 0)
    func add(_ id: String, _ event: CodexLifecycle) {
        lock.lock(); records.append((id, event)); lock.unlock(); signal.signal()
    }
    var values: [(String, CodexLifecycle)] {
        lock.lock(); defer { lock.unlock() }; return records
    }
}

@main
struct CodexChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { fatalError("FAIL: " + name) }
            checks += 1
            print("PASS: " + name)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentpet-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = "11111111-1111-4111-8111-111111111111"
        let b = "22222222-2222-4222-8222-222222222222"
        func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        func event(_ id: String, _ name: String, _ seconds: Double) -> AgentEvent {
            AgentEvent(sessionId: id, agentKind: .codex, eventName: name, project: "/synthetic/shared", timestamp: date(seconds))
        }
        check(CodexMetadata.threadURL(sessionID: a)?.absoluteString == "codex://threads/" + a, "exact thread deep link")
        for id in ["new", "../settings", a + "?prompt=run", a + "/"] {
            check(CodexMetadata.threadURL(sessionID: id) == nil, "reject malformed navigation ID")
        }
        var db: OpaquePointer?
        check(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "create synthetic metadata database")
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,name TEXT,model TEXT,rollout_path TEXT,originator TEXT); INSERT INTO threads VALUES('\(a)','Original','Renamed','model-a','/synthetic/a.jsonl','Codex Desktop'); INSERT INTO threads VALUES('\(b)','Other',NULL,'model-b','/synthetic/b.jsonl','cli');", nil, nil, nil) == SQLITE_OK, "seed synthetic metadata")
        let record = CodexMetadata.read(sessionID: a, home: root.path)
        check(record?.title == "Renamed" && record?.isDesktop == true && record?.model == "model-a", "read renamed title and desktop provenance")
        check(CodexMetadata.read(sessionID: b, home: root.path)?.isDesktop == false, "CLI is not treated as desktop")
        sqlite3_exec(db, "UPDATE threads SET name='New title' WHERE id='\(a)'", nil, nil, nil)
        check(CodexMetadata.read(sessionID: a, home: root.path)?.title == "New title", "refresh renamed title")
        check(CodexMetadata.read(sessionID: "33333333-3333-4333-8333-333333333333", home: root.path) == nil, "no fallback to another session")
        let input: [String: Any] = ["session_id": a, "hook_event_name": "PreToolUse", "tool_name": "functions.exec_command", "tool_input": ["cmd": "curl -H 'Authorization: SECRET' https://example.invalid"], "model": "example-model"]
        let parsed = HookPayload.event(forAgent: .codex, stdin: try JSONSerialization.data(withJSONObject: input), now: date(1))
        check(parsed?.message == "正在执行命令" && parsed?.model == "example-model", "Codex command activity without raw arguments")
        check(CodexHookPayload.activity(event: "PreToolUse", tool: "functions.read_file", input: ["path": "/private/project/Test.swift"]) == "正在读取 Test.swift", "display only filename")
        check(CodexHookPayload.activity(event: "PreToolUse", tool: "Bash", input: ["command": "rg secret-pattern /private/project"]) == "正在搜索代码", "native Bash alias with private arguments omitted")
        check(CodexHookPayload.activity(event: "PreToolUse", tool: "Read", input: ["file_path": "/private/project/README.md"]) == "正在读取 README.md", "native Read alias")
        check(CodexHookPayload.activity(event: "PreToolUse", tool: "mcp__cua_repl__js", input: [:]) == "正在检查界面", "native UI tool label")
        let store = SessionStore()
        store.persistenceURL = root.appendingPathComponent("sessions.json")
        store.apply(event(a, "UserPromptSubmit", 1), now: date(100))
        store.apply(event(a, "PreToolUse", 2), now: date(101))
        check(store.session(id: a)?.updatedAt == date(2), "queued events use event timestamps")
        check(store.apply(event(a, "SubagentStop", 3), now: date(3)) == nil && store.session(id: a)?.state == .working, "child stop preserves parent work")
        store.apply(event(a, "PermissionRequest", 4), now: date(4))
        let oldVersion = store.session(id: a)!.notificationVersion
        store.apply(event(a, "PreToolUse", 5), now: date(5))
        store.apply(event(a, "Stop", 6), now: date(6))
        store.markRead(id: a, through: oldVersion)
        store.prune(now: date(10000))
        check(store.session(id: a)?.hasUnread == true && store.session(id: a)?.state == .done, "old click cannot clear newer completion; unread survives TTL")
        check(store.session(id: a)?.turnStartedAt == date(1) && store.session(id: a)?.turnEndedAt == date(6), "task elapsed includes waiting and freezes on completion")
        store.apply(event(a, "PreToolUse", 5), now: date(7))
        store.apply(event(a, "Stop", 6), now: date(8))
        check(store.session(id: a)?.state == .done && store.session(id: a)?.notificationVersion == 2, "late and duplicate events do not regress completion")
        store.apply(event(b, "Stop", 8), now: date(8))
        store.markRead(id: b, through: 1)
        check(store.sessions.count == 2 && store.session(id: a)?.hasUnread == true, "same directory sessions remain independent")
        let restored = SessionStore()
        restored.persistenceURL = store.persistenceURL
        restored.restoreCodexSessions()
        check(restored.session(id: a) == store.session(id: a), "unread survives process restart")
        restored.markRead(id: a, through: 999)
        check(restored.session(id: a)?.hasUnread == false, "explicit read acknowledgement")
        restored.apply(event(a, "UserPromptSubmit", 9), now: date(9))
        restored.apply(event(a, "Stop", 10), now: date(10))
        check(restored.session(id: a)?.hasUnread == true && restored.session(id: a)?.turnStartedAt == date(9), "new turn becomes unread again")
        let unknown = root.appendingPathComponent("future.json")
        let future = Data("{\"version\":99,\"sessions\":[]}".utf8)
        try future.write(to: unknown)
        let futureStore = SessionStore(); futureStore.persistenceURL = unknown; futureStore.restoreCodexSessions()
        futureStore.apply(event(a, "Stop", 1), now: date(1))
        check((try? Data(contentsOf: unknown)) == future && futureStore.persistenceError != nil, "unknown schema preserved without overwrite")
        check(CodexMetadata.nativeUnread(sessionID: a, home: root.path) == nil, "missing acknowledgement schema is not success")
        let unread = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": ["synthetic": ["local": [a]]]]])
        try unread.write(to: root.appendingPathComponent(".codex-global-state.json"))
        check(CodexMetadata.nativeUnread(sessionID: a, home: root.path) == true && CodexMetadata.nativeUnread(sessionID: b, home: root.path) == false, "native unread metadata lookup")
        func native(_ type: String, _ turn: String, _ at: Double, start: Double? = nil, error: String? = nil) throws -> Data {
            var payload: [String: Any] = ["type": type, "turn_id": turn]
            if let start { payload["started_at"] = start * 1000 }
            if let error { payload["error"] = ["codex_error_info": error, "message": "private body must not be retained"] }
            return try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: date(at)), "payload": payload])
        }
        func lifecycle(_ type: String, _ turn: String, _ at: Double, start: Double? = nil, error: String? = nil) throws -> CodexLifecycle {
            guard let value = CodexLifecycle.parse(try native(type, turn, at, start: start, error: error)) else { fatalError("Invalid lifecycle fixture") }
            return value
        }
        let nativeStore = SessionStore()
        nativeStore.apply(event(a, "UserPromptSubmit", 1_700_000_001), now: date(1_700_000_001))
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("task_started", "turn-a", 1_700_000_000, start: 1_700_000_000))
        nativeStore.apply(event(a, "SessionStart", 1_700_000_004), now: date(1_700_000_004))
        check(nativeStore.session(id: a)?.state == .working && nativeStore.session(id: a)?.turnStartedAt == date(1_700_000_000), "desktop resume does not reset task state or duration")
        nativeStore.apply(event(a, "PreToolUse", 1_700_000_005), now: date(1_700_000_005))
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("task_complete", "turn-a", 1_700_000_010, start: 1_700_000_000))
        check(nativeStore.session(id: a)?.state == .done && nativeStore.session(id: a)?.codexTurnResult == .completed, "missing Stop hook ends on native completion")
        check(nativeStore.session(id: a)?.turnStartedAt == date(1_700_000_000) && nativeStore.session(id: a)?.turnEndedAt == date(1_700_000_010), "native millisecond duration anchors task clock")
        nativeStore.apply(event(a, "PreToolUse", 1_700_000_011), now: date(1_700_000_011))
        nativeStore.apply(event(a, "Stop", 1_700_000_012), now: date(1_700_000_012))
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("task_complete", "turn-a", 1_700_000_010))
        check(nativeStore.session(id: a)?.state == .done && nativeStore.session(id: a)?.notificationVersion == 1, "late working and duplicate native/Stop do not reopen or notify twice")
        nativeStore.apply(event(a, "UserPromptSubmit", 1_700_000_021), now: date(1_700_000_021))
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("task_complete", "old-turn", 1_700_000_019))
        check(nativeStore.session(id: a)?.state == .working, "old tail completion cannot stop newer prompt")
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("task_started", "turn-b", 1_700_000_020))
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("turn_aborted", "turn-b", 1_700_000_025, start: 1_700_000_020))
        check(nativeStore.session(id: a)?.codexTurnResult == .cancelled && nativeStore.session(id: a)?.message == "任务已停止", "user abort is stopped rather than completed")
        check(nativeStore.session(id: a)?.notificationVersion == 2, "new turn receives a distinct unread version")
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("task_started", "turn-c", 1_700_000_030))
        check(nativeStore.session(id: a)?.state == .working && nativeStore.session(id: a)?.hasUnread == false, "native new turn works even if prompt hook is absent")
        nativeStore.apply(event(a, "Stop", 1_700_000_039), now: date(1_700_000_039))
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("task_complete", "turn-c", 1_700_000_040, start: 1_700_000_030, error: "usage_limit_exceeded"))
        check(nativeStore.session(id: a)?.codexTurnResult == .failed && nativeStore.session(id: a)?.notificationVersion == 3, "native failure corrects earlier Stop without duplicate unread")
        check(nativeStore.session(id: a)?.message?.contains("private") == false, "native error bodies are discarded")
        check(CodexLifecycle.parse(Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"task_complete\"}}".utf8)) == nil, "non-lifecycle records ignored")
        let hookFirst = SessionStore()
        hookFirst.apply(event(a, "UserPromptSubmit", 1), now: date(1))
        hookFirst.apply(event(a, "Stop", 4), now: date(4))
        hookFirst.apply(event(a, "PreToolUse", 5), now: date(5))
        check(hookFirst.session(id: a)?.state == .done && hookFirst.session(id: a)?.turnEndedAt == date(4), "late activity after hook-only Stop remains terminal")
        let nativePersist = root.appendingPathComponent("native-state.json")
        nativeStore.persistenceURL = nativePersist; nativeStore.persistCodexSessions()
        let nativeRestored = SessionStore(); nativeRestored.persistenceURL = nativePersist; nativeRestored.restoreCodexSessions()
        check(nativeRestored.session(id: a)?.codexTurnResult == .failed && nativeRestored.session(id: a)?.codexTurnID == "turn-c", "terminal turn identity survives restart")

        let waiting = SessionStore()
        waiting.apply(event(a, "UserPromptSubmit", 1_700_000_001), now: date(1_700_000_001))
        waiting.apply(event(a, "PermissionRequest", 1_700_000_005), now: date(1_700_000_005))
        waiting.reconcileCodexLifecycle(id: a, event: try lifecycle("task_started", "waiting-turn", 1_700_000_000))
        check(waiting.session(id: a)?.state == .waiting && waiting.session(id: a)?.hasUnread == true, "initial native attachment preserves newer approval and unread")
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("task_started", "turn-d", 1_700_000_050))
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("turn_aborted", "turn-d", 1_700_000_055))
        nativeStore.reconcileCodexLifecycle(id: a, event: try lifecycle("task_complete", "turn-d", 1_700_000_056, error: "other"))
        check(nativeStore.session(id: a)?.codexTurnResult == .cancelled, "explicit abort remains stopped across follow-up terminal record")
        let watched = root.appendingPathComponent("watched.jsonl")
        var initial = try native("task_started", "watch-a", 1_700_000_000)
        initial.append(0x0A); initial.append(try native("task_complete", "watch-a", 1_700_000_010)); initial.append(0x0A)
        initial.append(Data(repeating: 0x78, count: 2_100_000)); initial.append(0x0A)
        try initial.write(to: watched)
        let probe = LifecycleProbe()
        let watcher = CodexLifecycleWatcher { id, event in probe.add(id, event) }
        watcher.watch(sessionID: a, path: watched.path)
        check(probe.signal.wait(timeout: .now() + 3) == .success, "file watcher restores native terminal without a Hook")
        check(probe.values.count == 1 && probe.values.first?.1.result == .completed, "attachment finds newest lifecycle behind large tool output")
        let handle = try FileHandle(forWritingTo: watched); defer { try? handle.close() }; try handle.seekToEnd()
        let partial = try native("task_started", "watch-b", 1_700_000_020)
        try handle.write(contentsOf: partial.prefix(partial.count / 2))
        check(probe.signal.wait(timeout: .now() + 0.15) == .timedOut, "partial JSON line does not invent a state")
        var remainder = Data(partial.suffix(partial.count - partial.count / 2)); remainder.append(0x0A)
        try handle.write(contentsOf: remainder)
        check(probe.signal.wait(timeout: .now() + 3) == .success && probe.values.last?.1.turnID == "watch-b", "incremental file event completes split line")
        var oversized = Data(repeating: 0x78, count: 1_100_000); oversized.append(0x0A)
        oversized.append(try native("turn_aborted", "watch-b", 1_700_000_025)); oversized.append(0x0A)
        try handle.write(contentsOf: oversized)
        check(probe.signal.wait(timeout: .now() + 3) == .success && probe.values.last?.1.result == .cancelled, "oversized unrelated record cannot hide subsequent terminal event")
        let second = root.appendingPathComponent("second.jsonl")
        var other = try native("task_complete", "watch-other", 1_700_000_040); other.append(0x0A); try other.write(to: second)
        watcher.watch(sessionID: b, path: second.path)
        check(probe.signal.wait(timeout: .now() + 3) == .success && probe.values.last?.0 == b, "native watches retain exact session identities")
        watcher.retain(sessionIDs: [])
        print("\(checks) portable Codex checks passed (not the XCTest suite).")
    }
}
