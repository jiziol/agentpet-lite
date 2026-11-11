import Foundation

/// Compatibility/migration inventory, never an install or live discovery list.
/// AgentKind keeps its old cases for v1 snapshots, history and settings.
public enum RetiredAgentRegistry {
    public static let kinds: [AgentKind] = [.gemini, .cursor, .windsurf, .copilot, .kiroCLI, .droid, .grok, .jcode]
    public static func kind(named name: String) -> AgentKind? {
        let key = name.lowercased()
        return kinds.first { $0.rawValue.lowercased() == key }
    }
    public static func ignores(_ kind: AgentKind, rawName: String? = nil) -> Bool {
        kinds.contains(kind) || (kind == .unknown && rawName.flatMap(Self.kind(named:)) != nil)
    }
    public static func migrationSpec(for kind: AgentKind, home: String = NSHomeDirectory()) -> AgentHookSpec? {
        switch kind {
        case .gemini:
            return AgentHookSpec(
                kind: .gemini, style: .claudeNested,
                events: ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd"],
                settingsPath: home + "/.gemini/settings.json")
        case .cursor:
            return AgentHookSpec(
                kind: .cursor, style: .cursorFlat,
                events: ["sessionStart", "beforeSubmitPrompt", "preToolUse", "stop", "subagentStop", "sessionEnd"],
                settingsPath: home + "/.cursor/hooks.json")
        case .windsurf:
            return AgentHookSpec(
                kind: .windsurf, style: .windsurfFlat,
                events: ["pre_user_prompt", "post_cascade_response"],
                settingsPath: home + "/.codeium/windsurf/hooks.json")
        case .copilot:
            // GitHub Copilot CLI: ~/.copilot/hooks/*.json, same flat shape as
            // Cursor (version + {type:command, command}). PascalCase event names
            // make Copilot send a snake_case payload with `hook_event_name`,
            // which decodes via the Claude payload. PreToolUse is deliberately
            // omitted: its command hook is fail-closed, so an error would block
            // the user's tools.
            return AgentHookSpec(
                kind: .copilot, style: .cursorFlat,
                events: ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"],
                settingsPath: home + "/.copilot/hooks/agentpet.json")
        case .kiroCLI:
            // Kiro CLI: hooks live inside an agent config file. We target the
            // default agent. camelCase lifecycle events; STDIN carries
            // hook_event_name/cwd/session_id (Claude-style). preToolUse omitted
            // to avoid any chance of blocking tool calls.
            return AgentHookSpec(
                kind: .kiroCLI, style: .kiroFlat,
                events: ["agentSpawn", "userPromptSubmit", "postToolUse", "stop"],
                settingsPath: home + "/.kiro/agents/default.json")
        case .droid:
            // Factory Droid CLI: ~/.factory/hooks.json, identical nested shape and
            // snake_case stdin payload as Claude (session_id/cwd/hook_event_name).
            // Notification fires on permission/approval requests (and 60s idle),
            // which we map to "waiting". Our hook command always exits 0, so the
            // PreToolUse hook can't block tool calls.
            return AgentHookSpec(
                kind: .droid, style: .claudeNested,
                events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SubagentStop", "SessionEnd"],
                settingsPath: home + "/.factory/hooks.json")
        case .grok:
            // xAI Grok Build: ~/.grok/hooks/*.json, Claude-compatible nested shape,
            // registered with PascalCase event names (Grok also accepts these).
            // Grok's payload uses camelCase keys + snake_case event VALUES.
            // PreToolUse is omitted: Grok treats a hook's exit 2 on PreToolUse as
            // "deny" and on Stop as "keep working", and our hook always exits 0,
            // so the remaining events report state without any risk of blocking.
            return AgentHookSpec(
                kind: .grok, style: .claudeNested,
                events: ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"],
                settingsPath: home + "/.grok/hooks/agentpet.json")
        case .jcode:
            // Observers only: jcode spawns them detached, so they never slow a
            // turn. pre_tool (a blocking gate) is deliberately not used.
            return AgentHookSpec(
                kind: .jcode, style: .jcodeToml,
                events: ["session_start", "turn_start", "post_tool", "turn_end", "session_end"],
                settingsPath: home + "/.jcode/config.toml")
        default: return nil
        }
    }
}
