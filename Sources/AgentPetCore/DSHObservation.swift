import Foundation

/// Full metadata snapshot from the versioned DSH bridge. No user answers or
/// model prose are needed to establish task and human-interaction state.
public struct DSHObservation: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case idle, working, done }
    public enum Result: String, Codable, Sendable { case completed, cancelled, failed, unknown }
    public struct Pending: Codable, Sendable, Equatable {
        public var id: String
        public var kind: HumanRequest.Kind
        public init(id: String, kind: HumanRequest.Kind) { self.id = id; self.kind = kind }
    }
    public var schema: Int
    public var profileID: String
    public var hostID: String
    public var hostStartedAt: Date
    public var nativeSessionID: String
    public var revision: Int
    public var nativeSeq: Int
    public var turn: Int?
    public var phase: Phase
    public var result: Result?
    public var pending: [Pending]
    public var startedAt: Date?
    public var endedAt: Date?
    public var baseline: Bool
    public var heartbeat: Bool
    public var gap: Bool
    public var navigationSocket: String?

    public var sessionKey: String { "dsh:\(profileID):\(nativeSessionID)" }
    public var taskResult: CodexTurnResult? {
        switch result {
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .failed: return .failed
        default: return nil
        }
    }
    public var valid: Bool {
        schema == 1 && profileID.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil &&
        UUID(uuidString: hostID) != nil && Self.validID(nativeSessionID) && revision > 0 && nativeSeq >= 0 &&
        (turn == nil || turn! >= 0) && pending.count <= 64 && Set(pending.map(\.id)).count == pending.count &&
        pending.allSatisfy { Self.validID($0.id) } &&
        (phase != .working || (turn != nil && result == nil && startedAt != nil && endedAt == nil)) &&
        (phase != .done || (turn != nil && result != nil && endedAt != nil)) &&
        (startedAt == nil || endedAt == nil || startedAt! <= endedAt!) &&
        hostStartedAt.timeIntervalSince1970.isFinite &&
        (navigationSocket == nil || Self.validSocket(navigationSocket!))
    }
    public static func validID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_.:-]{1,160}$", options: .regularExpression) != nil
    }
    public static func validSocket(_ path: String) -> Bool {
        path.range(of: "^/tmp/agentpet-dsh-[0-9]+/h-[A-Za-z0-9]+/nav\\.sock$", options: .regularExpression) != nil && path.utf8.count < 100
    }
}

/// Pure DSH reduction kept separate from legacy Hook transitions.
public enum DSHSessionReducer {
    public static func apply(_ event: AgentEvent, previous: AgentSession?, now: Date) -> AgentSession? {
        guard event.agentKind == .dsh, event.eventName == "dsh/observation", let observation = event.dsh,
              observation.valid, event.sessionId == observation.sessionKey,
              observation.hostStartedAt <= event.timestamp, event.timestamp <= now.addingTimeInterval(5),
              previous == nil || previous?.agentKind == .dsh else { return nil }
        if let old = previous?.dsh {
            if old.hostID == observation.hostID {
                guard observation.revision > old.revision else { return nil }
            } else { guard observation.hostStartedAt > old.hostStartedAt else { return nil } }
            if let turn = old.turn, let incoming = observation.turn, incoming < turn { return nil }
            if old.turn == observation.turn && old.result == .cancelled && observation.result != .cancelled { return nil }
        }
        // Merely loading old completed history cannot create a new unread card.
        if previous == nil && observation.baseline && observation.phase != .working && observation.pending.isEmpty { return nil }
        if observation.turn == nil && observation.pending.isEmpty { return nil }
        var session = previous ?? AgentSession(id: event.sessionId, agentKind: .dsh,
            state: .working, source: .hook, updatedAt: event.timestamp)
        let newTurn = previous?.dsh?.turn != observation.turn
        let newHost = previous?.dsh?.hostID != observation.hostID
        if newTurn {
            session.readThroughVersion = session.notificationVersion
            session.readAt = nil
            session.interactionGeneration = (session.interactionGeneration ?? 0) + 1
        } else if newHost {
            // Invalidate any navigation callback still in the previous Host.
            session.interactionGeneration = (session.interactionGeneration ?? 0) + 1
        }
        let pending = observation.pending.map { item in
            (previous?.humanRequests ?? []).first { $0.id == item.id && $0.kind == item.kind } ??
                HumanRequest(id: item.id, kind: item.kind, createdAt: event.timestamp)
        }
        // Quietly hidden terminal cards must not become fresh completions on
        // every heartbeat or Host restart. Still reconcile a missed result or
        // a genuinely new turn/pending request normally.
        let sameHiddenResult = session.state == .idle && session.dshDisconnectedAt == nil &&
            !newTurn && pending.isEmpty && observation.phase == .done &&
            session.dsh?.phase == .done && session.dsh?.result == observation.result &&
            session.dsh?.startedAt == observation.startedAt && session.dsh?.endedAt == observation.endedAt
        let state: AgentState = sameHiddenResult ? .idle :
            (pending.isEmpty ? (observation.phase == .done ? .done : .working) : .waiting)
        let message: String
        if let waiting = pending.last { message = waiting.message }
        else if state == .done || sameHiddenResult {
            switch observation.result {
            case .completed: message = "本轮已完成"
            case .cancelled: message = "任务已停止"
            case .failed: message = "任务结束，发生错误"
            default: message = "任务结果未知"
            }
        } else { message = event.message ?? "正在处理任务" }
        let changed = newTurn || session.state != state || session.message != message ||
            session.humanRequests != pending || session.dsh?.result != observation.result
        if changed {
            session.displayRevision = (session.displayRevision ?? 0) + 1
            if state == .waiting || state == .done { session.notificationVersion += 1 }
            if session.state != state || newTurn { session.stateSince = event.timestamp }
            session.updatedAt = event.timestamp
        }
        session.dsh = observation
        session.dshLastSeenAt = event.timestamp
        session.dshDisconnectedAt = nil
        session.state = state
        session.message = message
        session.humanRequests = pending
        session.pendingApproval = nil // DSH decisions stay exclusively in DSH.
        session.turnStartedAt = observation.startedAt
        session.turnEndedAt = observation.endedAt
        if let title = safeLabel(event.title) { session.title = title }
        if let model = safeLabel(event.model) { session.model = model }
        if let project = safeLabel(event.project) { session.project = project }
        return session
    }
    private static func safeLabel(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return String(value.prefix(240))
    }
}
