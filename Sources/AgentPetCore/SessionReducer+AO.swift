import Foundation

/// AO observation is a host-side projection layered on the existing session
/// reducer. Native Hook facts remain the only source of turn state/results;
/// AO adds project/role/status context and an AO-only row until an exact
/// native binding exists.
///
/// Generation boundary: a newer `createdAt` or a changed launch string is not
/// proof that a native session replaced another one. When more than one native
/// session claims the same AO session, every claim becomes an explicit conflict
/// with no current AO role. The native rows themselves stay visible with their
/// own state, unread and attention.
extension SessionReducer {
    /// Captures the AO coordinates carried by a native Hook event. Subagents
    /// inherit the parent environment but are not AO sessions of their own.
    @discardableResult
    func bindAOHostEnvironment(from event: AgentEvent, now: Date) -> Bool {
        guard event.subagentId == nil, event.opencodeParentSessionID == nil,
              let sessionID = event.aoSessionID,
              AOHostObservation.validID(sessionID),
              event.aoProjectID == nil || AOHostObservation.validID(event.aoProjectID!) else { return false }
        let binding = AOBinding(sessionID: sessionID, projectID: event.aoProjectID,
                                launchID: event.aoLaunchID,
                                agentKind: event.agentKind, origin: .hookEnvironment, boundAt: now)
        return recordAOBinding(binding, nativeSessionID: event.sessionId, now: now)
    }

    /// Records one exact native claim. A claim is not made current merely by
    /// being newer: `reconcileAOBindingClaims` marks every claim conflicted
    /// when the AO identity has more than one live native owner. Pending claims
    /// (before their native row exists) use the same boundary.
    @discardableResult
    func recordAOBinding(_ binding: AOBinding, nativeSessionID: String,
                         createdAt: Date? = nil, now: Date) -> Bool {
        var binding = binding
        // Native IDs belong to the emitting Hook, not AO's object namespace.
        // Pi uses `pi:<absolute session-file path>`, including slashes and IDs
        // longer than AO's short IDs. Keep the observer envelope's bounded,
        // control-free identity rule and preserve the exact native string.
        guard binding.valid, HumanIntervention.validID(nativeSessionID) else { return false }
        if let observation = aoSessions[binding.sessionID], observation.available,
           (observation.projectID != (binding.projectID ?? observation.projectID)
            || (AOHostMapping.agentKind(for: observation.harness) != binding.agentKind
                && binding.agentKind != .unknown)) {
            return false
        }
        if let existing = byID[nativeSessionID] {
            if let createdAt, existing.createdAt != createdAt { return false }
            guard existing.agentKind == binding.agentKind else { return false }
            if let old = existing.aoBinding, old.sessionID != binding.sessionID { return false }
        }
        if let old = aoBindings[nativeSessionID], old.sessionID != binding.sessionID { return false }
        if aoBindings[nativeSessionID] == nil, byID[nativeSessionID] == nil, aoBindings.count >= 256 {
            return false
        }
        // A conflicted claim is not cleared by another Hook from the same
        // native row; only a relaunch (which drops claims) or explicit evidence
        // may re-confirm it.
        if let old = byID[nativeSessionID]?.aoBinding ?? aoBindings[nativeSessionID] {
            if old.conflictedAt != nil, binding.conflictedAt == nil {
                binding.conflictedAt = old.conflictedAt
            }
            if old.supersededAt != nil, binding.supersededAt == nil {
                binding.supersededAt = old.supersededAt
            }
        }

        var changed = false
        if var session = byID[nativeSessionID] {
            if session.aoBinding != binding {
                session.aoBinding = binding
                changed = true
            }
            byID[nativeSessionID] = session
            aoBindings.removeValue(forKey: nativeSessionID)
        } else {
            if aoBindings[nativeSessionID] != binding {
                aoBindings[nativeSessionID] = binding
                changed = true
            }
            // No native row yet: the claim remains pending until creation.
            _ = reconcileAOBindingClaims(now: now)
            return changed
        }
        if reconcileAOBindingClaims(now: now) { changed = true }
        guard var session = byID[nativeSessionID] else { return changed }
        if session.aoBinding?.isCurrent == true,
           let observation = aoSessions[binding.sessionID], observation.available,
           observation.projectID == (binding.projectID ?? observation.projectID),
           (AOHostMapping.agentKind(for: observation.harness) == session.agentKind
            || session.agentKind == .unknown) {
            if session.aoObservation != observation {
                session.aoObservation = observation
                changed = true
            }
            if removeAOPlaceholder(for: binding.sessionID) { changed = true }
        } else if session.aoObservation != nil {
            session.aoObservation = nil
            changed = true
        }
        byID[session.id] = session
        if changed { persistCodexSessions() }
        return changed
    }

