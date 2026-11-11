import Foundation
import AgentPetCore

/// Holds only fresh text while its independent lifecycle hook catches up.
struct OpencodeSpeechState {
    private struct Key: Hashable { let session: String; let part: String }
    private var pending: [Key: OpencodeVisibleMessage] = [:]
    private var floor: Date = .distantFuture
    private var known: Set<String> = []
    var count: Int { pending.count }
    mutating func reset(enabled: Bool, now: Date) {
        pending.removeAll(); known.removeAll()
        floor = enabled ? now : .distantFuture
    }
    mutating func receive(_ messages: [OpencodeVisibleMessage], now: Date) {
        pending = pending.filter { fresh($0.value, now: now) }
        for message in messages where fresh(message, now: now) {
            let key = Key(session: message.sessionID, part: message.partID)
            if let old = pending[key], old.timestamp > message.timestamp ||
                (old.timestamp == message.timestamp && old.revision >= message.revision) { continue }
            guard pending[key] != nil || pending.count < 128 else { continue }
            pending[key] = message
        }
    }
    mutating func drain(sessions: [AgentSession], now: Date) -> [(OpencodeVisibleMessage, AgentSession)] {
        let current = Dictionary(sessions.filter { $0.agentKind == .opencode && !$0.isOpencodeSubagent }.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let removed = known.subtracting(current.keys)
        known = Set(current.keys)
        var ready: [(OpencodeVisibleMessage, AgentSession)] = []
        for (key, message) in pending {
            guard fresh(message, now: now), !removed.contains(message.sessionID) else {
                pending.removeValue(forKey: key); continue
            }
            guard let session = current[message.sessionID] else { continue }
            guard session.opencodeTurnID == message.turnID else {
                // A newer text frame may precede its new-turn hook; retain it briefly.
                if message.timestamp < (session.turnStartedAt ?? session.createdAt) { pending.removeValue(forKey: key) }
                continue
            }
            guard session.opencodeDisconnectedAt == nil, session.taskResult != .cancelled else {
                pending.removeValue(forKey: key); continue
            }
            guard session.opencodeProcessID == message.processID,
                  message.timestamp >= (session.turnStartedAt ?? session.createdAt),
                  session.opencodeProcessStartedAt.map({ $0 <= message.timestamp }) ?? true else {
                pending.removeValue(forKey: key); continue
            }
            ready.append((message, session)); pending.removeValue(forKey: key)
        }
        return ready.sorted { $0.0.timestamp == $1.0.timestamp ? $0.0.revision < $1.0.revision : $0.0.timestamp < $1.0.timestamp }
    }
    private func fresh(_ message: OpencodeVisibleMessage, now: Date) -> Bool {
        message.timestamp >= floor && message.timestamp <= now.addingTimeInterval(2) &&
            message.timestamp.addingTimeInterval(PetSpeechState.duration) > now
    }
}
