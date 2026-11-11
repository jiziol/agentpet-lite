import Foundation
import AgentPetCore

/// Volatile display state. All callers are owned by the main actor; no text is persisted.
struct PetSpeechState {
    struct SessionKey: Hashable {
        let id: String
        let createdAt: Date
        let kind: AgentKind
        init(_ session: AgentSession) {
            id = session.id; createdAt = session.createdAt; kind = session.agentKind
        }
    }
    struct Fence: Equatable {
        let key: SessionKey
        let generation: Int?
        let startedAt: Date?
        let turnID: String?
        let nativeStart: Date?
        let agyStepFloor: Int?
        let dshHostID: String?
        init(_ session: AgentSession, turnID: String? = nil, nativeStart: Date? = nil) {
            key = SessionKey(session); generation = session.interactionGeneration
            startedAt = session.turnStartedAt
            self.turnID = turnID ?? (session.agentKind == .dsh ? session.dsh?.turn.map(String.init) : nil)
            dshHostID = session.agentKind == .dsh ? session.dsh?.hostID : nil
            self.nativeStart = nativeStart
            agyStepFloor = session.agentKind == .antigravity ? session.antigravityStepFloor : nil
        }
        func matches(_ session: AgentSession) -> Bool {
            guard !session.isCodexInternalTask,
                  key == SessionKey(session), generation == session.interactionGeneration,
                  startedAt == session.turnStartedAt,
                  session.taskResult != .cancelled else { return false }
            if key.kind == .opencode { return !session.isOpencodeSubagent && session.opencodeTurnID == turnID && session.opencodeDisconnectedAt == nil }
            if key.kind == .antigravity {
                return agyStepFloor != nil && agyStepFloor == session.antigravityStepFloor
                    && [.working, .waiting, .done].contains(session.state)
            }
            if key.kind == .dsh {
                return dshHostID != nil && dshHostID == session.dsh?.hostID &&
                    session.dsh?.turn.map(String.init) == turnID && session.dshDisconnectedAt == nil &&
                    session.dsh?.result != .failed && session.dsh?.result != .unknown
            }
            guard key.kind == .codex else { return true }
            return session.codexTurnID.map { $0 == turnID }
                ?? (nativeStart != nil && session.codexLifecycleAt == nativeStart && session.turnEndedAt == nil)
        }
    }
    struct Candidate {
        enum Content { case snapshot(String), delta(String), withdraw }
        let fence: Fence
        let itemID: String
        let timestamp: Date
        let revision: Int
        let content: Content
    }
    struct Row: Identifiable, Equatable {
        let id: UUID
        let session: SessionKey
        let label: String
        let itemID: String
        var text: String
        let expiresAt: Date
    }
    private struct Channel {
        var fence: Fence
        let number: Int
        var timestamp: Date = .distantPast
        var revision = -1
        var itemID = ""
        var buffer = ""
        var pending = false
        var lastAdmittedItem = ""
        var nextAllowed: Date = .distantPast
    }
    static let duration: TimeInterval = 5
    static let sessionCooldown: TimeInterval = 2
    static let globalCooldown: TimeInterval = 0.5
    static let maximumRows = 6
    static let maximumChannels = 128
    private(set) var rows: [Row] = []
    private var channels: [SessionKey: Channel] = [:]
    private var rotation: [SessionKey] = []
    private var numbers: [AgentKind: Int] = [:]
    private let admissionInterval: TimeInterval
    private(set) var displayDuration: TimeInterval
    init(globalCooldown: TimeInterval = Self.globalCooldown, duration: TimeInterval = Self.duration) {
        admissionInterval = globalCooldown
        displayDuration = duration.isFinite ? min(max(duration, 3), 10) : Self.duration
    }
    // Existing rows retain their original deadline; updates never renew them.
    mutating func setDuration(_ duration: TimeInterval) {
        displayDuration = duration.isFinite ? min(max(duration, 3), 10) : Self.duration
    }
    private var nextGlobal: Date = .distantPast
    private(set) var importantUntil: Date?
    private var importantControlled = false
    var channelCount: Int { channels.count }

