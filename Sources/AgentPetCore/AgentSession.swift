import Foundation

/// A gated tool call awaiting the user's allow/deny decision.
public struct PendingApproval: Codable, Sendable, Equatable {
    public let requestId: String
    public let toolName: String
    public let summary: String

    public init(requestId: String, toolName: String, summary: String) {
        self.requestId = requestId
        self.toolName = toolName
        self.summary = summary
    }
}

/// Current known state of one agent session.
public struct AgentSession: Codable, Identifiable, Sendable, Equatable {
    public var identity: SessionIdentity
    public var turn = TurnState()
    public var attention = AttentionState()
    public var receipt = ReceiptState()
    public var hostContext = HostContext()
    public var dshTUI: Bool? {
        get { hostContext.dshTUI }
        set { hostContext.dshTUI = newValue }
    }
    public var isDSHTUI: Bool { dshTUI == true }
    /// Runtime-only projection of independently persisted AO source receipts.
    /// Exactly one display row carries each receipt; it never alters native versions.
    public var aoAttentionReceipts: [AOAttentionReceipt]? = nil
    public var hasAOUnread: Bool { aoAttentionReceipts?.contains(where: \.hasUnread) == true }
    public var codexContext = CodexSourceContext()
    public var antigravityContext = AntigravitySourceContext()
    public var opencodeContext = OpencodeSourceContext()
    /// Native Session.parentID, distinct from an assistant message's parentID.
    public var opencodeParentSessionID: String? {
        get { opencodeContext.parentSessionID }
        set { opencodeContext.parentSessionID = newValue }
    }
    public var isOpencodeSubagent: Bool {
        agentKind == .opencode && opencodeParentSessionID.map {
            $0 != id && OpencodeHookPayload.validSessionID($0)
        } == true
    }
    public var dshContext = DSHSourceContext()

