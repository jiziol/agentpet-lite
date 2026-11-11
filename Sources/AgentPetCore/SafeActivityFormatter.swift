import Foundation

/// Shared metadata-only activity formatter. Never displays command arguments or bodies.
public enum SafeActivityFormatter {
    static func displayLabel(_ value: String, limit: Int) -> String {
        String(String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(limit))
    }

    public static func activity(event: String, tool: String?, input: [String: Any]) -> String {
        switch event {
        case "SessionStart": return "会话已连接"
        case "UserPromptSubmit": return "正在处理任务"
        case "PermissionRequest": return "等待批准"
        case "Stop": return "本轮已完成"
        default: break
        }
        guard let tool else { return "正在处理任务" }
        let shortName = tool.components(separatedBy: ".").last ?? tool
        let name = shortName.lowercased()
        let path = input["file_path"] as? String ?? input["path"] as? String
        let target = path.map { " " + displayLabel(($0 as NSString).lastPathComponent, limit: 80) } ?? ""
        switch name {
        case "read_file", "view_image", "read": return "正在读取" + target
        case "apply_patch", "edit_file", "write_file", "edit", "write", "multiedit": return "正在修改文件" + target
        case "exec_command", "shell", "shell_command", "run", "bash":
            let command = input["cmd"] as? String ?? input["command"] as? String ?? ""
            let executable = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            switch (executable as NSString).lastPathComponent {
            case "rg", "grep", "find": return "正在搜索代码"
            case "cat", "head", "tail", "sed": return "正在读取文件"
            case "python", "python3": return "正在运行 Python 脚本"
            case "swift", "swiftc": return "正在运行 Swift 工具"
            case "git": return "正在运行 Git"
            default: return "正在执行命令"
            }
        case "write_stdin", "wait": return "等待命令结果"
        case "web__run", "search_query", "web_search", "websearch", "webfetch": return "正在检索资料"
        case "request_user_input", "request_user_input_async": return "等待你的回复"
        case "spawn_agent", "send_message", "task", "agent": return "正在协调子任务"
        case "exec": return "正在调用工具"
        case "grep", "glob": return "正在搜索文件"
        default:
            if name.hasPrefix("mcp__cua_repl__") { return "正在检查界面" }
            if name.hasPrefix("mcp__") { return "正在调用外部工具" }
            return "正在调用 " + displayLabel(shortName, limit: 64)
        }
    }
}
