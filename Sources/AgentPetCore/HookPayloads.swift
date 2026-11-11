import Foundation

/// Decodes a hook's stdin payload into an `AgentEvent`, choosing the field
/// convention by agent kind. opencode supports both plugin JSON and legacy explicit flags.
public enum HookPayload {
    public static func event(forAgent kind: AgentKind, stdin data: Data, now: Date) -> AgentEvent? {
        guard !RetiredAgentRegistry.ignores(kind), data.count <= 1_048_576 else { return nil }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var decoded = nativeEvent(forAgent: kind, stdin: data, now: now)
        // A documented observer envelope also works for adapters whose native
        // JSON has different names. Preserve opencode's native identity checks.
        if decoded == nil, kind != .opencode, let object,
           HumanIntervention.decode(object["agentpet_human"], at: now) != nil,
           let id = object["session_id"] as? String, HumanIntervention.validID(id),
           let name = object["hook_event_name"] as? String, AgentState(rawValue: name) != nil {
            decoded = AgentEvent(sessionId: id, agentKind: kind, eventName: name,
                project: object["cwd"] as? String, timestamp: now)
        }
        guard var event = decoded else { return nil }
        guard let object else { return event }
        // Older Pi templates emitted done for any agent_end. Only explicit
        // results from the settled observer may prove successful completion.
        if kind == .pi, event.eventName == "done", let result = object["turn_result"] as? String {
            event.turnResult = CodexTurnResult(rawValue: result)
        }
        return HumanHookObserver.decorate(event, payload: object)
    }

    private static func nativeEvent(forAgent kind: AgentKind, stdin data: Data, now: Date) -> AgentEvent? {
        switch kind {
        case .opencode:
            return OpencodeHookPayload.event(from: data, now: now)
        case .codex:
            return CodexHookPayload.event(from: data, now: now)
        case .antigravity:
            return AntigravityHookPayload.decode(from: data)?.makeEvent(now: now)
        default:
            return ClaudeHookPayload.decode(from: data)?.makeEvent(now: now, kind: kind)
        }
    }
}