    public var id: String {
        get { identity.id }
    }
    public var agentKind: AgentKind {
        get { identity.agentKind }
        set { identity.agentKind = newValue }
    }
    public var project: String?
    /// Human-readable conversation title (e.g. Claude Code's summary, or first
    /// user message). Populated lazily from the transcript when available.
    public var title: String?
    public var state: AgentState {
        get { turn.state }
        set { turn.state = newValue }
    }
    public var message: String?
    /// Display name of the LLM model in use (e.g. "Sonnet 4.6"), if any hook
    /// event for this session reported one. Sticky: once set, persists across
    /// later events that omit it.
    public var model: String?
    public var source: AgentSource {
        get { identity.source }
        set { identity.source = newValue }
    }
    public var updatedAt: Date
    /// When the session entered its current `state`; resets on state change.
    public var stateSince: Date {
        get { turn.stateSince }
        set { turn.stateSince = newValue }
    }
    /// When the session was first created (first `apply` event).
    public var createdAt: Date {
        get { identity.createdAt }
        set { identity.createdAt = newValue }
    }
    /// Gated tool call currently awaiting the user's decision, if any.
    public var pendingApproval: PendingApproval? {
        get { attention.pendingApproval }
        set { attention.pendingApproval = newValue }
    }
    /// `TERM_PROGRAM` of the terminal running this session. Sticky. Enables the
    /// click-to-focus affordance on the bubble row.
    public var terminalProgram: String? {
        get { hostContext.terminalProgram }
        set { hostContext.terminalProgram = newValue }
    }
    /// Controlling TTY of the terminal running this session (e.g.
    /// `"/dev/ttys003"`). Sticky. Used to target the exact window/tab.
    public var terminalTTY: String? {
        get { hostContext.terminalTTY }
        set { hostContext.terminalTTY = newValue }
    }
    /// Deep link that focuses the exact tab/pane (Warp). Sticky.
    public var terminalFocusURL: String? {
        get { hostContext.terminalFocusURL }
        set { hostContext.terminalFocusURL = newValue }
    }
    /// Exact GUI host binding; it takes precedence over inherited terminal variables.
    public var aionUiConversation: AionUiConversation? {
        get { hostContext.aionUiConversation }
        set { hostContext.aionUiConversation = newValue }
    }
    public var validAionUiConversation: AionUiConversation? {
        guard let target = aionUiConversation, target.nativeSessionID == id,
              target.agentKind == agentKind, target.url != nil else { return nil }
        return target
    }
    /// A Team-scoped association: the stored mark is present and the
    /// native/kind/route identity checks pass. Verification against the live
    /// teams table is deliberately excluded here so a known Team member never
    /// degrades into an independent clickable row while the check is pending
    /// or temporarily unavailable.
    public var aionUiTeamScope: AionUiConversation? {
        guard let target = validAionUiConversation, target.teamID != nil, target.teamURL != nil else { return nil }
        return target
    }
    /// A Team association confirmed against the live teams table (role known).
    public var validAionUiTeam: AionUiConversation? {
        guard let target = aionUiTeamScope, target.teamRole != nil else { return nil }
        return target
    }
    /// Last successful live verification, if any. Persisted for history;
    /// presentation decides currency from its time and identity.
    public var aionUiVerification: AionUiVerification? {
        get { hostContext.aionUiVerification }
        set { hostContext.aionUiVerification = newValue }
    }
    /// The stored verification, only while it still attests this exact session
    /// instance, conversation, Team and role. A recreated session (same id,
    /// other createdAt), a replaced conversation or a changed role fails here,
    /// so an older check can never be inherited.
    public var attestableAionUiVerification: AionUiVerification? {
        guard let verification = aionUiVerification, let scope = aionUiTeamScope,
              verification.sessionCreatedAt == createdAt,
              verification.conversationID == scope.id,
              verification.teamID == scope.teamID,
              verification.teamRole == scope.teamRole,
              verification.teamRole != nil else { return nil }
        return verification
    }
    /// Exact AO host binding captured from the supervised agent's environment
    /// or created for an AO-only placeholder row.
    public var aoBinding: AOBinding? {
        get { hostContext.aoBinding }
        set { hostContext.aoBinding = newValue }
    }
    public var aoObservation: AOHostObservation? {
        get { hostContext.aoObservation }
        set { hostContext.aoObservation = newValue }
    }
    public var isAOHostSession: Bool { aoBinding != nil || aoObservation != nil }
    /// A row that exists only because AO reports the session; it has no native
    /// hook row yet and is replaced as soon as an exact binding arrives.
    public var isAOPlaceholder: Bool { aoBinding?.origin == .hostObservation }
    /// A stale or superseded AO observation is history, not current evidence.
    public func aoObservationIsCurrent(at now: Date, window: TimeInterval = 60) -> Bool {
        guard let observation = aoObservation, observation.available,
              aoBinding?.isCurrent == true,
              aoBinding?.sessionID == observation.sessionID,
              now.timeIntervalSince(observation.observedAt) >= 0,
              now.timeIntervalSince(observation.observedAt) <= window else { return false }
        return true
    }
    /// The AO adapter supplies an exact project display scope. A project's
    /// orchestrators and workers share one summary without claiming ancestry.
    /// Unavailable observations keep the project label, but no current role.
    public var aoTeamScope: HostTeamScope? {
        guard let observation = aoObservation, let orchestration = observation.orchestration,
              orchestration.valid,
              let binding = aoBinding, binding.isCurrent,
              binding.sessionID == observation.sessionID,
              binding.projectID == nil || binding.projectID == observation.projectID else { return nil }
        let role: HostTeamRole? = observation.available && !observation.isExited
            ? (orchestration.role == .lead ? .lead : .teammate) : nil
        return HostTeamScope(host: .agentOrchestrator, teamID: orchestration.teamID,
                             teamName: orchestration.teamName, role: role,
                             verifiedAt: observation.available ? observation.observedAt : nil,
                             instanceID: observation.instanceID)
    }
    /// One minimal host-neutral Team scope shared by the existing AionUI
    /// presentation and AO's verified project scope. AO is preferred
    /// when a native session is genuinely present in both hosts: AO is the
    /// current host context, while the native source identity is unchanged.
    public var hostTeamScope: HostTeamScope? {
        if let ao = aoTeamScope { return ao }
        if let aion = aionUiTeamScope, let teamID = aion.teamID {
            let role = validAionUiTeam?.teamRole.map {
                $0 == .lead ? HostTeamRole.lead : HostTeamRole.teammate
            }
            return HostTeamScope(host: .aionUI, teamID: teamID,
                                 teamName: aion.teamName ?? "AionUI Team", role: role,
                                 verifiedAt: attestableAionUiVerification?.verifiedAt)
        }
        return nil
    }
    /// Raw agent name for a custom (`.unknown`) agent; `nil` for known kinds.
    /// Sticky. Keeps distinct custom agents from merging and drives their
    /// bubble icon (issue #56).
    public var agentName: String? {
        get { identity.agentName }
        set { identity.agentName = newValue }
    }
    public var codexHome: String? {
        get { codexContext.codexHome }
        set { codexContext.codexHome = newValue }
    }
    public var codexDesktop: Bool {
        get { codexContext.codexDesktop }
        set { codexContext.codexDesktop = newValue }
    }
    public var codexInternalTaskKind: String? {
        get { codexContext.codexInternalTaskKind }
        set { codexContext.codexInternalTaskKind = newValue }
    }
    public var codexInternalTaskExitedAt: Date? {
        get { codexContext.codexInternalTaskExitedAt }
        set { codexContext.codexInternalTaskExitedAt = newValue }
    }
    public var codexHasNativeThreadRecord: Bool? {
        get { codexContext.codexHasNativeThreadRecord }
        set { codexContext.codexHasNativeThreadRecord = newValue }
    }
    public var codexInternalTaskObservedAt: Date? {
        get { codexContext.codexInternalTaskObservedAt }
        set { codexContext.codexInternalTaskObservedAt = newValue }
    }
    public var codexTransientSource: CodexInternalTaskEvidence.DesktopSource? {
        get { codexContext.codexTransientSource }
        set { codexContext.codexTransientSource = newValue }
    }
    /// AO runs title generation with the project's selected harness, including
    /// OpenCode and Pi. The reserved scratch source is independent of harness.
    public var isAOBackgroundTask: Bool {
        // AO's unpublished scratch calls can leave a native thread/title cache
        // after the ephemeral provider thread has gone. Preserve all receipts
        // and stored lifecycle data; exclude only the reserved background source
        // without an interactive route or an outstanding human obligation.
        if CodexHookOrigin.isAOBackgroundWorkspace(project),
           !codexDesktop, terminalProgram == nil, terminalTTY == nil,
           terminalFocusURL == nil, validAionUiConversation == nil,
           opencodeNavigationSocket == nil,
           !isAOHostSession, pendingApproval == nil, (humanRequests ?? []).isEmpty {
            // A DSH bridge socket belongs to the observing Host, including ACP
            // Hosts without a desktop Client. It cannot turn AO's unpublished
            // scratch call into an interactive task. Formal AO ownership and
            // explicit human obligations above still protect real sessions.
            return true
        }
        return false
    }
    public var isCodexInternalTask: Bool {
        // Existing task/message/notification exclusion uses this shared gate.
        if isAOBackgroundTask { return true }
        if codexInternalTaskKind == "desktopSideConversation" {
            // A positively identified unpersisted Desktop fork stays hidden
            // across turns. Saving it as a native thread clears this evidence.
            guard agentKind == .codex, title == nil, codexHasNativeThreadRecord != true,
                  let observed = codexInternalTaskObservedAt, observed.timeIntervalSince1970.isFinite,
                  createdAt <= observed, !codexDesktop, !isAOHostSession,
                  terminalProgram == nil, terminalTTY == nil, terminalFocusURL == nil,
                  validAionUiConversation == nil else { return false }
            return true
        }
        let through: Date?
        switch codexInternalTaskKind {
        case "projectSuggestions", "desktopTransient": through = codexInternalTaskExitedAt
        case "aionUiTitle": through = codexInternalTaskObservedAt
        case "desktopProcessExited":
            guard !isAOHostSession, let observed = codexInternalTaskObservedAt,
                  createdAt <= observed,
                  let source = codexTransientSource, let home = codexHome,
                  source.isValid(sessionID: id, home: home, at: observed) else { return false }
            through = observed
        default: return false
        }
        guard agentKind == .codex, title == nil,
              codexHasNativeThreadRecord != true,
              let through, through.timeIntervalSince1970.isFinite,
              updatedAt <= through, !codexDesktop,
              terminalProgram == nil, terminalTTY == nil, terminalFocusURL == nil,
              validAionUiConversation == nil, pendingApproval == nil,
              (humanRequests ?? []).isEmpty else { return false }
        return true
    }
    public var notificationVersion: Int {
        get { receipt.notificationVersion }
        set { receipt.notificationVersion = newValue }
    }
    public var readThroughVersion: Int {
        get { receipt.readThroughVersion }
        set { receipt.readThroughVersion = newValue }
    }
    public var turnStartedAt: Date? {
        get { turn.turnStartedAt }
        set { turn.turnStartedAt = newValue }
    }
    public var turnEndedAt: Date? {
        get { turn.turnEndedAt }
        set { turn.turnEndedAt = newValue }
    }
    public var codexTurnID: String? {
        get { turn.codexTurnID }
        set { turn.codexTurnID = newValue }
    }
    public var codexLifecycleAt: Date? {
        get { codexContext.codexLifecycleAt }
        set { codexContext.codexLifecycleAt = newValue }
    }
    public var codexTurnResult: CodexTurnResult? {
        get { turn.codexTurnResult }
        set { turn.codexTurnResult = newValue }
    }
    public var antigravityTurnResult: CodexTurnResult? {
        get { turn.antigravityTurnResult }
        set { turn.antigravityTurnResult = newValue }
    }
    /// Native hook order is independent of later read-only UI observations.
    public var antigravityFromDSH: Bool? {
        get { antigravityContext.antigravityFromDSH }
        set { antigravityContext.antigravityFromDSH = newValue }
    }
    public var isDSHBackend: Bool { agentKind == .antigravity && antigravityFromDSH == true }

