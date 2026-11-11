import Foundation

/// Pure pruning transitions; caller supplies evidence and clocks.
extension SessionReducer {
    /// Only a definitively missing owning process ends an active card. The
    /// native result remains unknown; a subsequently delivered done can correct it.
    @discardableResult
    func reconcileOpencodeLiveness(now: Date, receipts: [LivenessEffectReceipt]) -> [AgentSession] {
        var disconnected: [AgentSession] = []
        for (id, var session) in byID where session.agentKind == .opencode &&
            (session.state == .working || session.state == .waiting) {
            guard session.opencodeProcessID != nil else { continue }
            guard let receipt = receipts.first(where: { $0.expected == session }) else { continue }
            let observation = receipt.observation
            let alive = observation.alive
            let reusedPID: Bool
            if alive == true, let expected = session.opencodeProcessStartedAt,
               let actual = observation.startedAt {
                reusedPID = abs(actual.timeIntervalSince(expected)) > 0.001
            } else { reusedPID = false }
            guard alive == false || reusedPID else { continue }
            session.state = .done
            session.stateSince = now
            session.updatedAt = now
            session.turnEndedAt = now
            session.opencodeDisconnectedAt = now
            session.opencodeTurnResult = nil
            session.humanRequests = []
            session.message = "会话连接已中断，任务结果未知"
            session.notificationVersion += 1
            session.displayRevision = (session.displayRevision ?? 0) + 1
            byID[id] = session
            disconnected.append(session)
        }
        if !disconnected.isEmpty { persistCodexSessions() }
        return disconnected
    }

    /// Demotes stale `done` sessions to `idle`, removes long-idle ones, and
    /// drops active sessions that have gone quiet (agent died without `Stop`).
    public func prune(now: Date) {
        if archivingEnabled { effects.append(.retryArchives) }
        reconcileDSHConnection(now: now)
        let oldCodex = byID.filter { $0.value.agentKind == .codex || $0.value.agentKind == .antigravity || $0.value.agentKind == .opencode || $0.value.agentKind == .dsh || $0.value.humanRequests != nil }
        for id in Array(byID.keys) {
            guard let session = byID[id] else { continue }
            // Completion and attention cards survive TTLs until explicitly read.
            if session.hasUnread || !(session.humanRequests ?? []).isEmpty || (session.agentKind == .codex && (session.state == .working || session.state == .waiting)) { continue }
            // The daemon checks this owning process explicitly. Silence alone
            // must not delete a known native task while a long tool is running.
            if session.agentKind == .opencode && session.opencodeProcessID != nil &&
                (session.state == .working || session.state == .waiting) { continue }
            if session.agentKind == .dsh && (session.state == .working || session.state == .waiting) { continue }
            if preserveReadResults && (session.state == .done || session.state == .idle) &&
                session.hasReadReceipt && !session.isStopped { continue }
            let quiet = now.timeIntervalSince(max(session.updatedAt, session.readAt ?? session.updatedAt))
            switch session.state {
            case .done:
                if quiet >= doneToIdleAfter {
                    var s = session
                    s.state = .idle
                    s.updatedAt = now
                    s.stateSince = now
                    byID[id] = s
                }
            case .idle:
                if quiet >= removeIdleAfter {
                    if archivingEnabled {
                        effects.append(.archive(SessionArchiveRequest(session: session, endedAt: now, saveAfterRemoval: false)))
                        continue
                    }
                    byID.removeValue(forKey: id)
                }
            case .registered:
                if quiet >= staleRegisteredAfter {
                    if archivingEnabled {
                        effects.append(.archive(SessionArchiveRequest(session: session, endedAt: now, saveAfterRemoval: false)))
                        continue
                    }
                    byID.removeValue(forKey: id)
                }
            case .working, .waiting:
                let activeQuiet = now.timeIntervalSince(max(session.updatedAt,
                    session.opencodeLastSeenAt ?? session.updatedAt))
                if activeQuiet >= staleActiveAfter {
                    if archivingEnabled {
                        effects.append(.archive(SessionArchiveRequest(session: session, endedAt: now, saveAfterRemoval: false)))
                        continue
                    }
                    byID.removeValue(forKey: id)
                }
            }
        }
        effects.append(.pruneCheckpoint(oldCodex))
    }

    func finishArchive(_ receipt: ArchiveEffectReceipt, saveAfterRemoval: Bool = true) {
        let request = receipt.request
        guard receipt.result.safelyRetained, byID[request.session.id] == request.session else { return }
        // A retry may finish after the user selected "keep visible". The
        // durable history copy can stay, but its old receipt must not hide the row.
        if preserveReadResults && (request.session.state == .done || request.session.state == .idle) &&
            request.session.hasReadReceipt && !request.session.isStopped { return }
        byID.removeValue(forKey: request.session.id)
        if saveAfterRemoval && request.saveAfterRemoval { persistCodexSessions() }
    }

    func finishPruneCheckpoint(_ before: [String: AgentSession]) {
        if byID.filter({ SessionSnapshotDTO.includes($0.value) }) != before { persistCodexSessions() }
    }

    /// A missing bridge heartbeat is an unknown result, never a user stop.
    public func reconcileDSHConnection(now: Date) {
        var changed = false
        for (id, var session) in byID where session.agentKind == .dsh &&
            (session.state == .working || session.state == .waiting) &&
            now.timeIntervalSince(session.dshLastSeenAt ?? session.updatedAt) > 45 {
            session.state = .done; session.stateSince = now; session.updatedAt = now
            session.turnEndedAt = now; session.dshDisconnectedAt = now; session.humanRequests = []
            session.message = "会话连接已中断，任务结果未知"
            session.notificationVersion += 1
            session.displayRevision = (session.displayRevision ?? 0) + 1
            byID[id] = session; changed = true
        }
        if changed { persistCodexSessions() }
    }
}