    /// Attaches a pending claim once the native Hook row exists. A conflicted
    /// pending claim still becomes the row's historical binding but never its
    /// current AO role.
    @discardableResult
    func attachPendingAOBinding(id: String) -> Bool {
        guard var session = byID[id], session.aoBinding == nil,
              let pending = aoBindings[id] else { return false }
        session.aoBinding = pending
        byID[id] = session
        aoBindings.removeValue(forKey: id)
        var changed = true
        if reconcileAOBindingClaims(now: Date()) { changed = true }
        guard var current = byID[id] else { return changed }
        if current.aoBinding?.isCurrent == true,
           let observation = aoSessions[pending.sessionID], observation.available,
           observation.projectID == (pending.projectID ?? observation.projectID),
           (AOHostMapping.agentKind(for: observation.harness) == current.agentKind
            || current.agentKind == .unknown) {
            if current.aoObservation != observation {
                current.aoObservation = observation
                changed = true
            }
            if removeAOPlaceholder(for: pending.sessionID) { changed = true }
        } else if current.aoObservation != nil {
            current.aoObservation = nil
            changed = true
        }
        byID[id] = current
        if changed { persistCodexSessions() }
        return changed
    }

    /// Applies one bounded AO snapshot. It never changes a bound native
    /// session's turn state/result. Only AO-only placeholder rows derive their
    /// display state from host facts. Returns placeholder transitions so the
    /// caller can notify on a real transition (never for initial history).
    @discardableResult
    func applyAOSnapshot(_ snapshot: AOSnapshot, now: Date) -> [AOHostTransition] {
        guard AOHostObservation.validInstanceID(snapshot.instanceID),
              snapshot.observedAt.timeIntervalSince1970.isFinite else { return [] }
        var transitions: [AOHostTransition] = []
        var cacheChanged = false
        if aoInstanceID != snapshot.instanceID {
            // A daemon restart creates a new generation. A claim/role from the
            // previous generation is history; live Hooks must re-confirm it.
            // Native rows, state and receipts stay visible.
            if aoInstanceID != nil {
                for (id, session) in Array(byID) {
                    if session.isAOPlaceholder {
                        byID.removeValue(forKey: id)
                        cacheChanged = true
                        continue
                    }
                    guard var current = byID[id],
                          current.aoBinding != nil || current.aoObservation != nil else { continue }
                    current.aoBinding = nil
                    current.aoObservation = nil
                    byID[id] = current
                    cacheChanged = true
                }
                if !aoBindings.isEmpty { aoBindings.removeAll(); cacheChanged = true }
            }
            aoSessions.removeAll()
            aoInstanceID = snapshot.instanceID
        }

        let previousObservations = aoSessions
        var merged: [String: AOHostObservation] = [:]
        for var observation in snapshot.sessions {
            guard observation.valid, observation.instanceID == snapshot.instanceID else { continue }
            if observation.projectName == nil { observation.projectName = snapshot.projectNames[observation.projectID] }
            observation.observedAt = snapshot.observedAt
            if let old = aoSessions[observation.sessionID] {
                let newer = observation.updatedAt > old.updatedAt
                    || (observation.updatedAt == old.updatedAt
                        && (observation.lastEventAt ?? .distantPast) >= (old.lastEventAt ?? .distantPast))
                if !newer {
                    var kept = old
                    kept.projectName = observation.projectName ?? old.projectName
                    kept.displayName = observation.displayName ?? old.displayName
                    kept.orchestration = observation.orchestration ?? old.orchestration
                    kept.available = observation.available
                    kept.observedAt = observation.observedAt
                    merged[observation.sessionID] = kept
                    continue
                }
            }
            merged[observation.sessionID] = observation
        }

        // A current snapshot can disprove a project/harness claim, including
        // an unmaterialized pending claim. No age/launch heuristic retires one.
        for (id, binding) in Array(aoBindings) {
            if let observation = merged[binding.sessionID],
               !Self.binding(binding, matches: observation) {
                aoBindings.removeValue(forKey: id)
            }
        }
        for (id, session) in Array(byID) where !session.isAOPlaceholder {
            guard let binding = session.aoBinding,
                  let observation = merged[binding.sessionID],
                  !Self.binding(binding, matches: observation) else { continue }
            var rejected = session
            rejected.aoBinding = nil
            rejected.aoObservation = nil
            byID[id] = rejected
            cacheChanged = true
        }
        // Conflict is sticky: rejecting another claim never promotes a prior
        // conflicted claim. It needs fresh evidence after claims are cleared.
        if reconcileAOBindingClaims(now: now) { cacheChanged = true }
        for (id, session) in Array(byID) where session.isAOPlaceholder {
            if let aoID = session.aoBinding?.sessionID, merged[aoID] != nil { continue }
            byID.removeValue(forKey: id)
        }
        aoSessions = merged

        // A changed explicit native handle retires an identity-reader claim.
        // It must not compete with its replacement or inherit that new role.
        for (id, native) in Array(byID) where native.aoBinding?.origin == .nativeIdentity {
            guard let old = native.aoBinding, old.isCurrent,
                  let exact = snapshot.nativeIdentities.first(where: { $0.sessionID == old.sessionID }),
                  exact.materializedSession(in: byID)?.id != id else { continue }
            var retired = native
            retired.aoBinding?.supersededAt = now
            retired.aoObservation = nil
            byID[id] = retired
            cacheChanged = true
        }
        // Restore only materialized native rows whose exact handle is still
        // owned by the current AO session. Persisted roles alone are never proof.
        for identity in snapshot.nativeIdentities {
            guard let host = merged[identity.sessionID], host.available,
                  let native = identity.materializedSession(in: byID),
                  AOHostMapping.agentKind(for: host.harness) == identity.agentKind else { continue }
            if let existing = native.aoBinding, existing.sessionID == host.sessionID,
               existing.projectID == host.projectID { continue }
            let binding = AOBinding(sessionID: host.sessionID, projectID: host.projectID,
                agentKind: identity.agentKind, origin: .nativeIdentity, boundAt: now)
            _ = recordAOBinding(binding, nativeSessionID: native.id, createdAt: native.createdAt, now: now)
        }

        // A native row must not keep an observation the current snapshot no
        // longer contains, and a non-current (conflicted/historical) claim must
        // never carry a current AO role. Native state, unread and attention are
        // untouched.
        for (id, session) in Array(byID) where !session.isAOPlaceholder {
            guard let observation = session.aoObservation else { continue }
            if session.aoBinding?.isCurrent != true
                || merged[observation.sessionID] == nil {
                var updated = session
                updated.aoObservation = nil
                byID[id] = updated
            }
        }

        if recordAOAttention(in: merged) { cacheChanged = true }
        if cacheChanged { persistCodexSessions() }
        var activeProjects = Set(merged.values.filter {
            Self.showsAOPlaceholder($0)
        }.compactMap { $0.orchestration?.teamID })
        // A completed native worker may still carry an unread result even
        // after AO becomes idle. Keep the already observed orchestrator as
        // the project's representative until that obligation is consumed.
        for session in byID.values where !session.isAOPlaceholder && !session.isCodexInternalTask {
            guard session.hasUnread || session.state == .working || session.state == .waiting,
                  let binding = session.aoBinding, binding.isCurrent,
                  let observation = merged[binding.sessionID],
                  observation.available, let project = observation.orchestration?.teamID else { continue }
            activeProjects.insert(project)
        }
        for observation in merged.values.sorted(by: { $0.sessionID < $1.sessionID }) {
            let current = Array(byID.values).filter {
                !$0.isAOPlaceholder && $0.aoBinding?.isCurrent == true
                    && $0.aoBinding?.sessionID == observation.sessionID
            }
            if let session = current.first {
                guard var updated = byID[session.id] else { continue }
                if updated.aoObservation != observation {
                    updated.aoObservation = observation
                    byID[session.id] = updated
                }
                _ = removeAOPlaceholder(for: observation.sessionID)
                continue
            }

            let placeholderID = AOHostMapping.placeholderID(observation.sessionID)
            if let existing = byID[placeholderID], !existing.isAOPlaceholder { continue }
            // No verified materialized native owner: preserve the exact AO
            // session evidence independently. Pending, conflicted and historical
            // claims cannot swallow a host wait or assign it to an arbitrary row.
            let before = byID[placeholderID]
            let priorHost = previousObservations[observation.sessionID].map {
                AOHostMapping.placeholderSession(for: $0)
            }
            let wasActive = (before ?? priorHost).map { $0.state == .working || $0.state == .waiting } ?? false
            // Include an idle orchestrator while its project has active tasks:
            // the summary must not lose the representative just because a
            // worker is doing the work. Idle-only history still creates no rows.
            let projectRepresentative = observation.role == .orchestrator && observation.available
                && !observation.isExited && observation.orchestration.map {
                    activeProjects.contains($0.teamID)
                } == true
            guard Self.showsAOPlaceholder(observation) || projectRepresentative
                    || before?.hasUnread == true || wasActive else {
                // AO-only rows exist for current work/attention. An old idle,
                // PR-only or terminated session with no unread has no task row.
                if let before, before.isAOPlaceholder, !before.hasUnread {
                    byID.removeValue(forKey: placeholderID)
                }
                continue
            }
            var placeholder = before ?? AOHostMapping.placeholderSession(for: observation)
            updatePlaceholder(&placeholder, with: observation, before: before)
            byID[placeholderID] = placeholder
            let displayChanged = before == nil
                || placeholder.state != before?.state
                || placeholder.message != before?.message
                || placeholder.title != before?.title
                || placeholder.notificationVersion != before?.notificationVersion
            if displayChanged {
                // A conflict may move an already observed host into its own
                // row. Preserve that host's transition baseline so a new wait
                // still notifies; a first snapshot remains silent history.
                transitions.append(.init(before: before ?? priorHost, after: placeholder))
            }
        }
        return transitions
    }