    public var antigravityEventAt: Date? {
        get { antigravityContext.antigravityEventAt }
        set { antigravityContext.antigravityEventAt = newValue }
    }
    /// Optional native step boundary, independent of Hook delivery latency.
    public var antigravityStepFloor: Int? {
        get { antigravityContext.antigravityStepFloor }
        set { antigravityContext.antigravityStepFloor = newValue }
    }
    public var opencodeTurnResult: CodexTurnResult? {
        get { turn.opencodeTurnResult }
        set { turn.opencodeTurnResult = newValue }
    }
    public var piTurnResult: CodexTurnResult? {
        get { turn.piTurnResult }
        set { turn.piTurnResult = newValue }
    }
    public var opencodeTurnID: String? {
        get { turn.opencodeTurnID }
        set { turn.opencodeTurnID = newValue }
    }
    public var opencodeEventAt: Date? {
        get { opencodeContext.opencodeEventAt }
        set { opencodeContext.opencodeEventAt = newValue }
    }
    public var opencodeNavigationSocket: String? {
        get { opencodeContext.opencodeNavigationSocket }
        set { opencodeContext.opencodeNavigationSocket = newValue }
    }
    public var opencodeProcessID: Int32? {
        get { opencodeContext.opencodeProcessID }
        set { opencodeContext.opencodeProcessID = newValue }
    }
    public var opencodeProcessStartedAt: Date? {
        get { opencodeContext.opencodeProcessStartedAt }
        set { opencodeContext.opencodeProcessStartedAt = newValue }
    }
    /// Liveness does not change the activity revision, reading or turn clock.
    public var opencodeLastSeenAt: Date? {
        get { opencodeContext.opencodeLastSeenAt }
        set { opencodeContext.opencodeLastSeenAt = newValue }
    }
    public var opencodeCheckpointAt: Date? {
        get { opencodeContext.opencodeCheckpointAt }
        set { opencodeContext.opencodeCheckpointAt = newValue }
    }
    /// Losing the owning process does not prove success, failure or cancellation.
    public var opencodeDisconnectedAt: Date? {
        get { opencodeContext.opencodeDisconnectedAt }
        set { opencodeContext.opencodeDisconnectedAt = newValue }
    }
    /// Optional additions keep existing v1 snapshots readable.
    public var humanRequests: [HumanRequest]? {
        get { attention.humanRequests }
        set { attention.humanRequests = newValue }
    }
    public var humanResolvedAt: [String: Date]? {
        get { attention.humanResolvedAt }
        set { attention.humanResolvedAt = newValue }
    }
    public var dsh: DSHObservation? {
        get { dshContext.dsh }
        set { dshContext.dsh = newValue }
    }
    public var dshLastSeenAt: Date? {
        get { dshContext.dshLastSeenAt }
        set { dshContext.dshLastSeenAt = newValue }
    }
    public var dshDisconnectedAt: Date? {
        get { dshContext.dshDisconnectedAt }
        set { dshContext.dshDisconnectedAt = newValue }
    }
    public var taskResult: CodexTurnResult? {
        switch agentKind {
        case .dsh: return dshDisconnectedAt == nil ? dsh?.taskResult : nil
        case .antigravity: return antigravityTurnResult
        case .opencode: return opencodeTurnResult
        case .pi: return piTurnResult
        default: return codexTurnResult
        }
    }
    /// Local acknowledgement of an explicit click that opened this turn.
    /// Optional fields keep existing v1 snapshots readable.
    public var readAt: Date? {
        get { receipt.readAt }
        set { receipt.readAt = newValue }
    }
    public var interactionGeneration: Int? {
        get { receipt.interactionGeneration }
        set { receipt.interactionGeneration = newValue }
    }
    /// Revision of the displayed activity, separate from unread notifications.
    public var displayRevision: Int? {
        get { receipt.displayRevision }
        set { receipt.displayRevision = newValue }
    }
    public var readDisplayRevision: Int? {
        get { receipt.readDisplayRevision }
        set { receipt.readDisplayRevision = newValue }
    }
    /// An explicit native user cancellation is already acknowledged by that
    /// action. This does not manufacture a successful navigation receipt.
    public var isStopped: Bool { (state == .done || state == .idle) && taskResult == .cancelled }
    /// A bare completion Hook without a known native conversation cannot be
    /// opened or acknowledged from the bubble. Keep its stored evidence, but
    /// exclude it from presentation until metadata identifies the conversation.
    public var isUnidentifiedCodexCompletion: Bool {
        agentKind == .codex && state == .done && title == nil &&
            !codexDesktop && terminalProgram == nil && validAionUiConversation == nil &&
            codexTurnID == nil && codexTurnResult == nil &&
            (humanRequests ?? []).isEmpty
    }
    public var hasUnread: Bool {
        if isAOPlaceholder, let receipts = aoAttentionReceipts { return receipts.contains(where: \.hasUnread) }
        return hasAOUnread || (!isStopped && notificationVersion > readThroughVersion)
    }
    public var hasReadReceipt: Bool {
        guard !hasUnread else { return false }
        let terminal = state == .done || state == .idle
        if let readDisplayRevision, readAt != nil {
            return readDisplayRevision == (displayRevision ?? 0)
        }
        // Earlier snapshots have no activity revision: retain completed reads,
        // but never extend an old click to a currently running activity.
        return terminal && (readAt != nil || readThroughVersion > 0)
    }

