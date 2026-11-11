import Foundation

/// Pure lifecycle transitions; caller supplies evidence and clocks.
extension SessionReducer {
    /// Native lifecycle is authoritative for a specific turn. Hook activity
    /// still supplies live tool labels; a missing Stop cannot keep a turn alive.
    @discardableResult
    public func reconcileCodexLifecycle(id: String, event: CodexLifecycle) -> AgentSession? {
        guard var session = byID[id], session.agentKind == .codex else { return nil }
        let previous = session
        if let latest = session.codexLifecycleAt, event.timestamp <= latest { return nil }
        if let result = event.result {
            if session.codexTurnID != event.turnID {
                // A previous turn's terminal record must not end a new prompt.
                if let start = session.turnStartedAt, event.timestamp < start { return nil }
                if session.codexTurnID != nil, let start = session.turnStartedAt,
                   let nativeStart = event.startedAt, nativeStart < start { return nil }
            }
            if session.state != .done && session.state != .idle {
                session.notificationVersion += 1
                session.displayRevision = (session.displayRevision ?? 0) + 1
            }
            let effectiveResult: CodexTurnResult = session.codexTurnID == event.turnID && session.codexTurnResult == .cancelled ? .cancelled : result
            session.codexTurnID = event.turnID
            session.codexTurnResult = effectiveResult
            session.turnEndedAt = event.timestamp
            if let start = event.startedAt { session.turnStartedAt = start }
            session.state = .done
            session.stateSince = event.timestamp
            session.pendingApproval = nil
            switch effectiveResult {
            case .completed: session.message = "本轮已完成"
            case .cancelled: session.message = "任务已停止"
            case .failed: session.message = "任务结束，发生错误"
            }
        } else {
            if session.codexTurnID == event.turnID && session.codexTurnResult != nil { return nil }
            let newTurn = session.codexTurnID != event.turnID
            if newTurn {
                _ = supersedeCodexRequests(&session, before: event.timestamp)
                // Attaching to the already active turn must preserve a newer
                // permission Hook and its unread card.
                let bindingActiveTurn = session.codexTurnID == nil && session.turnEndedAt == nil &&
                    (session.state == .working || session.state == .waiting) && event.timestamp <= session.updatedAt
                session.codexTurnResult = nil
                session.turnEndedAt = nil
                if !bindingActiveTurn {
                    session.readThroughVersion = session.notificationVersion
                    session.readAt = nil
                    session.displayRevision = (session.displayRevision ?? 0) + 1
                    session.interactionGeneration = (session.interactionGeneration ?? 0) + 1
                    session.pendingApproval = nil
                    if session.state != .working { session.message = "正在处理任务" }
                    session.state = .working
                    session.stateSince = event.timestamp
                }
            }
            session.codexTurnID = event.turnID
            session.turnStartedAt = event.startedAt ?? event.timestamp
        }
        session.codexLifecycleAt = event.timestamp
        session.updatedAt = max(session.updatedAt, event.timestamp)
        holdHumanRequests(&session, previous: previous)
        byID[id] = session
        persistCodexSessions()
        return session
    }

