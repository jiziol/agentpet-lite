import Foundation

/// Reads only the title of the exact native CLI conversation. No cwd fallback.
public enum AntigravityMetadata {
    public static func title(sessionID: String, transcriptPath: String?, home: String = NSHomeDirectory() + "/.gemini/antigravity-cli") -> String? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        let annotation = home + "/annotations/" + sessionID + ".pbtxt"
        if let file = FileHandle(forReadingAtPath: annotation) {
            defer { try? file.close() }
            if let bytes = try? file.read(upToCount: 16_384), let text = String(data: bytes, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let value = line.trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix("title:") else { continue }
                    let literal = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    if let data = ("[" + literal + "]").data(using: .utf8),
                       let array = try? JSONSerialization.jsonObject(with: data) as? [String], let title = array.first,
                       let display = compact(title) { return display }
                }
            }
        }
        guard let transcriptPath,
              URL(fileURLWithPath: transcriptPath).pathComponents.contains(sessionID),
              let file = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 65_536) else { return nil }
        for line in bytes.split(separator: 0x0A) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  root["type"] as? String == "USER_INPUT", root["source"] as? String == "USER_EXPLICIT",
                  let content = root["content"] as? String, let title = compact(content) else { continue }
            return title
        }
        return nil
    }

    /// PostToolUse omits tool details. Read the exact snapshot and label it as
    /// recent activity, rather than claiming that an already finished tool runs.
    public static func recentActivity(sessionID: String, transcriptPath: String?) -> String? {
        guard UUID(uuidString: sessionID) != nil, let transcriptPath,
              URL(fileURLWithPath: transcriptPath).pathComponents.contains(sessionID),
              let file = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        try? file.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let bytes = try? file.read(upToCount: 262_144) else { return nil }
        for line in bytes.split(separator: 0x0A).reversed() {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  root["type"] as? String == "PLANNER_RESPONSE",
                  let calls = root["tool_calls"] as? [[String: Any]], let latest = calls.last,
                  let data = try? JSONSerialization.data(withJSONObject: latest),
                  let call = try? JSONDecoder().decode(AntigravityHookPayload.ToolCall.self, from: data) else { continue }
            let activity = AntigravityHookPayload.activity(call)
            return "最近工具：" + (activity.hasPrefix("正在") ? String(activity.dropFirst(2)) : activity)
        }
        return nil
    }

    private static func compact(_ text: String) -> String? {
        let title = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !title.isEmpty else { return nil }
        return String(title.prefix(120))
    }
}