    /// AO-only rows are task rows: current work, a human wait, or an explicit
    /// no-signal unknown. Idle/PR/terminated history stays out of the bubble.
    private static func showsAOPlaceholder(_ observation: AOHostObservation) -> Bool {
        observation.available && (observation.isWorking || observation.isWaiting || observation.isNoSignal)
    }

    /// Marks every cached AO observation unavailable without deleting the row
    /// or claiming a new result. Bound native state is untouched; AO-only rows
    /// become explicitly unknown.
    @discardableResult
    func markAOUnavailable(now: Date) -> [AOHostTransition] {
        // Hooks arriving while disconnected must not reattach the cached host
        // as available or remove the independent unknown/attention row.
        for (id, var observation) in aoSessions {
            observation.available = false
            observation.observedAt = now
            aoSessions[id] = observation
        }
        var transitions: [AOHostTransition] = []
        for (id, session) in Array(byID) {
            guard var observation = session.aoObservation, observation.available else { continue }
            observation.available = false
            observation.observedAt = now
            if session.isAOPlaceholder {
                var updated = session
                updatePlaceholder(&updated, with: observation, before: session)
                if updated != session {
                    byID[id] = updated
                    transitions.append(.init(before: session, after: updated))
                }
            } else {
                var updated = session
                updated.aoObservation = observation
                byID[id] = updated
            }
        }
        return transitions
    }

