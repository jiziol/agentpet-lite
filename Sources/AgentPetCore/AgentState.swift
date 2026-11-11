import Foundation

/// Normalised lifecycle state of an agent session, independent of which
/// agent (Claude Code, Codex, ...) produced it.
public enum AgentState: String, Codable, Sendable, CaseIterable {
    /// Session announced itself but has not started working yet.
    case registered
    /// Actively running (prompt submitted, tools executing).
    case working
    /// Blocked on the user (needs input or a permission decision).
    case waiting
    /// Finished a turn.
    case done
    /// Done and quiet for a while; ambient/no attention needed.
    case idle
}

/// Agent identity. Retired cases remain strictly for old data and Hook ownership.
public enum AgentKind: String, Codable, Sendable {
    case claude
    case codex
    case gemini
    case cursor
    case opencode
    case windsurf
    case antigravity
    /// Official DSH desktop, observed by the independently installed bridge.
    case dsh
    case copilot
    case kiroCLI
    /// Factory Droid CLI (`droid`).
    case droid
    /// Pi Coding Agent (pi.dev).
    case pi
    /// xAI Grok Build CLI (`grok`). Hook payload is camelCase keys + snake_case
    /// event values, via `~/.grok/hooks/agentpet.json`.
    case grok
    /// Legacy jcode identifier; live event adaptation is retired.
    case jcode
    /// Any CLI agent launched via the `agentpet run` wrapper.
    case cli
    case unknown
}

/// How a session's state was learned.
public enum AgentSource: String, Codable, Sendable {
    /// Reported precisely by the agent through a hook.
    case hook
    /// Inferred by passively observing processes (running / not running only).
    case passive
}
