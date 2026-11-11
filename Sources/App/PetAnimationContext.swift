import Foundation
import AgentPetCore

struct PetAnimationCue: Equatable {
    let id: String
    let key: String
}

/// Snapshot of semantic activity/receipts, separate from the legacy PetMood enum.
struct PetAnimationContext: Equatable {
    struct Result: Equatable {
        let id: String
        let key: String
        let unread: Bool
        let endedAt: Date
    }
    var baseKey = "idle"
    var baseTrigger = "idle"
    var results: [Result] = []
    var cue: PetAnimationCue? = nil
    var quotaReminderEnabled = true

    init(sessions: [AgentSession] = [], cue: PetAnimationCue? = nil, quotaReminderEnabled: Bool = true) {
        self.cue = cue
        self.quotaReminderEnabled = quotaReminderEnabled
        let active = sessions.filter { $0.state == .working || $0.state == .waiting }
        if active.contains(where: { $0.state == .waiting }) { baseKey = "waiting" }
        else if !active.isEmpty { baseKey = "working" }
        baseTrigger = baseKey + active.map {
            "\($0.id):\($0.createdAt.timeIntervalSince1970):\($0.turnStartedAt?.timeIntervalSince1970 ?? 0):\($0.state.rawValue):\($0.notificationVersion)"
        }.sorted().joined(separator: "|")
        results = sessions.compactMap { session -> Result? in
            guard session.state == .done || session.state == .idle,
                  session.opencodeDisconnectedAt == nil, session.dshDisconnectedAt == nil,
                  let result = session.taskResult else { return nil }
            let key = result == .completed ? "success" : "failure"
            let ended = session.turnEndedAt ?? session.stateSince
            let id = "\(session.id):\(session.createdAt.timeIntervalSince1970):\(session.turnStartedAt?.timeIntervalSince1970 ?? 0):\(ended.timeIntervalSince1970):\(session.codexTurnID ?? session.opencodeTurnID ?? ""): \(session.notificationVersion):\(result.rawValue)"
            return Result(id: id, key: key, unread: !session.isStopped && session.indicator == .unread, endedAt: ended)
        }.sorted { $0.endedAt == $1.endedAt ? $0.id < $1.id : $0.endedAt < $1.endedAt }
        if results.count > 128 { results = Array(results.suffix(128)) }
    }
    var latestUnread: Result? { results.last(where: \.unread) }
}
