import Foundation

/// Pure context transitions; caller supplies evidence and clocks.
extension SessionReducer {
    /// Persist a positively identified internal purpose without inventing a
    /// native turn result, read receipt, or lifecycle transition.
    @discardableResult
    public func applyCodexInternalTaskEvidence(expected: AgentSession,
                                               evidence: CodexInternalTaskEvidence.Record) -> Bool {
        guard var session = byID[expected.id], session.agentKind == .codex,
              expected.agentKind == .codex, session.createdAt == expected.createdAt,
              evidence.sessionID == session.id, UUID(uuidString: session.id) != nil,
              ["projectSuggestions", "aionUiTitle", "desktopTransient", "desktopSideConversation",
               "desktopTransientCandidate", "desktopProcessExited"].contains(evidence.kind), evidence.home.hasPrefix("/"),
              let home = expected.codexHome, home == session.codexHome, home == evidence.home,
              expected.title == nil, session.title == nil,
              expected.codexHasNativeThreadRecord != true, session.codexHasNativeThreadRecord != true,
              !expected.codexDesktop, !session.codexDesktop,
              expected.terminalProgram == nil, session.terminalProgram == nil,
              expected.terminalTTY == nil, session.terminalTTY == nil,
              expected.terminalFocusURL == nil, session.terminalFocusURL == nil,
              expected.validAionUiConversation == nil, session.validAionUiConversation == nil,
              (evidence.kind == "desktopSideConversation" ||
                (expected.pendingApproval == nil && session.pendingApproval == nil &&
                 (expected.humanRequests ?? []).isEmpty && (session.humanRequests ?? []).isEmpty)),
              evidence.observedAt.timeIntervalSince1970.isFinite else { return false }
        if evidence.kind == "desktopSideConversation" {
            // This is session identity, independent of later tool/turn activity.
            // A concurrent native metadata lookup still fences it above.
            guard evidence.exitedAt == nil, session.createdAt <= evidence.observedAt,
                  !expected.isAOHostSession, !session.isAOHostSession else { return false }
        } else if evidence.kind == "desktopTransientCandidate" || evidence.kind == "desktopProcessExited" {
            guard evidence.exitedAt == nil, session.updatedAt == expected.updatedAt,
                  session.createdAt <= evidence.observedAt, session.updatedAt <= evidence.observedAt,
                  session.codexInternalTaskObservedAt.map({ evidence.observedAt >= $0 }) ?? true,
                  !expected.isAOHostSession, !session.isAOHostSession,
                  let source = evidence.desktopSource,
                  source.isValid(sessionID: session.id, home: home, at: evidence.observedAt) else { return false }
            // Polling an unchanged live candidate must not rewrite its snapshot
            // or turn the observation time into an activity heartbeat.
            if session.codexInternalTaskKind == evidence.kind, session.codexTransientSource == source,
               let observed = session.codexInternalTaskObservedAt, session.updatedAt <= observed { return false }
        } else if evidence.kind != "aionUiTitle" {
            guard let exit = evidence.exitedAt, exit.timeIntervalSince1970.isFinite,
                  exit <= evidence.observedAt, session.updatedAt <= exit else { return false }
        } else {
            guard evidence.exitedAt == nil, session.updatedAt == expected.updatedAt,
                  session.updatedAt <= evidence.observedAt else { return false }
        }
        let previous = session
        session.codexInternalTaskKind = evidence.kind
        session.codexTransientSource = evidence.desktopSource
        if let exit = evidence.exitedAt {
            if session.codexInternalTaskExitedAt.map({ exit > $0 }) ?? true {
                session.codexInternalTaskExitedAt = exit
            }
        } else {
            session.codexInternalTaskExitedAt = nil
            if session.codexInternalTaskObservedAt.map({ evidence.observedAt > $0 }) ?? true {
                session.codexInternalTaskObservedAt = evidence.observedAt
            }
        }
        guard session != previous else { return false }
        byID[session.id] = session
        persistCodexSessions()
        return true
    }

