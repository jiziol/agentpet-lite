import Foundation

@main
struct AntigravityChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { fatalError("FAIL: " + name) }
            checks += 1; print("PASS: " + name)
        }
        let a = "11111111-1111-4111-8111-111111111111"
        let b = "22222222-2222-4222-8222-222222222222"
        func event(_ payload: [String: Any], _ at: Double) throws -> AgentEvent {
            var payload = payload; payload["conversationId"] = a
            guard let event = HookPayload.event(forAgent: .antigravity, stdin: try JSONSerialization.data(withJSONObject: payload), now: Date(timeIntervalSince1970: at)) else { fatalError("Invalid fixture") }
            return event
        }
        let sleep = try event(["modelName": "Gemini 3.8 Flash", "workspacePaths": ["/synthetic/project"], "stepIdx": 0,
            "toolCall": ["name": "run_command", "args": ["CommandLine": "sleep 180", "Blocking": true, "WaitMsBeforeAsync": 1000]]], 1)
        try check(sleep.model == "Gemini 3.8 Flash", "native camelCase modelName retained")
        try check(sleep.message == "正在等待命令完成" && sleep.project == "/synthetic/project", "blocking activity and mixed-type args decoded")
        let read = try event(["toolCall": ["name": "view_file", "args": ["AbsolutePath": "/private/project/README.md", "StartLine": 1]]], 2)
        try check(read.message == "正在读取 README.md", "read activity keeps filename only")
        let command = try event(["toolCall": ["name": "run_command", "args": ["CommandLine": "curl -H 'Authorization: SECRET' https://example.invalid"]]], 2)
        try check(command.message == "正在执行命令" && command.message?.contains("SECRET") == false, "command arguments never reach bubble")
        try check(try event(["toolCall": ["name": "search_web", "args": ["query": "private question"]]], 2).message == "正在检索资料", "web activity omits query")
        try check(try event(["model": ["display_name": "Legacy"], "modelName": "native", "invocationNum": 1], 2).model == "Legacy", "legacy model compatibility")
        try check(try event(["invocationNum": 1], 2).message == "正在处理任务", "invocation reports real lifecycle instead of random theme")
        let background = try event(["terminationReason": "model_stop", "fullyIdle": false], 3)
        try check(background.eventName == "working" && background.turnResult == nil, "Stop with background tasks remains active")
        let stop = try event(["terminationReason": "model_stop", "fullyIdle": true], 4)
        try check(stop.eventName == "done" && stop.turnResult == .completed, "fully idle task completes")
        let failed = try event(["terminationReason": "error", "fullyIdle": true, "error": "private failure body"], 4)
        try check(failed.turnResult == .failed && failed.message == "任务结束，发生错误", "failure is not success and body omitted")
        try check(try event(["terminationReason": "interrupted", "fullyIdle": true], 4).turnResult == .cancelled, "interrupted result is stopped")
        let store = SessionStore(); store.apply(sleep, now: sleep.timestamp); store.apply(read, now: read.timestamp)
        store.apply(background, now: background.timestamp); store.apply(stop, now: stop.timestamp)
        try check(store.session(id: a)?.turnStartedAt == sleep.timestamp && store.session(id: a)?.turnEndedAt == stop.timestamp, "elapsed spans all tool changes and freezes")
        store.apply(read, now: Date(timeIntervalSince1970: 5))
        try check(store.session(id: a)?.state == .done, "older working event cannot regress done")
        store.apply(try event(["invocationNum": 1], 6), now: Date(timeIntervalSince1970: 6))
        try check(store.session(id: a)?.turnEndedAt == nil && store.session(id: a)?.turnStartedAt == Date(timeIntervalSince1970: 6), "new task restarts clock")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("brain/" + a + "/.system_generated/logs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("transcript_full.jsonl")
        let input: [String: Any] = ["type": "USER_INPUT", "source": "USER_EXPLICIT", "content": "三分钟阻塞任务\n验证 AgentPet"]
        try JSONSerialization.data(withJSONObject: input).write(to: transcript)
        try check(AntigravityMetadata.title(sessionID: a, transcriptPath: transcript.path, home: root.path) == "三分钟阻塞任务 验证 AgentPet", "exact native transcript supplies task title")
        try check(AntigravityMetadata.title(sessionID: b, transcriptPath: transcript.path, home: root.path) == nil, "another session cannot borrow transcript title")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("annotations"), withIntermediateDirectories: true)
        try Data("title: \"Renamed task\"\n".utf8).write(to: root.appendingPathComponent("annotations/" + a + ".pbtxt"))
        try check(AntigravityMetadata.title(sessionID: a, transcriptPath: transcript.path, home: root.path) == "Renamed task", "native renamed title takes priority")
        try check(AntigravityMetadata.title(sessionID: "../bad", transcriptPath: transcript.path, home: root.path) == nil, "malformed ID cannot access metadata")
        var withTool = try Data(contentsOf: transcript)
        withTool.append(0x0A)
        withTool.append(try JSONSerialization.data(withJSONObject: ["type": "PLANNER_RESPONSE", "tool_calls": [["name": "view_file", "args": ["AbsolutePath": "/private/README.md"]]]]))
        try withTool.write(to: transcript)
        try check(AntigravityMetadata.recentActivity(sessionID: a, transcriptPath: transcript.path) == "最近工具：读取 README.md", "non-gating post-tool snapshot supplies truthful recent activity")
        store.updateAntigravityActivity(id: a, message: "stale activity", since: stop.timestamp)
        try check(store.session(id: a)?.message != "stale activity", "late metadata cannot overwrite new turn activity")
        let spec = AgentHooks.spec(for: .antigravity)!
        try check(!spec.events.contains("PreToolUse"), "observer does not register a permission gate")
        let legacy: [String: Any] = ["agentpet": ["PreToolUse": [["matcher": "*", "hooks": [["command": "\"/Applications/AgentPet.app/Contents/MacOS/agentpet\" hook --agent antigravity"], ["command": "echo foreign"]]]]]]
        let installed = HookInstaller.installAntigravity(into: legacy, command: "\"/Applications/AgentPet Local.app/Contents/MacOS/agentpet\" hook --agent antigravity", events: spec.events)
        let nativeGroup = installed["agentpet"] as? [String: Any]
        let preEntries = nativeGroup?["PreToolUse"] as? [[String: Any]]
        let handlers = preEntries?.first?["hooks"] as? [[String: Any]]
        try check(handlers?.count == 1 && handlers?.first?["command"] as? String == "echo foreign", "legacy observer gate removed without deleting foreign permissions")
        print("\(checks) portable Antigravity checks passed.")
    }
}
