import Foundation

/// Small, versioned observer envelope. No prompts, outputs or error bodies.
public enum OpencodeHookPayload {
    public static func validSessionID(_ id: String) -> Bool {
        id.range(of: "^ses_[A-Za-z0-9]+$", options: .regularExpression) != nil && id.count <= 128
    }

    public static func event(from data: Data, now: Date) -> AgentEvent? {
        guard data.count <= 65_536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["version"] as? Int == 1,
              let id = json["session_id"] as? String, validSessionID(id),
              let name = json["event"] as? String,
              ["working", "waiting", "done", "metadata", "deleted", "heartbeat"].contains(name) else { return nil }
        let result = (json["result"] as? String).flatMap(CodexTurnResult.init(rawValue:))
        let message: String?
        switch name {
        case "metadata", "deleted", "heartbeat": message = nil
        case "done":
            if json["result"] as? String == "unknown" { message = "会话连接已中断，任务结果未知"; break }
            switch result {
            case .cancelled: message = "任务已停止"
            case .failed: message = "任务结束，发生错误"
            default: message = "本轮已完成"
            }
        case "waiting": message = json["waiting_kind"] as? String == "question" ? "等待你的回复" : "等待批准"
        default:
            let tool = json["tool"] as? String
            var input = json["tool_input"] as? [String: Any] ?? [:]
            if let path = input["file_path"] as? String { input["file_path"] = text((path as NSString).lastPathComponent, limit: 80) }
            message = SafeActivityFormatter.activity(event: "PreToolUse", tool: tool, input: input)
        }
        let seconds = json["timestamp"] as? Double
        let timestamp = seconds.flatMap { $0.isFinite && abs($0 - now.timeIntervalSince1970) < 86_400 ? Date(timeIntervalSince1970: $0) : nil } ?? now
        var event = AgentEvent(sessionId: id, agentKind: .opencode, eventName: name,
            project: text(json["project"], limit: 4096), message: message,
            model: text(json["model"], limit: 160), timestamp: timestamp)
        event.title = text(json["title"], limit: 160)
        event.opencodeNewTurn = json["new_turn"] as? Bool
        event.opencodeTurnID = text(json["turn_id"], limit: 256)
        if let parent = json["parent_session_id"] as? String,
           validSessionID(parent), parent != id { event.opencodeParentSessionID = parent }
        event.opencodeNavigationSocket = (json["navigation_socket"] as? String).flatMap { OpencodeNavigation.validSocket($0) ? $0 : nil }
        if let pid = json["process_id"] as? Int, pid > 1, pid <= Int(Int32.max) {
            event.opencodeProcessID = Int32(pid)
        }
        event.turnResult = name == "done" && json["result"] as? String != "unknown" ? result ?? .completed : nil
        return event
    }

    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let value = value as? String else { return nil }
        let clean = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

public enum OpencodeNavigation {
    public static func validSocket(_ path: String) -> Bool {
        let roots = [AgentPetPaths.baseDir] + [AgentPetPaths.migratedLocalDir].compactMap { $0 }
        guard let root = roots.first(where: { path.hasPrefix($0 + "/") }), path.utf8.count < 104 else { return false }
        let prefix = root + "/"
        let name = String(path.dropFirst(prefix.count))
        return name.range(of: "^oc-[0-9]+-[a-f0-9]{16}\\.sock$", options: .regularExpression) != nil
    }

    /// A bounded local request to the owning live plugin, using its native SDK.
    public static func select(session: AgentSession) -> Bool {
        guard OpencodeHookPayload.validSessionID(session.id), let path = session.opencodeNavigationSocket,
              validSocket(path), let fd = EventSender.connectedSocket(path: path) else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              var bytes = try? JSONSerialization.data(withJSONObject: ["sessionID": session.id]) else { return false }
        bytes.append(0x0A)
        guard EventSender.writeAll(bytes, fd: fd) else { return false }
        var data = Data(), chunk = [UInt8](repeating: 0, count: 256)
        while !data.contains(0x0A) && data.count <= 1024 {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return false }
            data.append(contentsOf: chunk[0..<count])
        }
        guard let end = data.firstIndex(of: 0x0A),
              let reply = try? JSONSerialization.jsonObject(with: Data(data[..<end])) as? [String: Any] else { return false }
        return reply["sessionID"] as? String == session.id && reply["ok"] as? Bool == true
    }
}
