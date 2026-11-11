import Foundation

/// Codex inputs differ from Claude's tools. Retain only safe display metadata,
/// never prompts, tool bodies, command arguments, or model responses.
public enum CodexHookPayload {
    public static func event(from data: Data, now: Date) -> AgentEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["session_id"] as? String,
              !id.isEmpty, id.count <= 256,
              let name = json["hook_event_name"] as? String else { return nil }
        let tool = json["tool_name"] as? String
        var input = json["tool_input"] as? [String: Any] ?? [:]
        if let text = json["tool_input"] as? String, let bytes = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { input = object }
        var model = json["model"] as? String
        if let object = json["model"] as? [String: Any] { model = object["display_name"] as? String ?? object["id"] as? String }
        var event = AgentEvent(sessionId: id, agentKind: .codex, eventName: name,
                          project: json["cwd"] as? String,
                          message: activity(event: name, tool: tool, input: input), model: model,
                          transcriptPath: json["transcript_path"] as? String,
                          subagentId: json["agent_id"] as? String, timestamp: now)
        if name == "PermissionRequest", let turnID = json["turn_id"] as? String, HumanIntervention.validID(turnID) {
            event.codexPermissionTurnID = turnID
        }
        return event
    }

    /// Compatibility entry for the existing Hook protocol and callers.
    public static func activity(event: String, tool: String?, input: [String: Any]) -> String {
        SafeActivityFormatter.activity(event: event, tool: tool, input: input)
    }
}
