import Foundation

/// Value state; each native ordering channel retains its own cursor.
public struct SessionIdentity: Sendable, Equatable {
    public let id: String
    public var agentKind: AgentKind
    public var source: AgentSource
    public var createdAt: Date
    public var agentName: String?
}

public struct TurnState: Sendable, Equatable {
    public var state: AgentState = .registered
    public var stateSince: Date = .distantPast
    public var turnStartedAt: Date? = nil
    public var turnEndedAt: Date? = nil
    public var codexTurnID: String? = nil
    public var codexTurnResult: CodexTurnResult? = nil
    public var antigravityTurnResult: CodexTurnResult? = nil
    public var opencodeTurnResult: CodexTurnResult? = nil
    public var piTurnResult: CodexTurnResult? = nil
    public var opencodeTurnID: String? = nil
}

public struct AttentionState: Sendable, Equatable {
    public var pendingApproval: PendingApproval? = nil
    public var humanRequests: [HumanRequest]? = nil
    public var humanResolvedAt: [String: Date]? = nil
}

public struct ReceiptState: Sendable, Equatable {
    public var notificationVersion: Int = 0
    public var readThroughVersion: Int = 0
    public var readAt: Date? = nil
    public var interactionGeneration: Int? = nil
    public var displayRevision: Int? = nil
    public var readDisplayRevision: Int? = nil
}

public struct HostContext: Sendable, Equatable {
    public var dshTUI: Bool? = nil
    public var terminalProgram: String? = nil
    public var terminalTTY: String? = nil
    public var terminalFocusURL: String? = nil
    public var aionUiConversation: AionUiConversation? = nil
    /// Last successful live verification of `aionUiConversation`, if any.
    public var aionUiVerification: AionUiVerification? = nil
    /// Exact native-session ↔ AO-session binding from the supervised agent's
    /// environment. Persisted history; never a current role by itself.
    public var aoBinding: AOBinding? = nil
    /// Last AO host observation for this session. Cleared when the daemon
    /// generation changes or a newer native generation supersedes this binding.
    public var aoObservation: AOHostObservation? = nil
}

public struct CodexSourceContext: Sendable, Equatable {
    public var codexHome: String? = nil
    public var codexDesktop: Bool = false
    public var codexLifecycleAt: Date? = nil
    /// A positively identified native internal purpose, never inferred from model or silence.
    public var codexInternalTaskKind: String? = nil
    /// Diagnostic process exit evidence; it does not establish a turn result.
    public var codexInternalTaskExitedAt: Date? = nil
    /// Observation of a positively identified disposable title client or
    /// unpersisted Desktop side conversation (identity, not an activity timer).
    /// It is an observation time, not a native turn end or process exit.
    public var codexInternalTaskObservedAt: Date? = nil
    /// Exact unpersisted Desktop source retained across diagnostic rotation.
    /// A live/unknown owner remains a visible candidate, not an internal task.
    public var codexTransientSource: CodexInternalTaskEvidence.DesktopSource? = nil
    /// Positive exact-ID native thread evidence outranks diagnostic fallback.
    public var codexHasNativeThreadRecord: Bool? = nil
}

public struct AntigravitySourceContext: Sendable, Equatable {
    public var antigravityFromDSH: Bool? = nil
    public var antigravityEventAt: Date? = nil
    public var antigravityStepFloor: Int? = nil
}

public struct OpencodeSourceContext: Sendable, Equatable {
    public var parentSessionID: String? = nil
    public var opencodeEventAt: Date? = nil
    public var opencodeNavigationSocket: String? = nil
    public var opencodeProcessID: Int32? = nil
    public var opencodeProcessStartedAt: Date? = nil
    public var opencodeLastSeenAt: Date? = nil
    public var opencodeCheckpointAt: Date? = nil
    public var opencodeDisconnectedAt: Date? = nil
}

public struct DSHSourceContext: Sendable, Equatable {
    public var dsh: DSHObservation? = nil
    public var dshLastSeenAt: Date? = nil
    public var dshDisconnectedAt: Date? = nil
}
