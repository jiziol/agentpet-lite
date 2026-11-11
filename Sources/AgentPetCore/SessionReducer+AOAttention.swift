import Foundation

/// AO attention is owned by its source, not by the native row used to show it.
extension SessionReducer {
    @discardableResult
    func recordAOAttention(in observations: [String: AOHostObservation]) -> Bool {
        var changed = false
        for observation in observations.values {
            let id = AOAttentionReceipt.sourceID(for: observation)
            let previous = aoAttentionRecords[id]
            if let previous, observation.updatedAt < previous.latestUpdatedAt { continue }
            let waitingAt = observation.activityAt ?? observation.updatedAt
            let newWait = observation.available && observation.isWaiting && !observation.isExited
                && (previous == nil || previous?.lastWasWaiting != true
                    || waitingAt > (previous?.waitingAt ?? .distantPast))
            // Never-waiting observations have no durable receipt responsibility.
            // Their ordering watermark already lives in the bounded current
            // aoSessions snapshot. Retain every existing waiting/read watermark.
            guard previous != nil || newWait else { continue }
            var history = observation
            // Persist facts/receipts, never current availability or Team authority.
            history.available = false
            history.orchestration = nil
            history.observedAt = history.updatedAt
            var record = previous ?? AOAttentionReceipt(observation: history, version: 0,
                readThroughVersion: 0, readAt: nil, waitingAt: nil, instanceID: observation.instanceID,
                lastWasWaiting: false, latestUpdatedAt: observation.updatedAt)
            // Retain the unread fact itself even if the host has since resumed.
            if record.version == 0 || newWait { record.observation = history }
            record.lastWasWaiting = observation.isWaiting && !observation.isExited
            record.latestUpdatedAt = observation.updatedAt
            if newWait {
                record.version += 1
                record.waitingAt = waitingAt
                record.instanceID = observation.instanceID
            }
            if record != previous { aoAttentionRecords[id] = record; changed = true }
        }
        return changed
    }

    @discardableResult
    func acknowledgeAO(_ clicked: AOAttentionReceipt, at: Date) -> Bool {
        guard at.timeIntervalSince1970.isFinite,
              var current = aoAttentionRecords[clicked.id], clicked.version >= 0,
              clicked.version <= current.version else { return false }
        // Only AO's own source/version is compared. An old click cannot consume
        // a newer waiting revision, even after the display owner has changed.
        let through = max(current.readThroughVersion, clicked.version)
        guard through != current.readThroughVersion else { return false }
        current.readThroughVersion = through
        current.readAt = at
        aoAttentionRecords[clicked.id] = current
        persistCodexSessions()
        return true
    }

    /// Rebuild the one-row projection after every store mutation. Keeping the
    /// canonical record outside AgentSessionDTO prevents receipt copies when a
    /// claim conflicts, is removed, reconnects, or materializes later.
    func projectAOAttention() {
        for (id, var session) in Array(byID) {
            if id.hasPrefix("ao-unread:") { byID.removeValue(forKey: id); continue }
            session.aoAttentionReceipts = session.isAOPlaceholder ? [] : nil
            byID[id] = session
        }
        for record in aoAttentionRecords.values.sorted(by: { $0.id < $1.id }) where record.version > 0 {
            let nativeOwners = byID.values.filter { session in
                guard !session.isAOPlaceholder, !session.isCodexInternalTask,
                      !session.isOpencodeSubagent, !session.isUnidentifiedCodexCompletion,
                      session.aoBinding?.isCurrent == true,
                      let observation = session.aoObservation, observation.available else { return false }
                return AOAttentionReceipt.sourceID(for: observation) == record.id
            }
            var ownerID: String?
            if nativeOwners.count == 1 { ownerID = nativeOwners[0].id }
            if ownerID == nil {
                ownerID = byID.values.first { session in
                    session.isAOPlaceholder && session.aoObservation.map {
                        AOAttentionReceipt.sourceID(for: $0) == record.id
                    } == true
                }?.id
            }
            if ownerID == nil, record.hasUnread {
                if let live = aoSessions[record.observation.sessionID], live.available,
                   AOAttentionReceipt.sourceID(for: live) == record.id {
                    let id = AOHostMapping.placeholderID(live.sessionID)
                    if byID[id] == nil {
                        byID[id] = AOHostMapping.placeholderSession(for: live)
                        ownerID = id
                    }
                }
                if ownerID == nil {
                    // Historical attention remains readable without reviving a
                    // host role or attaching it to any unverified native task.
                    var history = record.observation
                    history.available = false
                    // The durable project ID can group historical unread facts;
                    // available=false ensures this grants no live member role.
                    history.orchestration = AOHostMapping.projectGroup(for: history)
                    var row = AOHostMapping.placeholderSession(for: history)
                    row.identity = SessionIdentity(id: "ao-unread:" + record.id,
                        agentKind: row.agentKind, source: row.source, createdAt: row.createdAt,
                        agentName: row.agentName)
                    row.title = "AO 历史待办 · " + (history.displayName ?? history.sessionID)
                    byID[row.id] = row
                    ownerID = row.id
                }
            }
            if let ownerID, var owner = byID[ownerID] {
                owner.aoAttentionReceipts = (owner.aoAttentionReceipts ?? []) + [record]
                byID[ownerID] = owner
            }
        }
    }
}