    /// A native final message may precede a later metadata/heartbeat Hook.
    /// Preserve that channel's ordering clock and the real completion time.
    func reconcileOpencodeCompletion(expected: AgentSession, record: OpencodeCompletedTurn.Record,
                                      now: Date) -> AgentSession? {
        guard var session = byID[expected.id], session.agentKind == .opencode,
              !session.isOpencodeSubagent, session.state == .working,
              session.createdAt == expected.createdAt,
              session.opencodeTurnID == expected.opencodeTurnID,
              session.opencodeEventAt == expected.opencodeEventAt,
              session.opencodeProcessID == expected.opencodeProcessID,
              session.opencodeProcessStartedAt == expected.opencodeProcessStartedAt,
              session.validAionUiConversation != nil,
              session.validAionUiConversation == expected.validAionUiConversation,
              session.turnEndedAt == nil, session.pendingApproval == nil,
              (session.humanRequests ?? []).isEmpty,
              record.sessionID == session.id, record.turnID == session.opencodeTurnID,
              let started = session.turnStartedAt,
              record.completedAt >= started, record.completedAt >= session.updatedAt,
              record.completedAt <= now.addingTimeInterval(-0.5) else { return nil }
        session.state = .done; session.message = "本轮已完成"
        session.turnEndedAt = record.completedAt; session.stateSince = record.completedAt
        session.updatedAt = record.completedAt
        session.opencodeTurnResult = .completed; session.opencodeDisconnectedAt = nil
        session.notificationVersion += 1
        session.displayRevision = (session.displayRevision ?? 0) + 1
        byID[session.id] = session
        persistCodexSessions()
        return session
    }

    /// Preserve legacy child records and receipts, but exclude them from live tasks.
    @discardableResult
    func updateOpencodeParent(id: String, createdAt: Date, parentID: String) -> Bool {
        guard var session = byID[id], session.agentKind == .opencode,
              session.createdAt == createdAt, id != parentID,
              OpencodeHookPayload.validSessionID(parentID),
              session.opencodeParentSessionID == nil else { return false }
        session.opencodeParentSessionID = parentID
        byID[id] = session
        persistCodexSessions()
        return true
    }

    public func updateCodexMetadata(id: String, record: CodexMetadata.Record, home: String) {
        guard let old = byID[id], old.agentKind == .codex else { return }
        byID[id]?.title = record.title
        if let model = record.model { byID[id]?.model = model }
        byID[id]?.codexDesktop = record.isDesktop
        byID[id]?.codexHome = home
        // A successful exact-ID native thread lookup is stronger evidence than
        // the diagnostic-only fallback. Missing/error lookups never call here.
        byID[id]?.codexInternalTaskKind = nil
        byID[id]?.codexInternalTaskExitedAt = nil
        byID[id]?.codexInternalTaskObservedAt = nil
        byID[id]?.codexTransientSource = nil
        byID[id]?.codexHasNativeThreadRecord = true
        if byID[id] != old { persistCodexSessions() }
    }

    @discardableResult
    public func updateAionUiMetadata(id: String, createdAt: Date, record: AionUiMetadata.Record,
                                     verifiedAt: Date = Date()) -> Bool {
        guard var session = byID[id], session.createdAt == createdAt,
              record.conversation.nativeSessionID == id, record.conversation.agentKind == session.agentKind,
              record.conversation.url != nil else { return false }
        let before = session
        session.aionUiConversation = record.conversation
        session.aionUiVerification = AionUiVerification(conversationID: record.conversation.id,
                                                        teamID: record.conversation.teamID,
                                                        teamRole: record.conversation.teamRole,
                                                        sessionCreatedAt: createdAt,
                                                        verifiedAt: verifiedAt,
                                                        launchEpoch: AionUiVerificationLaunch.epoch)
        if let title = record.title { session.title = title }
        // A refreshed check time is not a content change: keep it in memory
        // without a snapshot write on every poll.
        let identityChanged = before.aionUiConversation != session.aionUiConversation
            || before.title != session.title
            || !session.aionUiVerification!.attestsSameIdentity(as: before.aionUiVerification)
        byID[id] = session
        guard identityChanged else { return false }
        persistCodexSessions()
        return true
    }

    /// Drops the cached live verification. `clearRole` additionally drops the
    /// verified Team role after the bounded grace window, keeping the raw Team
    /// mark (id and last known name) so the row falls back to the explicit
    /// neutral "current state unconfirmed" presentation instead of a cached
    /// result. A later successful re-check restores everything.
    @discardableResult
    func clearAionUiVerification(id: String, createdAt: Date, clearRole: Bool) -> Bool {
        guard var session = byID[id], session.createdAt == createdAt else { return false }
        var changed = false
        if session.aionUiVerification != nil {
            session.aionUiVerification = nil
            changed = true
        }
        if clearRole, let known = session.aionUiConversation, known.teamID != nil, known.teamRole != nil {
            session.aionUiConversation = AionUiConversation(id: known.id, nativeSessionID: known.nativeSessionID,
                                                            agentKind: known.agentKind, teamID: known.teamID,
                                                            teamName: known.teamName, teamRole: nil)
            changed = true
        }
        guard changed else { return false }
        byID[id] = session
        persistCodexSessions()
        return true
    }

