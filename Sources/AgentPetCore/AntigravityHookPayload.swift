import Foundation

/// The native CLI uses camelCase metadata and has no hook event name.
/// Only display metadata is retained; command arguments and bodies are discarded.
public struct AntigravityHookPayload: Decodable, Equatable {
    public let conversationId: String?
    public let workspacePaths: [String]?
    public let transcriptPath: String?
    public let toolCall: ToolCall?
    public let terminationReason: String?
    public let fullyIdle: Bool?
    public let invocationNum: Int?
    public let initialNumSteps: Int?
    public let stepIdx: Int?
    public let model: HookModelInfo?
    public let modelName: String?

    public struct ToolArgs: Decodable, Equatable {
        public let executable: String?
        public let filename: String?
        private enum Key: String, CodingKey {
            case commandLine = "CommandLine", command, cmd, absolutePath = "AbsolutePath"
            case targetFile = "TargetFile", filePath = "file_path", path, directoryPath = "DirectoryPath"
        }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            func value(_ keys: [Key]) -> String? {
                keys.lazy.compactMap { try? container.decode(String.self, forKey: $0) }.first
            }
            let command = value([.commandLine, .command, .cmd])
            let candidate = command?.split(whereSeparator: { $0.isWhitespace }).first.map { String($0).components(separatedBy: "/").last ?? "" }
            executable = candidate.flatMap { name in
                name.count <= 80 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) } ? name : nil
            }
            let path = value([.absolutePath, .targetFile, .filePath, .path, .directoryPath])
            filename = path.map { String(($0 as NSString).lastPathComponent.prefix(80)) }
        }
    }

    public struct ToolCall: Decodable, Equatable {
        public let name: String?
        public let args: ToolArgs?
        public init(name: String?) { self.name = name; args = nil }
    }

    public static func decode(from data: Data) -> AntigravityHookPayload? {
        try? JSONDecoder().decode(AntigravityHookPayload.self, from: data)
    }

    public func makeEvent(now: Date) -> AgentEvent? {
        guard let conversationId, !conversationId.isEmpty, conversationId.count <= 256 else { return nil }
        let reason = terminationReason?.lowercased()
        let state: AgentState
        let activity: String
        if terminationReason != nil || fullyIdle != nil {
            if Self.cancelReasons.contains(reason ?? "") {
                state = .done; activity = "任务已停止"
            } else if fullyIdle == false {
                state = .working; activity = "后台任务仍在运行"
            } else {
                state = .done
                switch reason {
                case "error", "max_steps_exceeded": activity = "任务结束，发生错误"
                case "cancelled", "canceled", "interrupted", "user_cancel": activity = "任务已停止"
                default: activity = "本轮已完成"
                }
            }
        } else if let toolCall {
            state = .working; activity = Self.activity(toolCall)
        } else if invocationNum != nil {
            state = .working; activity = "正在处理任务"
        } else if stepIdx != nil {
            state = .working; activity = "工具执行结束，继续处理任务"
        } else { return nil }
        var event = AgentEvent(sessionId: conversationId, agentKind: .antigravity,
            eventName: state.rawValue,
            project: workspacePaths?.first(where: { !$0.isEmpty }), message: activity,
            model: (model?.displayName ?? modelName).map { String($0.prefix(80)) },
            transcriptPath: transcriptPath, timestamp: now)
        event.antigravityNewInvocation = invocationNum != nil && terminationReason == nil && fullyIdle == nil
        if event.antigravityNewInvocation == true,
           let count = initialNumSteps, count > 0, count <= Int(Int32.max) {
            // The native count includes the current thinking step, even when
            // its database write has not been flushed before the Hook runs.
            event.antigravityStepFloor = count - 1
        } else if invocationNum == nil, let index = stepIdx, index >= 0, index <= Int(Int32.max) {
            event.antigravityStepFloor = index
        }
        if state == .done {
            switch reason {
            case "error", "max_steps_exceeded": event.turnResult = .failed
            case let reason? where Self.cancelReasons.contains(reason): event.turnResult = .cancelled
            default: event.turnResult = .completed
            }
        }
        return event
    }

    private static let cancelReasons: Set<String> = ["cancelled", "canceled", "interrupted", "user_cancel", "user_canceled", "user_cancelled"]

    static func activity(_ call: ToolCall) -> String {
        let name = call.name?.lowercased() ?? ""
        if ["run_command", "bash", "exec_command"].contains(name), call.args?.executable == "sleep" { return "正在等待命令完成" }
        let aliases = ["run_command": "exec_command", "view_file": "read_file", "view_file_outline": "read_file",
                       "write_to_file": "write_file", "replace_file_content": "edit_file", "multi_replace_file_content": "edit_file",
                       "list_dir": "glob", "find_by_name": "glob", "grep_search": "grep", "search_web": "web_search",
                       "command_status": "wait", "send_command_input": "write_stdin"]
        var safeInput: [String: Any] = [:]
        if let executable = call.args?.executable { safeInput["cmd"] = executable }
        if let filename = call.args?.filename { safeInput["path"] = filename }
        return SafeActivityFormatter.activity(event: "PreToolUse", tool: aliases[name] ?? call.name, input: safeInput)
    }
}
