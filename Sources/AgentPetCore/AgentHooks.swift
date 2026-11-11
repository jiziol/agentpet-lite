import Foundation

/// How an agent's hook configuration is written. The supported agents do not
/// share one format, so each spec carries its style.
public enum HookStyle: Sendable {
    /// Claude Code / Codex / Gemini: `{"hooks": {Event: [{"hooks": [{"type": "command", "command": ...}]}]}}`.
    case claudeNested
    /// Cursor `~/.cursor/hooks.json`: `{"version": 1, "hooks": {event: [{"command": ..., "type": "command"}]}}`.
    case cursorFlat
    /// Windsurf `~/.codeium/windsurf/hooks.json`: `{"hooks": {event: [{"command": ...}]}}`.
    case windsurfFlat
    /// opencode: a JS plugin file dropped in `~/.config/opencode/plugin/`.
    case opencodePlugin
    /// Antigravity `~/.gemini/config/hooks.json`: like claudeNested but the event
    /// map lives under a named hook group instead of a top-level `"hooks"` key:
    /// `{"agentpet": {Event: [{"hooks": [{"type": "command", "command": ...}]}]}}`.
    case antigravityNested
    /// Kiro CLI agent config `~/.kiro/agents/<agent>.json`: a `"hooks"` key merged
    /// into the agent file as `{"hooks": {event: [{"command": ...}]}}` (plain
    /// command items, no extra keys). Other agent fields are preserved.
    case kiroFlat
    /// Pi (pi.dev): a TypeScript extension file dropped in
    /// `~/.pi/agent/extensions/`. Like opencode, the extension hardcodes its own
    /// `pi.on(...)` handlers and reports state through the `agentpet hook` CLI.
    case piExtension
    /// jcode `~/.jcode/config.toml`: one key per event in the `[hooks]` table,
    /// value a command string or an array of them.
    case jcodeToml
}

/// Where and which lifecycle events to register for an agent.
public struct AgentHookSpec {
    public let kind: AgentKind
    public let style: HookStyle
    public let events: [String]
    public let settingsPath: String

    public init(kind: AgentKind, style: HookStyle, events: [String], settingsPath: String) {
        self.kind = kind; self.style = style; self.events = events; self.settingsPath = settingsPath
    }
}

public enum AgentHooks {
    public static func spec(for kind: AgentKind, home: String = NSHomeDirectory(),
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentHookSpec? {
        guard AgentCatalog.isMaintained(kind) else { return nil }
        let codex = environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home + "/.codex"
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home + "/.config"
        switch kind {
        case .claude:
            return AgentHookSpec(
                kind: .claude, style: .claudeNested,
                events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied", "Elicitation", "ElicitationResult", "Notification", "Stop", "SubagentStop", "SessionEnd"],
                settingsPath: home + "/.claude/settings.json")
        case .codex:
            return AgentHookSpec(
                kind: .codex, style: .claudeNested,
                events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "SubagentStop"],
                settingsPath: codex + "/hooks.json")
        case .opencode:
            // The JS plugin hardcodes its own session.created/session.idle hooks,
            // so no event list is registered through the generic installer.
            return AgentHookSpec(
                kind: .opencode, style: .opencodePlugin,
                events: [],
                settingsPath: config + "/opencode/plugin/agentpet.js")
        case .antigravity:
            // Antigravity has no session-start/notification hooks, so we register
            // for the model-call and tool lifecycle plus Stop. PreInvocation fires
            // when a turn begins; Stop when the agent loop ends. PreToolUse is
            // a permission gate, so an observer must not register it.
            return AgentHookSpec(
                kind: .antigravity, style: .antigravityNested,
                events: ["PreInvocation", "PostToolUse", "Stop"],
                settingsPath: home + "/.gemini/config/hooks.json")
        case .pi:
            // Pi has no Claude-style command hooks; its native mechanism is a TS
            // extension auto-discovered in ~/.pi/agent/extensions/. The extension
            // hardcodes its own pi.on() handlers, so no event list is registered
            // through the generic installer. Native aggregate UI prompts report
            // waiting/resolved without wrapping or answering extension dialogs.
            return AgentHookSpec(
                kind: .pi, style: .piExtension,
                events: [],
                settingsPath: home + "/.pi/agent/extensions/agentpet.ts")
        default: return nil
        }
    }
}
