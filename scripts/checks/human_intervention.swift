import Foundation

final class InputProbe: @unchecked Sendable {
    let lock = NSLock(), signal = DispatchSemaphore(value: 0)
    private var changes: [HumanIntervention] = []
    func add(_ change: HumanIntervention) { lock.lock(); changes.append(change); lock.unlock(); signal.signal() }
    var values: [HumanIntervention] { lock.lock(); defer { lock.unlock() }; return changes }
}

@main struct Checks {
    static var count = 0
    static func check(_ condition: Bool, _ name: String) {
        count += 1
        if !condition { fatalError("FAIL: " + name) }
    }
    static func time(_ n: Double) -> Date { Date(timeIntervalSince1970: n) }
    static func event(_ kind: AgentKind, _ name: String, _ n: Double, id: String = "a", requests: [String] = [], action: HumanIntervention.Action = .asked) -> AgentEvent {
        var e = AgentEvent(sessionId: id, agentKind: kind, eventName: name, project: "/synthetic", timestamp: time(n))
        if kind == .opencode { e.opencodeTurnID = "shared-turn"; e.opencodeNewTurn = name == "working" && n == 1 }
        if !requests.isEmpty { e.humanIntervention = HumanIntervention(action: action, requests: requests.map { HumanRequest(id: $0, kind: .choice, createdAt: time(n)) }) }
        return e
    }
    static func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func record(_ payload: [String: Any], at: Double) throws -> Data {
        try data(["type": "response_item", "timestamp": ISO8601DateFormatter().string(from: time(at)), "payload": payload])
    }
    static func ask(_ id: String, at: Double = 2, async: Bool = true) throws -> Data {
        try record(["type": "function_call", "name": async ? "functions.request_user_input_async" : "functions.request_user_input", "call_id": id,
            "arguments": "{\"questions\":[{\"question\":\"SECRET QUESTION\",\"options\":[\"SECRET OPTION\"]},{\"question\":\"SECRET SECOND\"}]}"], at: at)
    }
    static func main() throws {
        if CommandLine.arguments.count == 3 {
            try PiPlugin.source(binary: CommandLine.arguments[2]).write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8); return
        }
        if CommandLine.arguments.count == 2 {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1])); defer { try? file.close() }
            var tracker = CodexHumanInputTracker(), partial = Data(), asked = 0, resolved = 0
            while let block = try file.read(upToCount: 524288), !block.isEmpty {
                partial.append(block)
                while let end = partial.firstIndex(of: 10) {
                    let line = Data(partial[..<end]); partial.removeSubrange(...end)
                    if let change = tracker.ingest(line)?.0 { if change.action == .asked { asked += change.requests.count } else { resolved += change.requests.count } }
                }
            }
            check(asked > 0 && resolved > 0, "actual local Codex rollout contains recognized requests/replies")
            print("PASS: actual Codex rollout replay: asked=\(asked), resolved=\(resolved), outstanding=\(tracker.pending.count); no question/answer bodies exported")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // DSH accepts full native snapshots, not generic hook deltas. Its
        // pending/lifecycle matrix is covered by DSHIntegrationTests.
        check(SessionStore().apply(event(.dsh, "working", 1), now: time(1)) == nil, "DSH rejects a generic hook without native identity")
        for agent in AgentCatalog.all where agent.kind != .dsh {
            let store = SessionStore(); store.persistenceURL = root.appendingPathComponent(agent.id + ".json")
            store.apply(event(agent.kind, "working", 1), now: time(1))
            store.apply(event(agent.kind, "waiting", 2, requests: ["q1"]), now: time(2))
            let first = store.session(id: "a")!
            check(first.indicator == .attention && first.message == "等待你的选择", agent.id + ": orange waiting")
            check(store.markOpened(first, at: time(2.5)) && store.session(id: "a")!.indicator == .read, agent.id + ": exact read green")
            store.apply(event(agent.kind, "working", 3), now: time(3))
            check(store.session(id: "a")!.state == .waiting && store.session(id: "a")!.indicator == .read, agent.id + ": unrelated activity preserves read waiting")
            store.apply(event(agent.kind, "waiting", 4, requests: ["q2"]), now: time(4))
            store.markOpened(first, at: time(4.1))
            check(store.session(id: "a")!.indicator == .attention, agent.id + ": old click cannot read new request")
            let pending = store.session(id: "a")!
            store.apply(event(agent.kind, "waiting", 5, requests: ["q2"]), now: time(5))
            check(store.session(id: "a") == pending, agent.id + ": duplicate does not notify")
            store.apply(event(agent.kind, "working", 6, requests: ["q1"], action: .resolved), now: time(6))
            check(store.session(id: "a")!.humanRequests?.map(\.id) == ["q2"] && store.session(id: "a")!.state == .waiting, agent.id + ": partial answer retains second request")
            store.prune(now: time(4000))
            check(store.session(id: "a") != nil, agent.id + ": waiting cannot expire")
            let restored = SessionStore(); restored.persistenceURL = store.persistenceURL; restored.restoreCodexSessions()
            check(restored.session(id: "a") == store.session(id: "a"), agent.id + ": restart restores request and receipt")
            store.apply(event(agent.kind, "working", 7, requests: ["q2"], action: .resolved), now: time(7))
            check(store.session(id: "a")!.indicator == .running && store.session(id: "a")!.humanRequests == [], agent.id + ": final answer resumes blue")
            store.apply(event(agent.kind, "waiting", 4, requests: ["q2"]), now: time(4))
            check(store.session(id: "a")!.indicator == .running, agent.id + ": late asked cannot reopen resolved request")
            check(!agent.humanInputNote.isEmpty, agent.id + ": explicit coverage note")
        }
        let store = SessionStore()
        store.apply(event(.codex, "UserPromptSubmit", 1), now: time(1))
        store.apply(event(.codex, "waiting", 2, requests: ["async"]), now: time(2))
        let completion = CodexLifecycle(turnID: "t1", timestamp: time(3), startedAt: time(1), result: .completed)
        store.reconcileCodexLifecycle(id: "a", event: completion)
        check(store.session(id: "a")!.state == .waiting && store.session(id: "a")!.turnEndedAt == time(3), "async unanswered survives execution completion")
        store.apply(event(.codex, "working", 4, requests: ["async"], action: .resolved), now: time(4))
        check(store.session(id: "a")!.state == .done && store.session(id: "a")!.indicator == .unread, "answer after execution ends produces true completed unread")
        store.apply(event(.codex, "UserPromptSubmit", 5), now: time(5))
        store.apply(event(.codex, "waiting", 6, requests: ["cancel"]), now: time(6))
        store.reconcileCodexLifecycle(id: "a", event: CodexLifecycle(turnID: "t2", timestamp: time(7), startedAt: time(5), result: .cancelled))
        check(store.session(id: "a")!.state == .done && store.session(id: "a")!.humanRequests == [] && store.session(id: "a")!.taskResult == .cancelled, "abort clears pending without claiming answered/success")
        store.apply(event(.codex, "working", 8, requests: ["cancel"], action: .resolved), now: time(8))
        check(store.session(id: "a")!.taskResult == .cancelled && store.session(id: "a")!.state == .done, "late answer cannot resume cancelled task")
        let superseded = SessionStore(); superseded.persistenceURL = root.appendingPathComponent("superseded.json")
        superseded.apply(event(.codex, "UserPromptSubmit", 1), now: time(1))
        superseded.reconcileCodexLifecycle(id: "a", event: CodexLifecycle(turnID: "old", timestamp: time(1), startedAt: time(1), result: nil))
        superseded.apply(event(.codex, "waiting", 2, requests: ["old-question"]), now: time(2))
        let oldCard = superseded.session(id: "a")!
        superseded.markOpened(oldCard, at: time(2.5))
        superseded.reconcileCodexLifecycle(id: "a", event: CodexLifecycle(turnID: "old", timestamp: time(3), startedAt: time(1), result: .completed))
        check(superseded.session(id: "a")!.state == .waiting, "same-turn async input survives normal completion")
        superseded.reconcileCodexLifecycle(id: "a", event: CodexLifecycle(turnID: "new", timestamp: time(4), startedAt: time(4), result: nil))
        check(superseded.session(id: "a")!.humanRequests == [] && superseded.session(id: "a")!.indicator == .running, "new native turn replaces old waiting with running blue")
        superseded.markOpened(oldCard, at: time(4.1))
        check(!superseded.session(id: "a")!.hasReadReceipt, "previous waiting click cannot read fresh work")
        superseded.apply(event(.codex, "waiting", 2, requests: ["old-question"]), now: time(4.2))
        check(superseded.session(id: "a")!.indicator == .running, "late old question cannot reopen new turn")
        superseded.apply(event(.codex, "waiting", 5, requests: ["new-question"]), now: time(5))
        check(superseded.session(id: "a")!.indicator == .attention, "new-turn question still becomes orange")
        superseded.reconcileCodexLifecycle(id: "a", event: CodexLifecycle(turnID: "new", timestamp: time(5.5), startedAt: time(4), result: nil))
        check(superseded.session(id: "a")!.humanRequests?.map(\.id) == ["new-question"], "duplicate same-turn start does not retire current question")
        superseded.apply(event(.codex, "UserPromptSubmit", 6), now: time(6))
        check(superseded.session(id: "a")!.humanRequests == [] && superseded.session(id: "a")!.indicator == .running, "prompt hook starts blue before lifecycle watch catches up")
        var legacy = AgentSession(id: "legacy", agentKind: .codex, state: .waiting, message: "等待你的选择", source: .hook, updatedAt: time(10))
        legacy.turnStartedAt = time(10)
        legacy.humanRequests = [HumanRequest(id: "legacy-old", kind: .choice, createdAt: time(2))]
        legacy.notificationVersion = 1; legacy.readThroughVersion = 1
        let legacyData = try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))]])
        let legacyURL = root.appendingPathComponent("legacy.json"); try legacyData.write(to: legacyURL)
        let migrated = SessionStore(); migrated.persistenceURL = legacyURL; migrated.restoreCodexSessions()
        check(migrated.session(id: "legacy")!.humanRequests == [] && migrated.session(id: "legacy")!.indicator == .running, "restore repairs pre-fix stale waiting snapshot")
        let migratedAgain = SessionStore(); migratedAgain.persistenceURL = legacyURL; migratedAgain.restoreCodexSessions()
        check(migratedAgain.session(id: "legacy") == migrated.session(id: "legacy"), "snapshot migration is persisted and idempotent")
        let newInput = HumanRequest(id: "current", kind: .choice, createdAt: time(11))
        legacy.humanRequests = [newInput]
        try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))]]).write(to: legacyURL)
        let actualPending = SessionStore(); actualPending.persistenceURL = legacyURL; actualPending.restoreCodexSessions()
        check(actualPending.session(id: "legacy")!.humanRequests == [newInput] && actualPending.session(id: "legacy")!.state == .waiting, "migration preserves genuinely current unanswered input")
        var tracker = CodexHumanInputTracker()
        let asked = tracker.ingest(try ask("call_a"))!
        check(asked.0.requests.count == 2 && asked.0.requests.map(\.kind) == [.choice, .reply], "native multiple questions preserve precise IDs and kinds")
        let accepted = try record(["type": "function_call_output", "call_id": "call_a", "output": "{\"accepted\":true}"], at: 3)
        check(tracker.ingest(accepted) == nil && tracker.pending.count == 2, "async accepted is not an answer")
        check(tracker.ingest(try record(["type": "message", "role": "user", "content": [["text": "Here is ordinary prose, no interaction metadata"]]], at: 4)) == nil, "ordinary user prose cannot release UI prompts")
        let replyKey = String(data: try JSONSerialization.data(withJSONObject: ["request_user_input_async", "call_a", 0]), encoding: .utf8)!
        let rows = String(data: try JSONSerialization.data(withJSONObject: [["questionItemId": replyKey, "question": "SECRET", "answer": "SECRET ANSWER"]]), encoding: .utf8)!
        let reply = try record(["type": "message", "role": "user", "content": [["type": "input_text", "text": "<send_user_message_question_reply>" + rows + "</send_user_message_question_reply>"]]], at: 5)
        check(tracker.ingest(reply)?.0.requests.map(\.id) == ["call_a#0"] && tracker.pending.map(\.id) == ["call_a#1"], "actual async reply only releases its question")
        check(tracker.ingest(reply) == nil, "duplicate reply is harmless")
        let errored = try record(["type": "function_call_output", "call_id": "call_a", "output": "{\"accepted\":false}"], at: 6)
        check(tracker.ingest(errored) != nil && tracker.pending.isEmpty, "failed dialog creation releases remainder")
        check(tracker.ingest(try ask("call_a")) == nil, "duplicate old call cannot resurrect dialog")
        _ = tracker.ingest(try ask("sync", at: 7, async: false))
        check(tracker.ingest(try record(["type": "function_call_output", "call_id": "sync", "output": "{\"answers\":{\"q\":\"SECRET\"}}"], at: 8)) != nil && tracker.pending.isEmpty, "synchronous tool completion resolves its input")
        check(!String(data: try JSONEncoder().encode(asked.0), encoding: .utf8)!.contains("SECRET"), "native prompts and options never enter stored metadata")
        var outOfOrder = CodexHumanInputTracker(); _ = outOfOrder.ingest(try ask("new", at: 20, async: false))
        let oldAnswer = try record(["type": "function_call_output", "call_id": "new", "output": "{}"], at: 19)
        check(outOfOrder.ingest(oldAnswer) == nil && outOfOrder.pending.count == 2, "old native answer cannot remove a later prompt")
        var turnTracker = CodexHumanInputTracker()
        func turn(_ id: String, _ at: Double, result: String = "task_started") throws -> Data {
            try data(["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: time(at)), "payload": ["type": result, "turn_id": id]])
        }
        _ = turnTracker.ingest(try turn("old", 1)); _ = turnTracker.ingest(try ask("async-old", at: 2))
        check(turnTracker.ingest(try turn("old", 3, result: "task_complete")) == nil && turnTracker.pending.count == 2, "tracker retains same-turn async question after completion")
        check(turnTracker.ingest(try turn("new", 4))?.0.requests.count == 2 && turnTracker.pending.isEmpty, "tracker retires older UI on genuine new turn")
        check(turnTracker.ingest(try ask("async-old", at: 2)) == nil, "tracker rejects old native call replay")
        _ = turnTracker.ingest(try ask("async-new", at: 5))
        check(turnTracker.ingest(try turn("new", 6)) == nil && turnTracker.pending.count == 2, "tracker same-turn duplicate preserves current pending")
        check(turnTracker.ingest(try turn("older", 0)) == nil && turnTracker.pending.count == 2, "tracker late native start cannot clear later pending")
        _ = turnTracker.ingest(try turn("old", 7, result: "turn_aborted"))
        check(turnTracker.pending.count == 2, "old-turn abort cannot erase current input tracker")
        let watched = root.appendingPathComponent("input.jsonl")
        var initial = try ask("watch"); initial.append(10)
        initial.append(try record(["type": "function_call_output", "call_id": "watch", "output": "{\"accepted\":true}"], at: 3)); initial.append(10)
        try initial.write(to: watched)
        let probe = InputProbe()
        let watcher = CodexLifecycleWatcher(inputHandler: { _, change, _ in probe.add(change) }, handler: { _, _ in })
        watcher.watch(sessionID: "watch", path: watched.path)
        check(probe.signal.wait(timeout: .now() + 3) == .success && probe.values.first?.requests.count == 2, "file attachment recovers genuinely outstanding native input")
        let handle = try FileHandle(forWritingTo: watched); defer { try? handle.close() }; try handle.seekToEnd()
        let end = try record(["type": "function_call_output", "call_id": "watch", "output": "{\"accepted\":false}"], at: 4)
        try handle.write(contentsOf: end.prefix(end.count/2))
        check(probe.signal.wait(timeout: .now() + 0.15) == .timedOut, "partial native input record does not resolve prompt")
        var suffix = Data(end.suffix(end.count-end.count/2)); suffix.append(10); try handle.write(contentsOf: suffix)
        check(probe.signal.wait(timeout: .now() + 3) == .success && probe.values.last?.action == .resolved, "incremental native watcher resolves complete reply only")
        watcher.retain(sessionIDs: [])
        let recovered = InputProbe()
        let restart = CodexLifecycleWatcher(inputHandler: { _, change, _ in recovered.add(change) }, handler: { _, _ in })
        restart.watch(sessionID: "watch", path: watched.path)
        check(recovered.signal.wait(timeout: .now() + 3) == .success && recovered.signal.wait(timeout: .now() + 3) == .success && recovered.values.allSatisfy { $0.action == .resolved }, "watch restart replays closures without resurrecting historical prompts")
        restart.retain(sessionIDs: [])
        let claudeAsk: [String: Any] = ["session_id": "c", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_use_id": "tool1", "tool_input": ["questions": ["SECRET"]]]
        let c = SessionStore()
        let ca = HookPayload.event(forAgent: .claude, stdin: try data(claudeAsk), now: time(1))!
        check(ca.humanIntervention?.requests.map(\.id) == ["tool:tool1"], "Claude exact tool request identity")
        c.apply(ca, now: time(1))
        var post = claudeAsk; post["hook_event_name"] = "PostToolUse"; post["tool_name"] = "Read"; post["tool_use_id"] = "other"
        c.apply(HookPayload.event(forAgent: .claude, stdin: try data(post), now: time(2))!, now: time(2))
        check(c.session(id: "c")!.state == .waiting, "unrelated Claude tool cannot hide question")
        post["tool_name"] = "AskUserQuestion"; post["tool_use_id"] = "tool1"
        c.apply(HookPayload.event(forAgent: .claude, stdin: try data(post), now: time(3))!, now: time(3))
        check(c.session(id: "c")!.state == .working, "matching Claude answer resumes")
        var notification: [String: Any] = ["session_id": "c", "hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "SECRET"]
        check(HookPayload.event(forAgent: .claude, stdin: try data(notification), now: time(4)) == nil, "idle notification is not human intervention")
        var gemini = notification; gemini["notification_type"] = "ToolPermission"
        check(HookPayload.event(forAgent: .gemini, stdin: try data(gemini), now: time(4)) == nil, "retired native notifications are ignored")
        notification["notification_type"] = "permission_prompt"
        let permission = HookPayload.event(forAgent: .claude, stdin: try data(notification), now: time(4))!
        check(permission.message == "等待批准", "permission display discards sensitive notification body")
        let firstAttention = SessionStore()
        var missingBegin = event(.opencode, "waiting", 2, requests: ["first"])
        missingBegin.opencodeProcessID = 12345; missingBegin.opencodeNavigationSocket = "/synthetic/native.sock"
        firstAttention.apply(missingBegin, now: time(2))
        check(firstAttention.session(id: "a")!.opencodeTurnID == "shared-turn" && firstAttention.session(id: "a")!.opencodeProcessID == 12345 && firstAttention.session(id: "a")!.opencodeNavigationSocket == "/synthetic/native.sock", "first attention frame binds native turn/owner/navigation if routine begin was dropped")
        firstAttention.apply(event(.opencode, "working", 3, requests: ["first"], action: .resolved), now: time(3))
        check(firstAttention.session(id: "a")!.state == .working, "answer can resolve first-frame attention")
        check(StateMapper.state(for: .jcode, eventName: "turn_end") == nil, "retired events cannot invent native waiting")
        let pi = SessionStore(); pi.apply(event(.pi, "waiting", 1, requests: ["ui"]), now: time(1)); pi.apply(event(.pi, "session_shutdown", 2), now: time(2))
        check(pi.sessions.isEmpty, "native Pi session shutdown clears pending UI")
        let ranked = SessionStore(); ranked.apply(event(.claude, "working", 10, id: "run"), now: time(10)); ranked.apply(event(.claude, "waiting", 1, id: "wait", requests: ["q"]), now: time(1))
        check(ranked.sorted.first?.id == "wait", "human intervention sorts ahead of background work")
        print("PASS: \(count) human intervention checks (all catalog sources, request races, native Codex, Claude, persistence/privacy)")
    }
}