    func applyHook(_ event: AgentEvent, now: Date) -> AgentSession? {
        guard !RetiredAgentRegistry.ignores(event.agentKind, rawName: event.agentName) else { return nil }
        _ = bindAOHostEnvironment(from: event, now: now)
        if event.agentKind == .opencode {
            let parent = event.opencodeParentSessionID.flatMap {
                $0 != event.sessionId && OpencodeHookPayload.validSessionID($0) ? $0 : nil
            }
            if let parent, let old = byID[event.sessionId] {
                _ = updateOpencodeParent(id: old.id, createdAt: old.createdAt, parentID: parent)
            }
            // Filter before both lifecycle and human-request reducers.
            if byID[event.sessionId]?.isOpencodeSubagent == true || parent != nil { return nil }
        }
        if event.agentKind == .dsh {
            if event.eventName == "dsh/observation", let observation = event.dsh,
               observation.valid, event.sessionId == observation.sessionKey,
               observation.hostStartedAt <= event.timestamp, event.timestamp <= now.addingTimeInterval(5),
               observation.navigationSocket != nil {
                let old = dshEndpoints[observation.profileID]
                if old == nil || observation.hostStartedAt > old!.observation.hostStartedAt ||
                    (observation.hostID == old!.observation.hostID && event.timestamp > old!.seenAt) {
                    if old == nil && dshEndpoints.count >= 128,
                       let expired = dshEndpoints.min(by: { $0.value.seenAt < $1.value.seenAt })?.key {
                        dshEndpoints.removeValue(forKey: expired)
                    }
                    dshEndpoints[observation.profileID] = (observation, event.timestamp)
                }
            }
            guard let updated = DSHSessionReducer.apply(event, previous: byID[event.sessionId], now: now) else { return nil }
            let before = byID[event.sessionId]
            byID[event.sessionId] = updated
            _ = attachPendingAOBinding(id: event.sessionId)
            let current = byID[event.sessionId] ?? updated
            let visibleChange = before?.displayRevision != current.displayRevision || before?.dsh?.hostID != current.dsh?.hostID ||
                before?.title != current.title || before?.model != current.model || before?.project != current.project
            if visibleChange || now.timeIntervalSince(dshSnapshotCheckpointAt ?? .distantPast) >= 60 {
                persistCodexSessions()
                dshSnapshotCheckpointAt = now
            }
            return current
        }
        if event.humanIntervention != nil {
            let nativePost = ["PostToolUse", "PostToolUseFailure", "PermissionDenied", "postToolUse"].contains(event.eventName)
            if nativePost, !(byID[event.sessionId]?.humanRequests ?? []).contains(where: { pending in
                event.humanIntervention!.requests.contains(where: { $0.id == pending.id })
            }) {
                var activity = event; activity.humanIntervention = nil
                return apply(activity, now: now)
            }
            return applyHumanIntervention(event)
        }
        if event.agentKind == .opencode { return applyOpencode(event, now: now) }
        // A session-end event (agent quit/closed) removes the session at once,
        // so it doesn't linger as "done" until the idle timeout.
        if StateMapper.isSessionEnd(for: event.agentKind, eventName: event.eventName) {
            if let session = byID[event.sessionId], archivingEnabled {
                effects.append(.archive(SessionArchiveRequest(session: session, endedAt: now, saveAfterRemoval: true)))
                return nil
            }
            byID.removeValue(forKey: event.sessionId)
            persistCodexSessions()
            return nil
        }
        guard var state = StateMapper.state(for: event.agentKind, eventName: event.eventName) else {
            return nil
        }

        let pendingApproval: PendingApproval?
        if let requestId = event.approvalRequestId {
            state = .waiting
            pendingApproval = PendingApproval(
                requestId: requestId, toolName: event.toolName ?? "", summary: event.toolSummary ?? ""
            )
        } else {
            pendingApproval = nil
        }

        if var existing = byID[event.sessionId] {
            let previous = existing
            let priorState = existing.state
            let priorGeneration = existing.interactionGeneration
            let priorAgyStepFloor = existing.antigravityStepFloor
            let hadReadReceipt = existing.hasReadReceipt
            if event.agentKind == .codex {
                // Desktop resume can emit SessionStart in the middle of a turn.
                if event.eventName == "SessionStart" { return nil }
                // Reject duplicate/late deliveries, including an old working event after Stop.
                guard event.timestamp > existing.updatedAt else { return nil }
                // Only an explicit new prompt may reopen a native terminal turn.
                if (existing.codexTurnResult != nil || existing.turnEndedAt != nil) && event.eventName != "UserPromptSubmit" { return nil }
                if state == .working && (event.eventName == "UserPromptSubmit" || existing.state == .done || existing.state == .registered) {
                    _ = supersedeCodexRequests(&existing, before: event.timestamp)
                    existing.codexTurnID = nil
                    existing.codexTurnResult = nil
                    existing.turnStartedAt = event.timestamp
                    existing.turnEndedAt = nil
                    existing.readThroughVersion = existing.notificationVersion
                    existing.readAt = nil
                    existing.interactionGeneration = (existing.interactionGeneration ?? 0) + 1
                }
                if state == .done { existing.turnEndedAt = event.timestamp }
                if let home = event.codexHome { existing.codexHome = home }
            }
            if event.agentKind == .antigravity {
                guard event.timestamp > (existing.antigravityEventAt ?? existing.updatedAt) else { return nil }
                // Post-tool/queued work after Esc must not reopen the stopped
                // task. A fresh native invocation is required to resume it.
                if existing.antigravityTurnResult == .cancelled &&
                    (state == .done || (state == .working && event.antigravityNewInvocation != true)) { return nil }
                if event.antigravityNewInvocation == true, let fromDSH = event.antigravityFromDSH {
                    existing.antigravityFromDSH = fromDSH
                } else if existing.antigravityFromDSH == nil, let fromDSH = event.antigravityFromDSH {
                    existing.antigravityFromDSH = fromDSH
                }
                existing.antigravityEventAt = event.timestamp
                if event.antigravityNewInvocation == true {
                    // A missing boundary cannot inherit evidence from an old
                    // invocation. Native tool hooks only advance this floor.
                    existing.antigravityStepFloor = event.antigravityStepFloor
                } else if let floor = event.antigravityStepFloor {
                    existing.antigravityStepFloor = max(existing.antigravityStepFloor ?? floor, floor)
                }
                if state == .working && (existing.state == .done || existing.state == .idle || existing.turnStartedAt == nil) {
                    existing.turnStartedAt = event.timestamp
                    existing.turnEndedAt = nil
                    existing.antigravityTurnResult = nil
                    existing.readThroughVersion = existing.notificationVersion
                    existing.readAt = nil
                    existing.interactionGeneration = (existing.interactionGeneration ?? 0) + 1
                }
                if state == .done {
                    if existing.turnEndedAt == nil { existing.turnEndedAt = event.timestamp }
                    existing.antigravityTurnResult = event.turnResult
                }
            }
            if event.agentKind != .codex && event.agentKind != .antigravity,
               state == .working,
               (existing.state == .done || existing.state == .idle || existing.turnStartedAt == nil ||
                ["UserPromptSubmit", "UserPromptSubmitted", "beforeSubmitPrompt", "pre_user_prompt", "user_prompt_submit", "userPromptSubmit", "agent_start", "turn_start", "BeforeAgent"].contains(event.eventName)) {
                existing.turnStartedAt = event.timestamp
                existing.turnEndedAt = nil
                existing.readThroughVersion = existing.notificationVersion
                existing.readAt = nil
                existing.interactionGeneration = (existing.interactionGeneration ?? 0) + 1
            }
            if event.agentKind == .pi { existing.piTurnResult = state == .done ? event.turnResult : nil }
            if (state == .done || state == .waiting) && (existing.state != state || existing.message != event.message) {
                existing.notificationVersion += 1
            }
            // Each fresh work event is a new displayed activity. A click only
            // reads the captured revision; running status keeps its blue lamp.
            if state == .working || existing.state != state || existing.message != event.message {
                existing.displayRevision = (existing.displayRevision ?? 0) + 1
            }
            if existing.state != state { existing.stateSince = now }
            existing.state = state
            existing.updatedAt = event.agentKind == .antigravity ? max(existing.updatedAt, event.timestamp) : (event.agentKind == .codex ? event.timestamp : now)
            if let project = event.project { existing.project = project }
            if let model = event.model { existing.model = model }
            if let program = event.terminalProgram { existing.terminalProgram = program }
            if let tty = event.terminalTTY { existing.terminalTTY = tty }
            if let focusURL = event.terminalFocusURL { existing.terminalFocusURL = focusURL }
            if let name = event.agentName { existing.agentName = name }
            existing.message = event.message
            existing.pendingApproval = pendingApproval
            if state == .done && event.agentKind != .codex && event.agentKind != .antigravity { existing.turnEndedAt = event.timestamp }
            if state == .waiting && existing.humanRequests == nil { existing.humanRequests = [] }
            holdHumanRequests(&existing, previous: previous)
            byID[event.sessionId] = existing
            if (event.agentKind == .codex || event.agentKind == .antigravity || existing.humanRequests != nil) && (priorState != state || state != .working || priorGeneration != existing.interactionGeneration || priorAgyStepFloor != existing.antigravityStepFloor || previous.antigravityFromDSH != existing.antigravityFromDSH || hadReadReceipt != existing.hasReadReceipt) { persistCodexSessions() }
            return existing
        }
        var session = AgentSession(
            id: event.sessionId,
            agentKind: event.agentKind,
            project: event.project,
            state: state,
            message: event.message,
            model: event.model,
            source: .hook,
            updatedAt: (event.agentKind == .codex || event.agentKind == .antigravity) ? event.timestamp : now,
            pendingApproval: pendingApproval,
            terminalProgram: event.terminalProgram,
            terminalTTY: event.terminalTTY,
            terminalFocusURL: event.terminalFocusURL,
            agentName: event.agentName
        )
        if event.agentKind == .codex {
            session.codexHome = event.codexHome
            session.turnStartedAt = state == .working ? event.timestamp : nil
            session.turnEndedAt = state == .done ? event.timestamp : nil
        }
        if event.agentKind == .antigravity {
            session.antigravityFromDSH = event.antigravityFromDSH
            session.antigravityTurnResult = event.turnResult
            session.antigravityEventAt = event.timestamp
            session.antigravityStepFloor = event.antigravityStepFloor
            session.turnStartedAt = state == .working ? event.timestamp : nil
            session.turnEndedAt = state == .done ? event.timestamp : nil
        }
        session.notificationVersion = (state == .done || state == .waiting) ? 1 : 0
        session.interactionGeneration = 0
        session.displayRevision = 0
        if state == .waiting { session.humanRequests = [] }
        if session.turnStartedAt == nil && state == .working { session.turnStartedAt = event.timestamp }
        if event.agentKind == .pi, state == .done {
            session.piTurnResult = event.turnResult
            session.turnEndedAt = event.timestamp
        }
        byID[event.sessionId] = session
        _ = attachPendingAOBinding(id: event.sessionId)
        if event.agentKind == .codex || event.agentKind == .antigravity || session.humanRequests != nil { persistCodexSessions() }
        return byID[event.sessionId] ?? session
    }

