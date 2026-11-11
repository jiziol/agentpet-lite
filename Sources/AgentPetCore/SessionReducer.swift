import Foundation

/// In-memory store of agent sessions.
///
/// Pure logic, deliberately not thread-safe and free of wall-clock reads:
/// callers pass `now` so behaviour is deterministic and testable. The daemon
/// confines all access to a single queue (see issue #3).
final class SessionReducer {
    /// `done` sessions fall back to `idle` after this much quiet time.
    public var doneToIdleAfter: TimeInterval
    /// `idle` sessions are removed after this much quiet time.
    public var removeIdleAfter: TimeInterval
    /// Working/waiting sessions with no update for this long are removed: the
    /// agent almost certainly died without a `Stop` event.
    public var staleActiveAfter: TimeInterval
    /// A merely `registered` session (agent open but never started working) is
    /// dropped sooner: it reappears as `working` the moment the agent does
    /// anything, so a quiet/abandoned one shouldn't linger as "running".
    public var staleRegisteredAfter: TimeInterval

    /// The live UI can retain acknowledged results indefinitely without changing
    /// their native lifecycle, unread version, or history format.
    public var preserveReadResults = false
    var archivingEnabled = false
    var effects: [SessionEffect] = []

    var legacySnapshotSessions: [AgentSession] = []
    var byID: [String: AgentSession] = [:]
    var dshSnapshotCheckpointAt: Date?
    /// Current AO daemon generation (run-file `appRunId`). A change always
    /// invalidates every cached AO role and removes AO-only placeholder rows.
    var aoInstanceID: String?
    /// Latest AO facts, keyed by exact AO session ID. Never persisted as
    /// current evidence; rebuilt from the daemon after every launch.
    var aoSessions: [String: AOHostObservation] = [:]
    /// Bindings that arrived before their native session row existed.
    var aoBindings: [String: AOBinding] = [:]
    var aoAttentionRecords: [String: AOAttentionReceipt] = [:]
    // Routing facts are Profile-wide; lifecycle facts remain per session.
    // A restarted Host need not load every old conversation to navigate to it.
    var dshEndpoints: [String: (observation: DSHObservation, seenAt: Date)] = [:]
    func restore(_ snapshot: SessionSnapshotDTO) {
        var migrated = false
        aoBindings.removeAll()
        aoAttentionRecords.removeAll()
        for var record in snapshot.aoAttentionRecords ?? [] where record.valid {
            // Older candidates also persisted never-waiting observations. Only
            // discard records with no waiting or acknowledgement evidence; age
            // and count never retire genuine unread or read source watermarks.
            if record.version == 0, record.waitingAt == nil, record.readAt == nil {
                migrated = true
                continue
            }
            record.observation.available = false
            record.observation.orchestration = nil
            aoAttentionRecords[record.id] = record
        }
        legacySnapshotSessions = snapshot.sessions.filter {
            RetiredAgentRegistry.ignores($0.agentKind, rawName: $0.agentName) && !$0.isAOPlaceholder
        }
        for var session in snapshot.sessions where !RetiredAgentRegistry.ignores(session.agentKind, rawName: session.agentName) {
            session.aoAttentionReceipts = nil
            // AO roles and placeholder rows are live host evidence. A relaunch
            // must wait for a fresh snapshot instead of inheriting a cached role.
            if session.isAOPlaceholder { migrated = true; continue }
            // A relaunch re-confirms host identity from live Hook evidence.
            // Do not carry a prior launch's claim or role as current.
            if session.aoBinding != nil || session.aoObservation != nil {
                session.aoBinding = nil
                session.aoObservation = nil
                migrated = true
            }
            // Earlier snapshots could carry questions from an older turn into
            // a newly started task. Repair only those provably older requests.
            if session.agentKind == .codex, let boundary = session.turnStartedAt,
               supersedeCodexRequests(&session, before: boundary) { migrated = true }
            byID[session.id] = session
        }
        aoInstanceID = nil
        aoSessions.removeAll()
        if migrated { persistCodexSessions() }
    }