    /// Drops native AO claims and observations while preserving native rows,
    /// their receipts, and independently observed AO-only evidence. Called after the launch event queue is drained: a queued
    /// pre-launch claim must not become the current generation by age alone.
    @discardableResult
    func clearAOHostClaims() -> Bool {
        var changed = false
        for (id, session) in Array(byID) {
            guard !session.isAOPlaceholder,
                  session.aoBinding != nil || session.aoObservation != nil else { continue }
            var updated = session
            updated.aoBinding = nil
            updated.aoObservation = nil
            byID[id] = updated
            changed = true
        }
        if !aoBindings.isEmpty { aoBindings.removeAll(); changed = true }
        return changed
    }

    /// Source-of-truth claim reconciliation. At most one live claim per AO
    /// session may be current. Once a conflict is observed it is not auto-
    /// cleared: a later app launch or explicit evidence must re-confirm it.
    @discardableResult
    private func reconcileAOBindingClaims(now: Date) -> Bool {
        var changed = false
        var byNative: [String: AOBinding] = aoBindings
        for (id, session) in byID where !session.isAOPlaceholder {
            if let binding = session.aoBinding { byNative[id] = binding }
        }
        var byAO: [String: [(nativeID: String, binding: AOBinding)]] = [:]
        for (nativeID, binding) in byNative {
            byAO[binding.sessionID, default: []].append((nativeID, binding))
        }
        for (_, claims) in byAO {
            let active = claims.filter { $0.binding.supersededAt == nil }
            let conflict = active.count > 1 || active.contains { $0.binding.conflictedAt != nil }
            for claim in claims {
                var binding = claim.binding
                if binding.supersededAt == nil, conflict, binding.conflictedAt == nil {
                    binding.conflictedAt = now
                    changed = true
                }
                if let session = byID[claim.nativeID] {
                    if session.aoBinding != binding {
                        var updated = session
                        updated.aoBinding = binding
                        if !binding.isCurrent { updated.aoObservation = nil }
                        byID[claim.nativeID] = updated
                        changed = true
                    } else if !binding.isCurrent, session.aoObservation != nil {
                        var updated = session
                        updated.aoObservation = nil
                        byID[claim.nativeID] = updated
                        changed = true
                    }
                } else if aoBindings[claim.nativeID] != binding {
                    aoBindings[claim.nativeID] = binding
                    changed = true
                }
            }
        }
        return changed
    }

