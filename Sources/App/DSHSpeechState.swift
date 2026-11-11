import Foundation
import AgentPetCore

/// Wait briefly for the ordered metadata frame; reject other Hosts/turns and history.
struct DSHSpeechState {
    private struct Key: Hashable { let host: String; let session: String; let item: String }
    private var pending: [Key: DSHVisibleMessage] = [:]
    private var floor: Date = .distantFuture
    var count: Int { pending.count }
    mutating func reset(enabled: Bool, now: Date) {
        pending.removeAll(); floor = enabled ? now : .distantFuture
    }
    mutating func receive(_ messages: [DSHVisibleMessage], now: Date) {
        pending = pending.filter { fresh($0.value, now: now) }
        for message in messages where fresh(message, now: now) {
            let key = Key(host: message.hostID, session: message.sessionKey, item: message.itemID)
            if let old = pending[key], old.revision >= message.revision { continue }
            guard pending[key] != nil || pending.count < 128 else { continue }
            pending[key] = message
        }
    }
    mutating func drain(sessions: [AgentSession], now: Date) -> [(DSHVisibleMessage, AgentSession)] {
        let current = Dictionary(sessions.filter { $0.agentKind == .dsh }.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        var ready: [(DSHVisibleMessage, AgentSession)] = []
        for (key, message) in pending {
            guard fresh(message, now: now) else { pending.removeValue(forKey: key); continue }
            guard let session = current[message.sessionKey], let dsh = session.dsh else { continue }
            guard !session.isCodexInternalTask else { pending.removeValue(forKey: key); continue }
            guard dsh.hostID == message.hostID, dsh.hostStartedAt == message.hostStartedAt,
                  dsh.profileID == message.profileID, dsh.nativeSessionID == message.sessionID,
                  session.dshDisconnectedAt == nil, session.taskResult != .cancelled,
                  dsh.result != .failed && dsh.result != .unknown,
                  message.timestamp >= (session.turnStartedAt ?? session.createdAt) else {
                pending.removeValue(forKey: key); continue
            }
            if dsh.turn != message.turn {
                if (dsh.turn ?? -1) > message.turn { pending.removeValue(forKey: key) }
                continue
            }
            guard dsh.nativeSeq >= message.nativeSeq, dsh.revision >= message.observationRevision else { continue }
            ready.append((message, session)); pending.removeValue(forKey: key)
        }
        return ready.sorted { $0.0.timestamp == $1.0.timestamp ? $0.0.revision < $1.0.revision : $0.0.timestamp < $1.0.timestamp }
    }
    private func fresh(_ message: DSHVisibleMessage, now: Date) -> Bool {
        message.timestamp >= floor && message.timestamp <= now.addingTimeInterval(2) &&
            message.timestamp.addingTimeInterval(PetSpeechState.duration) > now
    }
}
