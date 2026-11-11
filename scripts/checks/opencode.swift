import Foundation

@main struct OpencodeChecks {
    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--tui-plugin" {
            try OpencodeTUIPlugin.source(speechSocketPath: CommandLine.arguments[3]).write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
            return
        }
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--v2-plugin" {
            try OpencodePlugin.source(binary: CommandLine.arguments[3], speechSocketPath: CommandLine.arguments[4], generation: .v2).write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--select" {
            var session = AgentSession(id: CommandLine.arguments[2], agentKind: .opencode, state: .done, source: .hook, updatedAt: Date())
            session.opencodeNavigationSocket = CommandLine.arguments[3]
            print(OpencodeNavigation.select(session: session))
            return
        }
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--speech-plugin" {
            try OpencodePlugin.source(binary: CommandLine.arguments[3], speechSocketPath: CommandLine.arguments[4]).write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
            return
        }
        if CommandLine.arguments.count == 3 {
            try OpencodePlugin.source(binary: CommandLine.arguments[2]).write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
            return
        }
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { fatalError("FAIL: " + name) }; count += 1
        }
        let t = Date().timeIntervalSince1970
        let sid = "ses_fixtureABC"
        func event(_ name: String, _ at: Double, _ extra: [String: Any] = [:], id: String = "ses_fixtureABC") throws -> AgentEvent {
            var json: [String: Any] = ["version": 1, "session_id": id, "event": name, "timestamp": t + at,
                "turn_id": "msg_1", "project": "/synthetic/project"]
            json.merge(extra) { _, new in new }
            return HookPayload.event(forAgent: .opencode, stdin: try JSONSerialization.data(withJSONObject: json), now: Date(timeIntervalSince1970: t + at))!
        }
        let read = try event("working", 0, ["new_turn": true, "title": "读取任务", "model": "native-model",
            "tool": "read", "tool_input": ["file_path": "/private/path/README.md", "contents": "SECRET"]])
        try check(read.message == "正在读取 README.md" && read.title == "读取任务" && read.model == "native-model", "native task details")
        let command = try event("working", 1, ["tool": "bash", "tool_input": ["command": "curl -H SECRET"]])
        try check(command.message == "正在执行命令" && command.message?.contains("SECRET") == false, "command privacy")
        try check(try event("waiting", 1, ["waiting_kind": "question"]).message == "等待你的回复", "question activity")
        try check(HookPayload.event(forAgent: .opencode, stdin: Data("{}".utf8), now: Date()) == nil, "malformed envelope ignored")
        try check(!OpencodeHookPayload.validSessionID("../ses_bad"), "invalid session ID")
        try check(!OpencodeNavigation.validSocket("/tmp/oc-1-aaaaaaaaaaaaaaaa.sock"), "foreign socket rejected")
        let store = SessionStore()
        store.apply(read, now: read.timestamp)
        try check(store.session(id: sid)?.indicator == .running, "fresh work blue")
        let clicked = store.session(id: sid)!
        try check(store.markOpened(clicked, at: read.timestamp), "matching click accepted")
        try check(store.session(id: sid)?.indicator == .running && store.session(id: sid)?.hasReadReceipt == true, "running message click records receipt and stays blue")
        let renamed = try event("metadata", 0.5, ["title": "已改名", "model": "model-2"])
        store.apply(renamed, now: renamed.timestamp)
        try check(store.session(id: sid)?.title == "已改名" && store.session(id: sid)?.model == "model-2", "metadata refresh")
        try check(store.session(id: sid)?.indicator == .running && store.session(id: sid)?.hasReadReceipt == true && store.session(id: sid)?.updatedAt == read.timestamp, "metadata leaves running blue, receipt and activity clock intact")
        store.apply(command, now: command.timestamp)
        try check(store.session(id: sid)?.indicator == .running, "new tool blue")
        try check(store.session(id: sid)?.turnStartedAt == read.timestamp, "tools preserve turn clock")
        let wait = try event("waiting", 2)
        store.apply(wait, now: wait.timestamp)
        try check(store.session(id: sid)?.indicator == .attention, "permission waits orange")
        try check(store.session(id: sid)?.pendingApproval == nil, "observer cannot approve permission")
        let done = try event("done", 3, ["result": "cancelled"])
        store.apply(done, now: done.timestamp)
        let ended = store.session(id: sid)!
        try check(ended.taskResult == .cancelled && ended.message == "任务已停止" && ended.turnEndedAt == done.timestamp, "cancelled result and frozen clock")
        store.apply(try event("done", 4), now: Date())
        try check(store.session(id: sid)?.notificationVersion == ended.notificationVersion && store.session(id: sid)?.taskResult == .cancelled, "duplicate idle cannot erase cancellation")
        store.apply(command, now: Date())
        try check(store.session(id: sid)?.state == .done, "out of order work ignored")
        store.apply(try event("working", 5), now: Date())
        try check(store.session(id: sid)?.state == .done, "late tool cannot reopen ended turn")
        store.prune(now: Date(timeIntervalSince1970: t + 20))
        try check(store.session(id: sid)?.state == .done && store.session(id: sid)?.indicator == .read && store.session(id: sid)?.hasUnread == false, "explicit user cancellation is green during grace period")
        store.markOpened(ended, at: Date(timeIntervalSince1970: t + 10))
        store.prune(now: Date(timeIntervalSince1970: t + 39))
        try check(store.session(id: sid)?.state == .done, "read quiet threshold not reached")
        store.prune(now: Date(timeIntervalSince1970: t + 40))
        try check(store.session(id: sid)?.state == .idle, "read completion hides after 30 seconds")
        let next = try event("working", 50, ["new_turn": true, "turn_id": "msg_2"])
        store.apply(next, now: next.timestamp)
        try check(store.session(id: sid)?.indicator == .running && store.session(id: sid)?.turnStartedAt == next.timestamp, "new turn resets receipt and clock")
        try check(!store.markOpened(ended, at: Date()), "old navigation cannot read new turn")
        store.apply(try event("done", 51, ["result": "failed"]), now: Date())
        try check(store.session(id: sid)?.state == .working, "previous turn completion cannot end new turn")
        let fail = try event("done", 52, ["turn_id": "msg_2", "result": "failed"])
        store.apply(fail, now: fail.timestamp)
        try check(store.session(id: sid)?.taskResult == .failed, "failure remains distinct from success")
        store.apply(try event("working", 53, ["new_turn": true], id: "ses_otherABC"), now: Date())
        try check(store.sessions.count == 2, "same directory separate native sessions")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store.persistenceURL = root.appendingPathComponent("snapshot.json"); store.persistCodexSessions()
        let restored = SessionStore(); restored.persistenceURL = store.persistenceURL; restored.restoreCodexSessions()
        try check(restored.session(id: sid)?.hasUnread == true && restored.session(id: sid)?.title == "已改名", "restart restores completion and title")
        let liveStore = SessionStore()
        let liveStart = try event("working", 100, ["new_turn": true, "process_id": 12345])
        liveStore.apply(liveStart, now: liveStart.timestamp)
        let liveCard = liveStore.session(id: sid)!
        liveStore.markOpened(liveCard, at: liveStart.timestamp)
        let heartbeat = try event("heartbeat", 401, ["process_id": 12345])
        liveStore.apply(heartbeat, now: heartbeat.timestamp)
        try check(liveStore.session(id: sid)?.indicator == .running && liveStore.session(id: sid)?.hasReadReceipt == true, "heartbeat preserves click receipt while live task stays blue")
        try check(liveStore.session(id: sid)?.updatedAt == liveStart.timestamp && liveStore.session(id: sid)?.turnStartedAt == liveStart.timestamp, "heartbeat cannot invent activity or reset elapsed time")
        liveStore.prune(now: Date(timeIntervalSince1970: t + 420))
        try check(liveStore.session(id: sid)?.state == .working, "native long task survives five minute inactivity")
        let foreign = try event("heartbeat", 421, ["process_id": 99999])
        try check(liveStore.apply(foreign, now: foreign.timestamp) == nil, "foreign owner heartbeat ignored")
        try check(liveStore.reconcileOpencodeLiveness(now: Date(), processIsAlive: { _ in nil }).isEmpty, "unknown process state cannot end task")
        try check(liveStore.reconcileOpencodeLiveness(now: Date(), processIsAlive: { _ in true }).isEmpty, "live process cannot end task")
        let lost = liveStore.reconcileOpencodeLiveness(now: Date(timeIntervalSince1970: t + 422), processIsAlive: { _ in false })
        try check(lost.count == 1 && lost[0].indicator == .unread && lost[0].opencodeTurnResult == nil && lost[0].opencodeDisconnectedAt != nil, "missing owner becomes unread unknown result, not completion")
        try check(lost[0].message == "会话连接已中断，任务结果未知", "disconnect explanation")
        try check(liveStore.reconcileOpencodeLiveness(now: Date(), processIsAlive: { _ in false }).isEmpty, "disconnect emitted once")
        let delayedDone = try event("done", 410, ["result": "completed", "process_id": 12345])
        liveStore.apply(delayedDone, now: Date(timeIntervalSince1970: t + 424))
        try check(liveStore.session(id: sid)?.opencodeDisconnectedAt == nil && liveStore.session(id: sid)?.opencodeTurnResult == .completed && liveStore.session(id: sid)?.turnEndedAt == delayedDone.timestamp, "delayed authoritative completion corrects unknown result")
        try check(OpencodeLiveness.processIsAlive(getpid()) == true && OpencodeLiveness.processIsAlive(0) == nil, "kernel process liveness")
        let birth = OpencodeLiveness.processStartedAt(getpid())
        try check(birth != nil && OpencodeLiveness.processStartedAt(0) == nil, "kernel process birth time")
        let reusedStore = SessionStore()
        var reused = try event("working", 100, ["new_turn": true, "process_id": Int(getpid())])
        reused.opencodeProcessStartedAt = birth!.addingTimeInterval(-60)
        reusedStore.apply(reused, now: reused.timestamp)
        var reattachedMetadata = try event("metadata", 101, ["title": "重新打开", "process_id": Int(getpid()) + 1])
        reattachedMetadata.opencodeProcessStartedAt = birth
        reusedStore.apply(reattachedMetadata, now: reattachedMetadata.timestamp)
        try check(reusedStore.session(id: sid)?.opencodeProcessID == getpid() && reusedStore.session(id: sid)?.opencodeProcessStartedAt == reused.opencodeProcessStartedAt, "idle client metadata cannot adopt an old active task")
        try check(reusedStore.reconcileOpencodeLiveness(now: Date(), processIsAlive: { _ in true }).count == 1, "PID reuse cannot keep a restored task running")
        let path = root.appendingPathComponent("agentpet.js").path
        try "// foreign hook".write(toFile: path, atomically: true, encoding: .utf8)
        do { try HookInstaller.installToDisk(command: "\"/synthetic/agentpet\" hook --agent opencode", path: path, style: .opencodePlugin); fatalError("foreign replaced") }
        catch HookInstallerError.foreignPlugin { count += 1 }
        try check(try String(contentsOfFile: path, encoding: .utf8) == "// foreign hook", "foreign file preserved")
        try OpencodePlugin.source(binary: "/old/agentpet").write(toFile: path, atomically: true, encoding: .utf8)
        try HookInstaller.installToDisk(command: "\"/new/agentpet\" hook --agent opencode", path: path, style: .opencodePlugin)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".agentpet-backups"), includingPropertiesForKeys: nil)
        try check(try backups.contains { try String(contentsOf: $0.appendingPathComponent("before"), encoding: .utf8) == OpencodePlugin.source(binary: "/old/agentpet") }, "owned upgrade backed up")
        try check(try String(contentsOfFile: path, encoding: .utf8) == OpencodePlugin.source(binary: "/new/agentpet"), "installer uses current helper")
        store.apply(try event("deleted", 60), now: Date())
        try check(store.session(id: sid) == nil && store.session(id: "ses_otherABC") != nil, "explicit deletion removes only exact session")
        print("PASS: \(count) opencode core checks")
    }
}