    mutating func receive(_ message: CodexVisibleMessage, session: AgentSession, now: Date) {
        receive(Candidate(fence: Fence(session, turnID: message.turnID, nativeStart: message.turnStartedAt),
            itemID: "\(message.phase):\(message.timestamp.timeIntervalSince1970)",
            timestamp: message.timestamp, revision: 0, content: .snapshot(message.text)), session: session, now: now)
    }

    mutating func receive(_ candidate: Candidate, session: AgentSession, now: Date) {
        advance(now: now)
        guard candidate.fence.matches(session), candidate.fence.key.id.utf8.count <= 512,
              (candidate.fence.turnID?.utf8.count ?? 0) <= 256, candidate.itemID.utf8.count <= 256,
              !candidate.itemID.isEmpty, candidate.timestamp >= (session.turnStartedAt ?? session.createdAt),
              candidate.timestamp <= now.addingTimeInterval(2),
              candidate.timestamp.addingTimeInterval(displayDuration) > now else { return }
        let key = candidate.fence.key
        if case .withdraw = candidate.content {
            guard var channel = channels[key], channel.fence == candidate.fence,
                  candidate.timestamp > channel.timestamp || (candidate.timestamp == channel.timestamp && candidate.revision > channel.revision) else { return }
            rows.removeAll { $0.session == key && $0.itemID == candidate.itemID }
            // Removing the visible older part must not discard a newer pending part.
            guard channel.itemID == candidate.itemID else { return }
            channel.pending = false; channel.buffer = ""
            channel.lastAdmittedItem = candidate.itemID
            channel.timestamp = candidate.timestamp; channel.revision = candidate.revision
            channels[key] = channel
            return
        }
        if channels[key] == nil {
            guard channels.count < Self.maximumChannels else { return }
            let number = (numbers[key.kind] ?? 0) + 1
            numbers[key.kind] = number
            channels[key] = Channel(fence: candidate.fence, number: number)
            rotation.append(key)
        }
        guard var channel = channels[key] else { return }
        if channel.fence != candidate.fence {
            rows.removeAll { $0.session == key }
            channel = Channel(fence: candidate.fence, number: channel.number)
        }
        guard candidate.timestamp > channel.timestamp
            || (candidate.timestamp == channel.timestamp && candidate.itemID == channel.itemID && candidate.revision > channel.revision)
        else { return }
        switch candidate.content {
        case .withdraw: return
        case .snapshot(let text): channel.buffer = Self.bounded(text)
        case .delta(let text):
            // A delta cannot establish an item: sources must first send a snapshot.
            guard channel.itemID == candidate.itemID else { return }
            channel.buffer = Self.bounded(channel.buffer + String(text.prefix(320)))
        }
        channel.timestamp = candidate.timestamp; channel.revision = candidate.revision
        channel.itemID = candidate.itemID
        // Important notices consume incoming revisions, but never queue a replay.
        channel.pending = importantUntil == nil && !Self.compactText(channel.buffer).isEmpty
        if importantUntil != nil { channel.lastAdmittedItem = channel.itemID }
        channels[key] = channel
        advance(now: now)
    }

    mutating func reconcile(_ sessions: [AgentSession], now: Date) {
        let current = Dictionary(sessions.map { (SessionKey($0), $0) }, uniquingKeysWith: { _, b in b })
        channels = channels.filter { current[$0.key] != nil }
        for key in Array(channels.keys) {
            guard let session = current[key], let channel = channels[key], !channel.fence.matches(session) else { continue }
            rows.removeAll { $0.session == key }
            channels[key] = Channel(fence: Fence(session, turnID: session.agentKind == .opencode ? session.opencodeTurnID : session.codexTurnID, nativeStart: session.codexLifecycleAt), number: channel.number)
        }
        rotation.removeAll { channels[$0] == nil }
        rows.removeAll { channels[$0.session] == nil }
        if channels.isEmpty { numbers.removeAll() }
        advance(now: now)
    }

    mutating func beginImportant(now: Date, controlled: Bool = false) {
        importantControlled = controlled
        importantUntil = now.addingTimeInterval(8)
        rows.removeAll()
        for key in rotation {
            channels[key]?.pending = false
            if let item = channels[key]?.itemID { channels[key]?.lastAdmittedItem = item }
        }
    }

