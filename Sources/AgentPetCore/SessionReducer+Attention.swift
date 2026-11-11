import Foundation

/// Pure attention transitions; caller supplies evidence and clocks.
extension SessionReducer {
    public func markRead(id: String, through version: Int) {
        guard var session = byID[id] else { return }
        if session.isAOPlaceholder {
            // This legacy API's version belongs to the AO-only source. A bound
            // native row always keeps this operation native-only.
            for receipt in session.aoAttentionReceipts ?? [] {
                var clicked = receipt
                clicked.version = min(version, receipt.version)
                _ = acknowledgeAO(clicked, at: receipt.observation.observedAt)
            }
            session.readThroughVersion = max(session.readThroughVersion, min(version, session.notificationVersion))
            byID[id] = session
            persistCodexSessions()
            return
        }
        session.readThroughVersion = max(session.readThroughVersion, min(version, session.notificationVersion))
        byID[id] = session
        persistCodexSessions()
    }

    /// A navigation callback acknowledges only the clicked turn and message
    /// version. It cannot clear a newer completion or a newly submitted turn.
    @discardableResult
    public func markOpened(_ clicked: AgentSession, at: Date) -> Bool {
        guard var current = byID[clicked.id], current.createdAt == clicked.createdAt,
              (current.interactionGeneration ?? 0) == (clicked.interactionGeneration ?? 0) else { return false }
        current.readThroughVersion = max(current.readThroughVersion, min(clicked.notificationVersion, current.notificationVersion))
        current.readAt = at
        current.readDisplayRevision = clicked.displayRevision ?? 0
        byID[current.id] = current
        persistCodexSessions()
        return true
    }

    /// Exact request IDs isolate parallel prompts and protect later messages from
    /// old replies. Read acknowledgements never remove an outstanding request.
    func applyHumanIntervention(_ event: AgentEvent) -> AgentSession? {
        guard let change = event.humanIntervention, !change.requests.isEmpty,
              change.requests.count <= 64, change.requests.allSatisfy({ HumanIntervention.validID($0.id) }) else { return nil }
        let previous = byID[event.sessionId]
        if let previous {
            guard previous.agentKind == event.agentKind else { return nil }
            if event.agentKind == .opencode, let incoming = event.opencodeTurnID, let bound = previous.opencodeTurnID,
               incoming != bound { return nil }
        } else if change.action == .resolved { return nil }
        var session = previous ?? AgentSession(id: event.sessionId, agentKind: event.agentKind,
            project: event.project, state: .working, source: .hook, updatedAt: event.timestamp)
        if event.agentKind == .antigravity, session.antigravityEventAt == nil {
            session.antigravityEventAt = previous?.updatedAt ?? .distantPast
        }
        if previous == nil { session.turnStartedAt = event.timestamp }
        var requests = session.humanRequests ?? []
        var resolved = session.humanResolvedAt ?? [:]
        var changed = false
        if let requestID = event.approvalRequestId {
            session.pendingApproval = PendingApproval(requestId: requestID, toolName: event.toolName ?? "", summary: event.toolSummary ?? "")
        }
        switch change.action {
        case .asked:
            guard session.taskResult != .cancelled && session.taskResult != .failed,
                  session.opencodeDisconnectedAt == nil else { return nil }
            for request in change.requests {
                guard !requests.contains(where: { $0.id == request.id }),
                      (resolved[request.id] ?? .distantPast) < request.createdAt,
                      request.createdAt >= (session.turnStartedAt ?? .distantPast), requests.count < 64 else { continue }
                requests.append(request); changed = true
            }
            guard changed else { return nil }
            session.state = .waiting
            session.notificationVersion += 1
            session.displayRevision = (session.displayRevision ?? 0) + 1
        case .resolved:
            for request in change.requests {
                resolved[request.id] = max(resolved[request.id] ?? .distantPast, event.timestamp)
                if let index = requests.firstIndex(where: { $0.id == request.id && $0.createdAt <= event.timestamp }) {
                    requests.remove(at: index); changed = true
                }
            }
            if changed && requests.isEmpty {
                session.state = session.turnEndedAt == nil ? .working : .done
                session.message = session.state == .working ? "正在处理任务" : "本轮已完成"
                session.displayRevision = (session.displayRevision ?? 0) + 1
                if session.state == .done { session.notificationVersion += 1 }
            }
        }
        if !requests.isEmpty { session.message = requests.last?.message; session.state = .waiting }
        if session.state != previous?.state || (change.action == .resolved && changed && requests.isEmpty) { session.stateSince = event.timestamp }
        session.humanRequests = requests
        session.humanResolvedAt = Dictionary(uniqueKeysWithValues: resolved.sorted { $0.value > $1.value }.prefix(128).map { ($0.key, $0.value) })
        session.updatedAt = max(session.updatedAt, event.timestamp)
        if let title = event.title { session.title = title }
        if let model = event.model { session.model = model }
        if let home = event.codexHome { session.codexHome = home }
        if let project = event.project { session.project = project }
        if let program = event.terminalProgram { session.terminalProgram = program }
        if let tty = event.terminalTTY { session.terminalTTY = tty }
        if let focusURL = event.terminalFocusURL { session.terminalFocusURL = focusURL }
        if let name = event.agentName { session.agentName = name }
        if event.agentKind == .opencode {
            if session.opencodeTurnID == nil { session.opencodeTurnID = event.opencodeTurnID }
            if let socket = event.opencodeNavigationSocket { session.opencodeNavigationSocket = socket }
            if session.opencodeProcessID == nil {
                session.opencodeProcessID = event.opencodeProcessID
                session.opencodeProcessStartedAt = event.opencodeProcessStartedAt
            }
            session.opencodeLastSeenAt = event.timestamp
            session.opencodeEventAt = max(session.opencodeEventAt ?? .distantPast, event.timestamp)
        }
        byID[event.sessionId] = session
        _ = attachPendingAOBinding(id: event.sessionId)
        persistCodexSessions()
        return changed ? (byID[event.sessionId] ?? session) : nil
    }

