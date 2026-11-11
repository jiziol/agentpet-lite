import Foundation

/// Maps an agent-native event name to a normalised `AgentState`.
///
/// Returns `nil` for events that should not change state (unknown or
/// irrelevant events are ignored rather than treated as an error).
public enum StateMapper {
    /// Events that mean the whole session ended (the agent was quit/closed), so
    /// the session should be removed immediately rather than lingering as done.
    public static func isSessionEnd(for kind: AgentKind, eventName: String) -> Bool {
        guard !RetiredAgentRegistry.ignores(kind) else { return false }
        switch kind {
        case .claude: return eventName == "SessionEnd"
        case .pi: return eventName == "session_shutdown"
        default: return false
        }
    }

    public static func state(for kind: AgentKind, eventName: String) -> AgentState? {
        guard !RetiredAgentRegistry.ignores(kind) else { return nil }
        // Generic: any caller (e.g. the `agentpet run` wrapper) can send a
        // normalised state name directly.
        if let direct = AgentState(rawValue: eventName) { return direct }

        switch kind {
        case .claude:
            switch eventName {
            case "SessionStart": return .registered
            case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .working
            case "Notification", "PermissionRequest", "Elicitation": return .waiting
            case "PostToolUseFailure", "PermissionDenied", "ElicitationResult": return .working
            case "Stop": return .done
            // SubagentStop fires when a Task() subagent finishes mid-session —
            // not when the main session is done. Ignoring it (nil = "no state
            // change") avoids a false done→working flicker.
            case "SubagentStop": return nil
            default: return nil
            }
        case .codex:
            switch eventName {
            case "SessionStart": return .registered
            case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart": return .working
            case "PermissionRequest": return .waiting
            case "Stop": return .done
            case "SubagentStop": return nil
            default: return nil
            }
        case .opencode:
            // The plugin sends normalised states directly (handled above); these
            // map the raw opencode event names as a fallback.
            switch eventName {
            case "session.created": return .working
            case "session.idle": return .done
            default: return nil
            }
        case .antigravity:
            switch eventName {
            case "PreInvocation", "PreToolUse", "PostToolUse", "PostInvocation": return .working
            case "Stop": return .done
            default: return nil
            }
        case .pi:
            // The Pi extension sends normalised state names directly (handled by
            // the AgentState(rawValue:) check above). These map Pi's native event
            // names too, as a fallback. UI dialogs come from native prompt events.
            switch eventName {
            case "session_start": return .registered
            case "agent_start", "turn_start", "tool_execution_start": return .working
            case "ui_prompt_start": return .waiting
            case "ui_prompt_end": return .working
            case "agent_settled", "session_shutdown": return .done
            case "agent_end": return nil
            default: return nil
            }
        case .dsh, .cli, .unknown, .gemini, .cursor, .windsurf, .copilot, .kiroCLI, .droid, .grok, .jcode:
            return nil
        }
    }
}
