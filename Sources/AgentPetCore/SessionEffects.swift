import Foundation

struct ProcessLivenessObservation: Sendable {
    let alive: Bool?
    let startedAt: Date?
}

struct SessionArchiveRequest: Sendable {
    let session: AgentSession
    let endedAt: Date
    let saveAfterRemoval: Bool
}

enum SessionEffect {
    case saveSnapshot(SessionSnapshotDTO)
    case archive(SessionArchiveRequest)
    case retryArchives
    case pruneCheckpoint([String: AgentSession])
}

struct ArchiveRetryResult {
    let sessionID: String
    let result: SessionArchiveResult
}

struct ArchiveEffectReceipt {
    let request: SessionArchiveRequest
    let result: SessionArchiveResult
}

struct LivenessEffectReceipt {
    let expected: AgentSession
    let observation: ProcessLivenessObservation
}

/// Snapshot identity is conservative: metadata edits also invalidate an old
/// removal receipt. A later eligible prune can re-request that current value.
final class ArchiveEffectExecutor {
    var store: SessionArchiveStore?
    private var pendingRemoval: [String: SessionArchiveRequest] = [:]

    func execute(_ request: SessionArchiveRequest) -> ArchiveEffectReceipt {
        let result = store?.archive(request.session, startedAt: request.session.createdAt,
                                    endedAt: request.endedAt) ?? .alreadyArchived
        if result == .failed && pendingRemoval[request.session.id] == nil {
            pendingRemoval[request.session.id] = request
        } else if result.safelyRetained {
            pendingRemoval.removeValue(forKey: request.session.id)
        }
        return ArchiveEffectReceipt(request: request, result: result)
    }

    func retry() -> [ArchiveEffectReceipt] {
        var receipts: [ArchiveEffectReceipt] = []
        for result in store?.retryPendingReceipts() ?? [] where result.result.safelyRetained {
            guard let request = pendingRemoval.removeValue(forKey: result.sessionID) else { continue }
            receipts.append(ArchiveEffectReceipt(request: request, result: result.result))
        }
        return receipts
    }

    func retainSessionIDs(_ ids: Set<String>) {
        pendingRemoval = pendingRemoval.filter { ids.contains($0.key) }
    }
}

enum LivenessEffectExecutor {
    static func observe(_ session: AgentSession, processIsAlive: (Int32) -> Bool?) -> LivenessEffectReceipt? {
        guard let pid = session.opencodeProcessID else { return nil }
        let alive = processIsAlive(pid)
        let birth = alive == true && session.opencodeProcessStartedAt != nil ? OpencodeLiveness.processStartedAt(pid) : nil
        return LivenessEffectReceipt(expected: session,
            observation: ProcessLivenessObservation(alive: alive, startedAt: birth))
    }
}