    func holdHumanRequests(_ session: inout AgentSession, previous: AgentSession?) {
        guard let requests = session.humanRequests, !requests.isEmpty,
              session.state == .working || session.state == .done || session.state == .idle else { return }
        if session.state == .done && (session.taskResult == .cancelled || session.taskResult == .failed || session.opencodeDisconnectedAt != nil) {
            session.humanResolvedAt = (session.humanResolvedAt ?? [:]).merging(Dictionary(uniqueKeysWithValues: requests.map { ($0.id, session.updatedAt) })) { max($0, $1) }
            session.humanResolvedAt = Dictionary(uniqueKeysWithValues: session.humanResolvedAt!.sorted { $0.value > $1.value }.prefix(128).map { ($0.key, $0.value) })
            session.humanRequests = []
            return
        }
        session.state = .waiting
        session.message = requests.last?.message
        if let previous {
            session.notificationVersion = previous.notificationVersion
            if previous.interactionGeneration == session.interactionGeneration {
                session.displayRevision = previous.displayRevision
                session.stateSince = previous.stateSince
            }
        }
    }

    /// Retires the display of an older Codex turn without answering native UI.
    /// Completed async questions remain visible until a genuine new turn starts.
    @discardableResult
    func supersedeCodexRequests(_ session: inout AgentSession, before boundary: Date) -> Bool {
        guard session.agentKind == .codex, let requests = session.humanRequests else { return false }
        let old = requests.filter { $0.createdAt < boundary }
        guard !old.isEmpty else { return false }
        session.humanRequests = requests.filter { $0.createdAt >= boundary }
        var retired = session.humanResolvedAt ?? [:]
        for request in old { retired[request.id] = max(retired[request.id] ?? .distantPast, boundary) }
        session.humanResolvedAt = Dictionary(uniqueKeysWithValues: retired.sorted { $0.value > $1.value }.prefix(128).map { ($0.key, $0.value) })
        if session.humanRequests?.isEmpty == true && session.state == .waiting && session.pendingApproval == nil {
            session.state = session.turnEndedAt == nil ? .working : .done
            session.message = session.state == .working ? "正在处理任务" : "本轮已完成"
            session.stateSince = boundary
            session.displayRevision = (session.displayRevision ?? 0) + 1
            if session.state == .working { session.readThroughVersion = session.notificationVersion }
            else { session.notificationVersion += 1 }
        }
        return true
    }

    /// Clears the pending approval for `id` and moves it to `.working`, but
    /// only if `requestId` matches; otherwise a no-op returning `false`.
    @discardableResult
    public func resolveApproval(id: String, requestId: String) -> Bool {
        guard var session = byID[id], session.pendingApproval?.requestId == requestId else { return false }
        let previous = session
        session.pendingApproval = nil
        session.state = .working
        session.displayRevision = (session.displayRevision ?? 0) + 1
        holdHumanRequests(&session, previous: previous)
        byID[id] = session
        persistCodexSessions()
        return true
    }
}
