import Foundation

/// Independent AO viewing facts. AO sequence numbers stay in AO's namespace;
/// they are never compared with AgentPet notification/read-through versions.
public struct AOSessionReadFrame: Decodable, Sendable {
    public struct Turn: Decodable, Sendable {
        public let id: String
        public let providerTurnId: String?
        public let requestedAt: Double
        /// Exclusive upper bound of the AO timestamp's stated precision.
        public let completedBefore: Double
    }
    public struct Cursor: Decodable, Sendable { public let sequence: Int; public let revision: Int }
    public struct Receipt: Decodable, Sendable {
        public let sessionId: String
        public let projectId: String
        public let sessionCreatedAt: String
        public let conversationId: String
        public let branchId: String
        public let viewedAt: Double
        public let readCursor: Cursor
        public let turns: [Turn]

        public func covers(_ native: AgentSession, now: Date) -> Bool {
            guard !native.isAOPlaceholder, !native.isStopped, !native.isCodexInternalTask, !native.isOpencodeSubagent, !native.isDSHBackend,
                  native.state == .done || native.state == .idle,
                  native.notificationVersion > native.readThroughVersion,
                  native.pendingApproval == nil, (native.humanRequests ?? []).isEmpty,
                  native.aoObservationIsCurrent(at: now), let owner = native.aoObservation,
                  native.aoBinding?.isCurrent == true,
                  native.aoBinding?.sessionID == sessionId, native.aoBinding?.projectID == projectId,
                  owner.sessionID == sessionId, owner.projectID == projectId,
                  let created = AOAPIDate.parse(sessionCreatedAt), created == owner.createdAt,
                  let start = native.turnStartedAt, let end = native.turnEndedAt,
                  start <= end, end.timeIntervalSince1970 * 1000 <= viewedAt,
                  viewedAt.isFinite, viewedAt >= 0, viewedAt <= now.timeIntervalSince1970 * 1000,
                  native.readAt.map({ $0 < Date(timeIntervalSince1970: viewedAt / 1000) }) ?? true,
                  !conversationId.isEmpty, conversationId.utf8.count <= 512, branchId.utf8.count <= 512,
                  readCursor.sequence >= 0, readCursor.revision >= 0, !turns.isEmpty, turns.count <= 8 else { return false }
            let matching = turns.filter { turn in
                guard !turn.id.isEmpty, turn.id.utf8.count <= 512,
                      turn.requestedAt.isFinite, turn.completedBefore.isFinite,
                      turn.requestedAt >= 0, turn.requestedAt < turn.completedBefore,
                      start.timeIntervalSince1970 * 1000 >= turn.requestedAt,
                      end.timeIntervalSince1970 * 1000 < turn.completedBefore else { return false }
                // AO's Codex adapter retains the exact native root turn ID in
                // providerTurnId; a different turn cannot borrow a time range.
                if native.agentKind == .codex, let id = native.codexTurnID, let provider = turn.providerTurnId {
                    return provider == id || provider.hasSuffix(":root" + id)
                }
                return true
            }
            return matching.count == 1
        }
    }

    public let version: Int
    public let capabilities: [String]
    public let instanceId: String
    public let appRunId: String
    public let appPath: String
    public let pid: Int32
    public let updatedAt: Double
    public let receipts: [Receipt]
    enum CodingKeys: String, CodingKey {
        case version = "protocol", capabilities, instanceId, appRunId, appPath, pid, updatedAt, receipts
    }

    public func isCurrent(run: AORunFile, now: Date) -> Bool {
        let age = now.timeIntervalSince1970 * 1000 - updatedAt
        return version == 1 && capabilities.contains("session-read.v1")
            && UUID(uuidString: instanceId) != nil && appRunId == run.appRunID && pid > 0
            && appPath.hasPrefix("/") && appPath.hasSuffix(".app") && appPath.utf8.count <= 4096
            && updatedAt.isFinite && age >= 0 && age <= 15_000 && receipts.count <= 1024
    }
}