    /// Apply an exact-ID binding (or an explicit user-confirmed historical
    /// classification) only to the unchanged, previously unclassified record.
    /// Independent native provenance and AionUi/terminal targets take priority.
    @discardableResult
    public func markAntigravityDSHBackend(expected: AgentSession) -> Bool {
        guard var current = byID[expected.id], current == expected,
              current.agentKind == .antigravity, current.antigravityFromDSH == nil,
              current.terminalProgram == nil, current.terminalTTY == nil,
              current.terminalFocusURL == nil, current.validAionUiConversation == nil else { return false }
        current.antigravityFromDSH = true
        byID[current.id] = current
        persistCodexSessions()
        return true
    }

    public func updateAntigravityActivity(id: String, message: String, since: Date) {
        guard var session = byID[id], session.agentKind == .antigravity,
              session.state == .working, session.updatedAt == since else { return }
        guard session.message != message else { return }
        let wasRead = session.hasReadReceipt
        session.message = message
        session.displayRevision = (session.displayRevision ?? 0) + 1
        byID[id] = session
        if wasRead { persistCodexSessions() }
    }

    /// Updates the display title for a session. Called asynchronously after
    /// transcript title resolution completes off the main thread.
    public func updateTitle(id: String, title: String) {
        guard let session = byID[id], session.validAionUiConversation == nil else { return }
        byID[id]?.title = title
        if byID[id]?.agentKind == .antigravity { persistCodexSessions() }
    }

    /// Updates the display model for a session. Called asynchronously after
    /// an async transcript check resolves a `/model` switch mid-session,
    /// which hook payloads don't report.
    public func updateModel(id: String, model: String) {
        guard byID[id] != nil else { return }
        byID[id]?.model = model
    }

    /// Corrects a session's state after the fact — used when an async check
    /// (e.g. reading the transcript to see how Claude ended its turn)
    /// determines the state we set synchronously was wrong.
    ///
    /// Only applies when the session is *still* in `expected` state from the
    /// *same* transition (`since` matches `stateSince`): if a newer event has
    /// already moved the session on, this is a no-op — the correction targets
    /// a transition that no longer exists, and must never clobber fresher
    /// state. `stateSince` is preserved (this corrects the existing
    /// transition; it isn't a new one).
    public func refineState(id: String, from expected: AgentState, to refined: AgentState, since: Date) {
        guard var session = byID[id], session.state == expected, session.stateSince == since else { return }
        session.state = refined
        byID[id] = session
    }

    /// Use only the latest observed Host in the same Profile. Never scan random
    /// sockets or silently reuse an older live Host when the newest is stale.
    public func dshNavigationTarget(for clicked: AgentSession, now: Date) -> DSHObservation? {
        guard var target = clicked.dsh, let endpoint = dshEndpoints[target.profileID],
              now.timeIntervalSince(endpoint.seenAt) <= 45 else { return nil }
        target.hostID = endpoint.observation.hostID
        target.hostStartedAt = endpoint.observation.hostStartedAt
        target.navigationSocket = endpoint.observation.navigationSocket
        return target
    }

    /// A native agy binding may point at an unloaded DSH session. Only use the
    /// latest live endpoint for its exact profile; the Client verifies the ID.
    public func dshNavigationTarget(profileID: String, nativeSessionID: String, now: Date) -> DSHObservation? {
        guard let endpoint = dshEndpoints[profileID], now.timeIntervalSince(endpoint.seenAt) <= 45 else { return nil }
        var target = endpoint.observation
        target.nativeSessionID = nativeSessionID
        return target.valid ? target : nil
    }

    /// Opening an unloaded conversation can legitimately replace its old Host
    /// binding. A confirmed current endpoint may acknowledge only the unchanged
    /// display/turn that was clicked, never a new request or completion.
    @discardableResult
    public func markDSHOpened(_ clicked: AgentSession, target: DSHObservation, at: Date) -> Bool {
        guard let current = byID[clicked.id], current.createdAt == clicked.createdAt,
              target.valid, target.profileID == current.dsh?.profileID,
              target.nativeSessionID == current.dsh?.nativeSessionID,
              current.dsh?.turn == clicked.dsh?.turn,
              current.displayRevision == clicked.displayRevision,
              current.notificationVersion == clicked.notificationVersion,
              current.dshDisconnectedAt == nil,
              let endpoint = dshNavigationTarget(for: current, now: at),
              endpoint.hostID == target.hostID, endpoint.navigationSocket == target.navigationSocket else { return false }
        var confirmed = clicked
        confirmed.interactionGeneration = current.interactionGeneration
        return markOpened(confirmed, at: at)
    }
}
