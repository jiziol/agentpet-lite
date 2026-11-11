import Foundation
import AgentPetCore

/// Local presentation receipts. Keep lifecycle tracking intact so a heartbeat
/// cannot recreate a cleared result, and a new turn can become visible normally.
struct EndedTaskDismissalState {
    private struct Record: Codable, Equatable {
        let id: String
        let kind: String
        let turn: String?
        let startedAt: Date?
        let notificationVersion: Int
        let result: String?
        let clearedAt: Date
    }
    static let defaultsKey = "agentpet.clearedEndedTasks.v1"
    // A remote workday can accumulate hundreds of unread results. The old
    // 128-record cap made a bulk clear immediately resurrect older results.
    static let maxRecords = 4096
    static let maxDataBytes = 8 * 1024 * 1024
    private var records: [String: Record] = [:]
    private(set) var revision = 0
    var count: Int { records.count }

    init(data: Data? = nil) {
        guard let data, data.count <= Self.maxDataBytes,
              let values = try? JSONDecoder().decode([Record].self, from: data), values.count <= Self.maxRecords else { return }
        for record in values where !record.id.isEmpty && record.id.utf8.count <= 512 &&
            (record.turn?.utf8.count ?? 0) <= 256 && record.notificationVersion >= 0 &&
            record.clearedAt.timeIntervalSince1970.isFinite {
            records[record.id] = record
        }
    }

    static func canClear(_ session: AgentSession) -> Bool {
        guard session.state == .done || session.state == .idle,
              session.pendingApproval == nil, (session.humanRequests ?? []).isEmpty,
              session.dsh?.pending.isEmpty != false else { return false }
        if session.agentKind == .dsh {
            guard let observation = session.dsh, observation.valid else { return false }
            // End evidence and a known outcome are different facts. An archived
            // or disconnected turn may have ended with an unknown result and
            // no navigable page; explicit local dismissal must still work.
            let nativeEnd = observation.phase == .done && observation.endedAt != nil
            let disconnectedEnd = session.dshDisconnectedAt?.timeIntervalSince1970.isFinite == true &&
                session.turnEndedAt?.timeIntervalSince1970.isFinite == true
            return nativeEnd || disconnectedEnd
        }
        guard session.dshDisconnectedAt == nil else { return false }
        return session.state == .done || session.taskResult != nil ||
            session.hasReadReceipt || session.turnEndedAt != nil
    }

    mutating func dismiss(_ sessions: [AgentSession], now: Date) {
        let before = records
        for session in sessions where Self.canClear(session) && !session.id.isEmpty && session.id.utf8.count <= 512 {
            let turn = Self.turnID(session)
            guard (turn?.utf8.count ?? 0) <= 256 else { continue }
            records[session.id] = Record(id: session.id, kind: session.agentKind.rawValue,
                turn: turn, startedAt: session.turnStartedAt, notificationVersion: session.notificationVersion,
                result: session.taskResult?.rawValue, clearedAt: now)
        }
        let oldest = records.values.sorted { $0.clearedAt == $1.clearedAt ? $0.id < $1.id : $0.clearedAt < $1.clearedAt }
        for record in oldest.prefix(max(0, records.count - Self.maxRecords)) { records.removeValue(forKey: record.id) }
        if records != before { revision += 1 }
    }

    mutating func visible(_ sessions: [AgentSession], now: Date) -> [AgentSession] {
        let before = records
        records = records.filter { $0.value.clearedAt <= now.addingTimeInterval(2) &&
            $0.value.clearedAt.addingTimeInterval(7 * 86400) > now }
        let visible = sessions.filter { session in
            guard let record = records[session.id] else { return true }
            let sameTurn: Bool
            if let turn = record.turn {
                sameTurn = turn == Self.turnID(session)
            } else {
                sameTurn = record.startedAt == session.turnStartedAt &&
                    record.notificationVersion == session.notificationVersion
            }
            guard Self.canClear(session), record.kind == session.agentKind.rawValue, sameTurn,
                  record.result == session.taskResult?.rawValue else {
                records.removeValue(forKey: session.id); return true
            }
            return false
        }
        if records != before { revision += 1 }
        return visible
    }

    func encoded() -> Data? { try? JSONEncoder().encode(Array(records.values)) }

    private static func turnID(_ session: AgentSession) -> String? {
        switch session.agentKind {
        case .codex: return session.codexTurnID
        case .opencode: return session.opencodeTurnID
        case .dsh: return session.dsh?.turn.map(String.init)
        default: return nil
        }
    }
}
