import Foundation

/// Native event metadata is interpreted here; no prompt or answer is retained.
public enum HumanHookObserver {
    public static func decorate(_ original: AgentEvent, payload: [String: Any]) -> AgentEvent? {
        var event = original
        if let change = HumanIntervention.decode(payload["agentpet_human"], at: event.timestamp) {
            event.humanIntervention = change
            return event
        }
        let name = payload["hook_event_name"] as? String ?? payload["hookEventName"] as? String ?? event.eventName
        let tool = payload["tool_name"] as? String ?? payload["toolName"] as? String
        let call = payload["call_id"] as? String ?? payload["tool_use_id"] as? String
        let elicitation = payload["elicitation_id"] as? String
        let notification = payload["notification_type"] as? String
        let input: [String: Any]?
        if let object = payload["tool_input"] as? [String: Any] { input = object }
        else if let text = payload["tool_input"] as? String, let data = text.data(using: .utf8) {
            input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else { input = nil }
        if event.agentKind == .claude, ["Notification", "notification"].contains(name), let notification,
           !["permission_prompt", "elicitation_dialog"].contains(notification) { return nil }
        let requestKind = HumanIntervention.toolKind(tool)
        let action: HumanIntervention.Action
        let kind: HumanRequest.Kind
        var ids: [String] = []
        switch name {
        case "PreToolUse", "preToolUse":
            guard let requestKind else { return event }
            action = .asked; kind = requestKind
            if let call {
                if event.agentKind == .codex {
                    let count = (input?["questions"] as? [Any])?.count ?? 1
                    guard count > 0 && count <= 32 else { return event }
                    ids = (0..<count).map { call + "#" + String($0) }
                } else { ids = ["tool:" + call] }
            }
        case "PermissionRequest":
            action = .asked; kind = .permission
            if let call { ids = ["permission:" + call] }
        case "Elicitation":
            action = .asked; kind = .reply
            if let elicitation { ids = ["elicitation:" + elicitation] }
        case "ElicitationResult":
            action = .resolved; kind = .reply
            if let elicitation { ids = ["elicitation:" + elicitation] }
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied", "postToolUse":
            guard let call else { return event }
            action = .resolved; kind = requestKind ?? .permission
            ids = ["permission:" + call]
            if requestKind != nil, event.agentKind != .codex { ids.append("tool:" + call) }
        case "Notification", "notification":
            event.message = notification == "permission_prompt" ? "等待批准" : "等待你的回复"
            return event
        default: return event
        }
        if action == .asked {
            event.eventName = "waiting"
            event.message = HumanRequest(id: "display", kind: kind, createdAt: event.timestamp).message
        } else if name == "ElicitationResult" { event.eventName = "working" }
        if !ids.isEmpty, ids.allSatisfy(HumanIntervention.validID) {
            event.humanIntervention = HumanIntervention(action: action, requests: ids.enumerated().map { index, id in
                let questions = input?["questions"] as? [[String: Any]] ?? []
                let individual = event.agentKind == .codex && action == .asked && requestKind != nil && questions.indices.contains(index)
                    ? ((questions[index]["options"] as? [Any] ?? []).isEmpty ? HumanRequest.Kind.reply : .choice) : kind
                return HumanRequest(id: id, kind: individual, createdAt: event.timestamp)
            })
        }
        return event
    }
}