    public enum Indicator: String, Sendable { case running, attention, unread, read, idle }
    public var indicator: Indicator {
        if isStopped { return .read }
        // Reading a running activity does not end the task. Keep its receipt,
        // but let the native task state retain the blue working indicator.
        if state == .working || state == .registered { return .running }
        if hasReadReceipt { return .read }
        if state == .waiting { return .attention }
        if hasUnread { return .unread }
        switch state {
        case .working, .registered: return .running
        case .waiting: return .attention
        case .done: return .unread
        case .idle: return .idle
        }
    }

    /// Grouping/identity key for the bubble. Known kinds group by kind; custom
    /// (`.unknown`) agents group by their raw name so two different custom
    /// agents don't collapse into one row (issue #56).
    public var groupKey: String {
        agentKind == .unknown ? "unknown:\(agentName?.lowercased() ?? "")" : agentKind.rawValue
    }

    public init(
        id: String,
        agentKind: AgentKind,
        project: String? = nil,
        title: String? = nil,
        state: AgentState,
        message: String? = nil,
        model: String? = nil,
        source: AgentSource,
        updatedAt: Date,
        stateSince: Date? = nil,
        createdAt: Date? = nil,
        pendingApproval: PendingApproval? = nil,
        terminalProgram: String? = nil,
        terminalTTY: String? = nil,
        terminalFocusURL: String? = nil,
        agentName: String? = nil
    ) {
        self.identity = SessionIdentity(id: id, agentKind: agentKind, source: source, createdAt: createdAt ?? updatedAt, agentName: agentName)
        self.updatedAt = updatedAt
        self.agentKind = agentKind
        self.project = project
        self.title = title
        self.state = state
        self.message = message
        self.model = model
        self.source = source
        self.stateSince = stateSince ?? updatedAt
        self.createdAt = createdAt ?? updatedAt
        self.pendingApproval = pendingApproval
        self.terminalProgram = terminalProgram
        self.terminalTTY = terminalTTY
        self.terminalFocusURL = terminalFocusURL
        self.agentName = agentName
    }

    public init(from decoder: Decoder) throws {
        self = try AgentSessionDTO(from: decoder).session
    }

    public func encode(to encoder: Encoder) throws {
        try AgentSessionDTO(self).encode(to: encoder)
    }

}