    private func updatePlaceholder(_ session: inout AgentSession, with observation: AOHostObservation,
                                   before: AgentSession?) {
        let state = AOHostMapping.state(for: observation)
        let message = AOHostMapping.message(for: observation)
        let oldState = before?.state ?? state
        let oldBinding = session.aoBinding
        let sameBinding = oldBinding.map {
            $0.sessionID == observation.sessionID
                && $0.projectID == observation.projectID
                && $0.agentKind == session.agentKind
                && $0.origin == .hostObservation
                && $0.isCurrent
        } ?? false
        if !sameBinding {
            session.aoBinding = AOBinding(sessionID: observation.sessionID,
                                          projectID: observation.projectID,
                                          agentKind: session.agentKind,
                                          origin: .hostObservation,
                                          boundAt: observation.observedAt)
        }
        session.aoObservation = observation
        session.title = observation.displayName ?? session.title
        session.message = message
        session.state = state
        // Active/waiting hosts are live evidence and may refresh the heartbeat;
        // an idle/no-signal row ages from its durable AO timestamp so an old
        // unknown row cannot linger forever.
        if state == .working || state == .waiting {
            session.updatedAt = max(session.updatedAt, observation.observedAt)
        } else {
            session.updatedAt = max(session.updatedAt, observation.updatedAt)
        }
        if state != oldState { session.stateSince = observation.activityAt ?? observation.updatedAt }
        session.turnStartedAt = state == .working ? (observation.activityAt ?? observation.updatedAt) : nil
        // AO never proves a successful/failed native turn. The timer freezes for
        // non-working host states without setting taskResult.
        session.turnEndedAt = state == .working ? nil : observation.updatedAt
        if before == nil {
            session.notificationVersion = state == .waiting ? 1 : 0
            session.displayRevision = 1
        } else if state != oldState || session.message != before?.message {
            if state == .waiting && oldState != .waiting { session.notificationVersion += 1 }
            session.displayRevision = (session.displayRevision ?? 0) + 1
        }
    }

    private static func binding(_ binding: AOBinding, matches observation: AOHostObservation) -> Bool {
        (binding.projectID == nil || binding.projectID == observation.projectID)
            && (binding.agentKind == .unknown
                || binding.agentKind == AOHostMapping.agentKind(for: observation.harness))
    }

    /// Only a verified, materialized owner can deduplicate live host evidence.
    /// AO and native notification versions describe different rounds: never
    /// copy receipts between them. The native row keeps the host observation
    /// (including a still-current wait) and its own independent unread state.
    private func removeAOPlaceholder(for aoSessionID: String) -> Bool {
        let id = AOHostMapping.placeholderID(aoSessionID)
        guard byID[id]?.isAOPlaceholder == true else { return false }
        byID.removeValue(forKey: id)
        return true
    }
}