    /// The system notice owns a visible-time budget instead of this wall clock.
    /// Keep consumed item IDs so suppressed revisions cannot replay afterwards.
    mutating func endImportant(now: Date) {
        importantControlled = false; importantUntil = nil
        advance(now: now)
    }

    mutating func advance(now: Date) {
        rows.removeAll { $0.expiresAt <= now }
        if importantControlled { return }
        if let deadline = importantUntil {
            guard deadline <= now else { return }
            importantUntil = nil
        }
        // Rotate only after a channel is served; a busy source cannot reset priority.
        for key in rotation {
            guard var channel = channels[key], channel.pending else { continue }
            if channel.timestamp.addingTimeInterval(displayDuration) <= now {
                channel.pending = false; channels[key] = channel; continue
            }
            guard channel.nextAllowed <= now else { continue }
            if let index = rows.firstIndex(where: { $0.session == key && $0.itemID == channel.itemID }) {
                rows[index].text = Self.compactText(channel.buffer)
            } else {
                // Late revisions must not resurrect an expired or displaced card.
                if channel.lastAdmittedItem == channel.itemID {
                    channel.pending = false; channels[key] = channel; continue
                }
                guard nextGlobal <= now else { continue }
                rows.removeAll { $0.session == key }
                if rows.count == Self.maximumRows { rows.removeFirst() }
                rows.append(Row(id: UUID(), session: key,
                    label: "@\(Self.name(key.kind))[\(channel.number)]", itemID: channel.itemID,
                    text: Self.compactText(channel.buffer), expiresAt: now.addingTimeInterval(displayDuration)))
                channel.lastAdmittedItem = channel.itemID
                nextGlobal = now.addingTimeInterval(admissionInterval)
            }
            channel.pending = false; channel.nextAllowed = now.addingTimeInterval(Self.sessionCooldown)
            channels[key] = channel
            rotation.removeAll { $0 == key }; rotation.append(key)
        }
    }

    mutating func clear() { self = Self(globalCooldown: admissionInterval, duration: displayDuration) }
    var nextExpiry: Date? {
        if importantControlled { return nil }
        if let importantUntil { return importantUntil }
        let pending = channels.values.filter(\.pending).map { channel in
            let update = rows.contains { $0.session == channel.fence.key && $0.itemID == channel.itemID }
            return min(channel.timestamp.addingTimeInterval(displayDuration), max(channel.nextAllowed, update ? .distantPast : nextGlobal))
        }
        return (rows.map(\.expiresAt) + pending).min()
    }
    func visible(sessions: [AgentSession], hiddenKinds: Set<AgentKind>, showTeams: Bool = true, now: Date) -> [Row] {
        guard importantUntil == nil else { return [] }
        let current = Dictionary(sessions.map { (SessionKey($0), $0) }, uniquingKeysWith: { _, b in b })
        return rows.filter { row in
            guard row.expiresAt > now, let session = current[row.session],
                  channels[row.session]?.fence.matches(session) == true else { return false }
            // A Team-scoped session is governed by its own switch: a mark that
            // is not yet verified counts as an unconfirmed member and stays
            // silent instead of falling back to the per-kind filter.
            if let team = session.hostTeamScope {
                switch team.host {
                case .aionUI: return showTeams && team.role == .lead
                case .agentOrchestrator: return team.role == .lead
                }
            }
            return !hiddenKinds.contains(session.agentKind)
        }
    }
    static func compactText(_ text: String) -> String {
        let body = bounded(text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return body.count > 20 ? String(body.prefix(19)) + "…" : body
    }
    private static func bounded(_ text: String) -> String {
        let bytes = String(decoding: text.utf8.prefix(2048), as: UTF8.self)
        let clean = bytes.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String(String.UnicodeScalarView(clean)).prefix(320))
    }
    private static func name(_ kind: AgentKind) -> String {
        switch kind {
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .antigravity: return "agy"
        case .dsh: return "DSH"
        default: return kind.rawValue.capitalized
        }
    }
}
