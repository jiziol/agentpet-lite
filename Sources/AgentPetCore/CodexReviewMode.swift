import Foundation

/// Only native policy metadata is retained; command and answer bodies are discarded.
public enum CodexReviewMode: String, Sendable, Equatable {
    case automatic = "auto_review"
    case user
    /// Native policy forbids an interactive approval prompt.
    case nonInteractive = "non_interactive"

    /// A native PermissionRequest can be automatic internal review rather than
    /// a question. Clear the routing marker after inspection to avoid deferral
    /// loops; an identified prompt always retains its native waiting behavior.
    public static func reviewedPermission(_ original: AgentEvent, mode: Self?) -> AgentEvent {
        guard original.agentKind == .codex, original.codexPermissionTurnID != nil else { return original }
        var event = original
        event.codexPermissionTurnID = nil
        if (mode == .automatic || mode == .nonInteractive) && event.humanIntervention == nil && event.approvalRequestId == nil {
            event.eventName = "working"
            event.message = "正在处理任务"
        }
        return event
    }

    public static func read(path: String, sessionID: String, turnID: String, at timestamp: Date) -> Self? {
        guard HumanIntervention.validID(sessionID), HumanIntervention.validID(turnID),
              let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            let start = size > 16_777_216 ? size - 16_777_216 : 0
            try file.seek(toOffset: start)
            let bytes = try file.read(upToCount: 16_777_216) ?? Data()
            var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            if start > 0 && !lines.isEmpty { lines.removeFirst() }
            // A writer's partial final JSON is not usable evidence.
            if bytes.last != 0x0A && !lines.isEmpty { lines.removeLast() }
            return parse(lines.map { Data($0) }, sessionID: sessionID, turnID: turnID, at: timestamp)
        } catch { return nil }
    }

    /// Resolves changes as of the Hook's native timestamp, not today's policy.
    public static func parse(_ lines: [Data], sessionID: String, turnID: String, at timestamp: Date) -> Self? {
        guard lines.reduce(0, { $0 + $1.count }) <= 16_777_216,
              HumanIntervention.validID(sessionID), HumanIntervention.validID(turnID) else { return nil }
        var latestContext: (id: String, date: Date, mode: Self?)?
        var latestStart: (id: String, date: Date)?
        var latestSettings: (date: Date, mode: Self?)?
        for line in lines where line.count <= 1_048_576 {
            guard line.range(of: Data("turn_context".utf8)) != nil ||
                    line.range(of: Data("thread_settings_applied".utf8)) != nil ||
                    line.range(of: Data("task_started".utf8)) != nil,
                  let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let date = CodexLifecycle.date(root["timestamp"]), date <= timestamp,
                  let p = root["payload"] as? [String: Any] else { continue }
            if root["type"] as? String == "turn_context", let id = p["turn_id"] as? String,
               latestContext == nil || date > latestContext!.date {
                latestContext = (id, date, mode(in: p))
            } else if root["type"] as? String == "event_msg", p["type"] as? String == "task_started",
                      let id = p["turn_id"] as? String, latestStart == nil || date > latestStart!.date {
                latestStart = (id, date)
            } else if root["type"] as? String == "event_msg", p["type"] as? String == "thread_settings_applied",
                      p["thread_id"] as? String == sessionID,
                      let settings = p["thread_settings"] as? [String: Any],
                      latestSettings == nil || date > latestSettings!.date {
                latestSettings = (date, mode(in: settings))
            }
        }
        guard let context = latestContext, context.id == turnID else { return nil }
        if let start = latestStart, start.date > context.date && start.id != turnID { return nil }
        if let settings = latestSettings, settings.date > context.date { return settings.mode }
        return context.mode
    }

    private static func mode(in metadata: [String: Any]) -> Self? {
        // "never" disallows asking the human even when the reviewer's label is
        // "user". Do not infer this from hook permission_mode or missing fields.
        if metadata["approval_policy"] as? String == "never" { return .nonInteractive }
        switch metadata["approvals_reviewer"] as? String {
        case "auto_review": return .automatic
        case "user": return .user
        default: return nil
        }
    }

}