    func applyOpencode(_ event: AgentEvent, now: Date) -> AgentSession? {
        let previous = byID[event.sessionId]
        if let latest = previous?.opencodeEventAt, event.timestamp <= latest { return nil }
        if event.eventName == "deleted" {
            if let session = previous, archivingEnabled {
                effects.append(.archive(SessionArchiveRequest(session: session, endedAt: event.timestamp, saveAfterRemoval: true)))
                return nil
            }
            byID.removeValue(forKey: event.sessionId)
            persistCodexSessions()
            return nil
        }
        if event.eventName == "heartbeat" {
            guard var session = previous, session.turnEndedAt == nil,
                  session.state == .working || session.state == .waiting,
                  session.opencodeTurnID == event.opencodeTurnID,
                  session.opencodeProcessID == event.opencodeProcessID else { return nil }
            session.opencodeLastSeenAt = event.timestamp
            session.opencodeEventAt = event.timestamp
            let checkpoint = event.timestamp.timeIntervalSince(session.opencodeCheckpointAt ?? session.updatedAt) >= 60
            if checkpoint { session.opencodeCheckpointAt = event.timestamp }
            byID[event.sessionId] = session
            // A minute-scale checkpoint survives app restarts without writing on
            // every heartbeat or changing the displayed activity/receipt.
            if checkpoint { persistCodexSessions() }
            return session
        }
        let metadata = event.eventName == "metadata"
        guard let state = metadata ? previous?.state : StateMapper.state(for: .opencode, eventName: event.eventName) else { return nil }
        var session = previous ?? AgentSession(id: event.sessionId, agentKind: .opencode,
            project: event.project, state: state, source: .hook, updatedAt: event.timestamp)
        if !metadata {
            // Only a native new prompt/busy boundary may reopen a finished turn.
            let newTurn = state == .working && (event.opencodeNewTurn == true || session.opencodeTurnID == nil)
            if let turn = session.opencodeTurnID, let incoming = event.opencodeTurnID,
               turn != incoming && !newTurn { return nil }
            if session.turnEndedAt != nil && state != .done && !newTurn { return nil }
            if newTurn {
                session.opencodeTurnID = event.opencodeTurnID
                session.humanRequests = []
                session.opencodeTurnResult = nil
                session.opencodeDisconnectedAt = nil
                session.turnStartedAt = event.timestamp
                session.turnEndedAt = nil
                session.readThroughVersion = session.notificationVersion
                session.readAt = nil
                session.interactionGeneration = (session.interactionGeneration ?? 0) + 1
            }
            if state == .done {
                // Duplicate idle notifications do not change the result or timer.
                if session.turnEndedAt != nil && session.opencodeDisconnectedAt == nil { return nil }
                session.opencodeDisconnectedAt = event.turnResult == nil ? event.timestamp : nil
                session.turnEndedAt = event.timestamp
                session.opencodeTurnResult = event.turnResult
            }
            if (state == .waiting || state == .done) && (previous?.state != state || previous?.message != event.message) {
                session.notificationVersion += 1
            }
            if state == .working || previous?.state != state || previous?.message != event.message {
                session.displayRevision = (session.displayRevision ?? 0) + 1
            }
            if previous?.state != state { session.stateSince = event.timestamp }
            session.state = state
            session.message = event.message
            session.updatedAt = event.timestamp
        }
        if let title = event.title { session.title = title }
        if let model = event.model { session.model = model }
        if let project = event.project { session.project = project }
        if let program = event.terminalProgram { session.terminalProgram = program }
        if let tty = event.terminalTTY { session.terminalTTY = tty }
        if let focusURL = event.terminalFocusURL { session.terminalFocusURL = focusURL }
        if let socket = event.opencodeNavigationSocket { session.opencodeNavigationSocket = socket }
        // Opening/renaming an old conversation in a new idle client cannot
        // transfer an active task's ownership and make a dead owner look alive.
        if !metadata || (session.state != .working && session.state != .waiting) {
            if let pid = event.opencodeProcessID { session.opencodeProcessID = pid }
            if let birth = event.opencodeProcessStartedAt { session.opencodeProcessStartedAt = birth }
        }
        session.opencodeLastSeenAt = event.timestamp
        session.opencodeEventAt = event.timestamp
        holdHumanRequests(&session, previous: previous)
        byID[event.sessionId] = session
        _ = attachPendingAOBinding(id: event.sessionId)
        if metadata || state != .working || previous?.state != state || previous?.interactionGeneration != session.interactionGeneration || previous?.hasReadReceipt != session.hasReadReceipt {
            persistCodexSessions()
        }
        return byID[event.sessionId] ?? session
    }
}