    public func persistCodexSessions() {
        // Keep the original selection/save conditions and include legacy records.
        let sessions = byID.values.filter { SessionSnapshotDTO.includes($0) }
        effects.append(.saveSnapshot(SessionSnapshotDTO(sessions: Array(sessions) + legacySnapshotSessions,
            aoAttentionRecords: aoAttentionRecords.values.sorted { $0.id < $1.id })))
    }

    public init(doneToIdleAfter: TimeInterval = 30,
                removeIdleAfter: TimeInterval = 600,
                staleActiveAfter: TimeInterval = 300,
                staleRegisteredAfter: TimeInterval = 90) {
        self.doneToIdleAfter = doneToIdleAfter
        self.removeIdleAfter = removeIdleAfter
        self.staleActiveAfter = staleActiveAfter
        self.staleRegisteredAfter = staleRegisteredAfter
    }

    /// Removes all sessions (e.g. after the user disconnects an integration).
    public func clear() {
        byID.removeAll()
        dshEndpoints.removeAll()
        aoSessions.removeAll(); aoBindings.removeAll(); aoInstanceID = nil
        aoAttentionRecords.removeAll()
        persistCodexSessions()
    }

    /// Removes a single session (e.g. dismissing a stuck agent).
    public func remove(id: String) {
        byID.removeValue(forKey: id)
        aoBindings.removeValue(forKey: id)
        persistCodexSessions()
    }

    /// Applies an event, creating or updating the matching session.
    /// Returns the updated session, or `nil` if the event maps to no state.
    @discardableResult
    public func apply(_ event: AgentEvent, now: Date) -> AgentSession? {
        apply(HookSourceAdapter().observe(event, at: now))
    }

    /// Standard internal entry; keep channel-specific fences in the existing reducers.
    @discardableResult
    public func apply(_ observation: SessionObservation) -> AgentSession? {
        switch observation.payload {
        case .hook(let event):
            let previous = byID[event.sessionId]
            guard var session = applyHook(event, now: observation.observedAt) else { return nil }
            if let hosted = event.dshTUI, event.timestamp >= (previous?.updatedAt ?? .distantPast) {
                let startsInvocation = event.antigravityNewInvocation == true ||
                    ["UserPromptSubmit", "UserPromptSubmitted", "beforeSubmitPrompt", "pre_user_prompt",
                     "user_prompt_submit", "userPromptSubmit", "agent_start", "turn_start", "BeforeAgent"].contains(event.eventName)
                // Positive ancestry can classify the current invocation at any
                // Hook. A detached/unknown later Hook cannot erase it; a fresh
                // independently launched prompt can restore ordinary visibility.
                if hosted || startsInvocation || previous == nil {
                    session.dshTUI = hosted
                    byID[session.id] = session
                    if session.dshTUI != previous?.dshTUI { persistCodexSessions() }
                }
            }
            return session
        case .codexLifecycle(let id, let event): return reconcileCodexLifecycle(id: id, event: event)
        case .antigravitySQLite(let id, let evidence): return reconcileAntigravityCancellation(id: id, cancellation: evidence)
        case .antigravityLog(let evidence): return reconcileAntigravityCancellationSignal(evidence, observedAt: observation.observedAt)
        case .aionUiCancellation(let evidence): return reconcileAionUiCancellation(evidence, observedAt: observation.observedAt)
        }
    }

    public var sessions: [AgentSession] {
        Array(byID.values)
    }

    /// Sessions ordered by attention priority then recency, for display.
    public var sorted: [AgentSession] {
        byID.values.filter { !$0.isOpencodeSubagent && !$0.isDSHBackend }.sorted { lhs, rhs in
            let lp = lhs.state.attentionPriority
            let rp = rhs.state.attentionPriority
            if lp != rp { return lp > rp }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public func session(id: String) -> AgentSession? {
        byID[id]
    }
}

extension AgentState {
    /// Higher means more deserving of the user's attention.
    var attentionPriority: Int {
        switch self {
        case .working: return 4
        case .waiting: return 5
        case .done: return 2
        case .registered: return 1
        case .idle: return 0
        }
    }
}
