import Foundation
import AgentPetCore

/// Synthetic input only. Rendering, lamps, retention and speech admission use
/// the same policies as the desktop; no daemon, store or persistence is involved.
struct SettingsPreviewState {
    enum Status: String, CaseIterable {
        case working = "Working", waiting = "Waiting", completed = "Completed"
        case failed = "Failed", stopped = "Stopped"

        var result: CodexTurnResult? {
            switch self {
            case .completed: return .completed
            case .failed: return .failed
            case .stopped: return .cancelled
            default: return nil
            }
        }
    }

    static let maximumTasks = 24
    private(set) var sessions: [AgentSession] = []
    private var counter = 0
    private var replyCounter = 0
    private var speech = PetSpeechState()

    @discardableResult
    mutating func add(_ kind: AgentKind, now: Date) -> String? {
        guard sessions.count < Self.maximumTasks else { return nil }
        counter += 1
        let id = "preview-\(kind.rawValue)-\(counter)"
        var session = AgentSession(id: id, agentKind: kind,
            project: "preview-project", title: String(format: NSLocalizedString("Sample task %d", comment: "preview fixture"), counter),
            state: .working, source: .hook, updatedAt: now,
            terminalProgram: "AgentPet Preview")
        session.turnStartedAt = now
        session.interactionGeneration = 1
        session.displayRevision = 1
        session.message = NSLocalizedString("Working on the sample task", comment: "preview fixture")
        setNativeFields(&session, result: nil)
        sessions.append(session)
        return id
    }

    func status(of session: AgentSession) -> Status {
        if session.state == .working { return .working }
        if session.state == .waiting { return .waiting }
        switch session.taskResult {
        case .failed: return .failed
        case .cancelled: return .stopped
        default: return .completed
        }
    }

    mutating func setStatus(_ status: Status, id: String, now: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              status != self.status(of: sessions[index]) else { return }
        var session = sessions[index]
        let wasEnded = session.turnEndedAt != nil
        if wasEnded && status.result == nil {
            session.turnStartedAt = now
            session.interactionGeneration = (session.interactionGeneration ?? 0) + 1
        }
        session.state = status == .working ? .working : status == .waiting ? .waiting : .done
        session.updatedAt = now
        session.stateSince = now
        session.turnEndedAt = status.result == nil ? nil : now
        session.displayRevision = (session.displayRevision ?? 0) + 1
        session.readAt = nil
        session.readDisplayRevision = nil
        session.readThroughVersion = session.notificationVersion
        if status != .working { session.notificationVersion += 1 }
        session.humanRequests = status == .waiting
            ? [HumanRequest(id: "preview-reply", kind: .reply, createdAt: now)] : []
        session.message = session.humanRequests?.last?.message
            ?? NSLocalizedString(status == .working ? "Working on the sample task" : status.rawValue,
                                 comment: "preview fixture")
        setNativeFields(&session, result: status.result)
        sessions[index] = session
        speech.reconcile(sessions, now: now)
    }

    /// Represents a successful click acknowledgement inside this sandbox only.
    /// Pending requests and the native task state stay intact, just as markOpened.
    mutating func markRead(_ id: String, now: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].readThroughVersion = sessions[index].notificationVersion
        sessions[index].readAt = now
        sessions[index].readDisplayRevision = sessions[index].displayRevision ?? 0
    }

    mutating func remove(_ id: String, now: Date) {
        sessions.removeAll { $0.id == id }
        speech.reconcile(sessions, now: now)
    }

    mutating func clear() {
        sessions.removeAll()
        speech.clear()
    }

    mutating func reply(to id: String, duration: TimeInterval, now: Date) {
        guard let session = sessions.first(where: { $0.id == id }),
              session.taskResult != .failed && session.taskResult != .cancelled else { return }
        replyCounter += 1
        speech.setDuration(duration)
        let turnID = session.agentKind == .opencode ? session.opencodeTurnID : session.codexTurnID
        let candidate = PetSpeechState.Candidate(
            fence: .init(session, turnID: turnID), itemID: "preview-reply-\(replyCounter)",
            timestamp: now, revision: 0,
            content: .snapshot(NSLocalizedString("Sample reply: the requested change is ready for review.", comment: "preview fixture")))
        speech.receive(candidate, session: session, now: now)
    }

    mutating func advance(now: Date) { speech.reconcile(sessions, now: now) }
    func visibleReplies(hiddenKinds: Set<AgentKind>, showTeams: Bool = true, now: Date) -> [PetSpeechState.Row] {
        speech.visible(sessions: sessions, hiddenKinds: hiddenKinds, showTeams: showTeams, now: now)
    }

    private func setNativeFields(_ session: inout AgentSession, result: CodexTurnResult?) {
        let turn = "preview-turn-\(session.interactionGeneration ?? 1)"
        switch session.agentKind {
        case .codex:
            session.codexTurnID = turn
            session.codexTurnResult = result
        case .opencode:
            session.opencodeTurnID = turn
            session.opencodeTurnResult = result
        case .antigravity:
            session.antigravityStepFloor = session.interactionGeneration ?? 1
            session.antigravityTurnResult = result
        case .pi:
            session.piTurnResult = result
        case .dsh:
            // DSHObservation has no public memberwise initializer. Decode this
            // synthetic wire fixture, then use the native taskResult projection.
            var object: [String: Any] = [
                "schema": 1, "profileID": String(repeating: "0", count: 24),
                "hostID": "00000000-0000-0000-0000-000000000001",
                "hostStartedAt": session.createdAt.timeIntervalSinceReferenceDate,
                "nativeSessionID": session.id, "revision": session.displayRevision ?? 1,
                "nativeSeq": session.displayRevision ?? 1, "turn": session.interactionGeneration ?? 1,
                "phase": result == nil ? "working" : "done",
                "pending": (session.humanRequests ?? []).map { ["id": $0.id, "kind": $0.kind.rawValue] },
                "startedAt": (session.turnStartedAt ?? session.createdAt).timeIntervalSinceReferenceDate,
                "baseline": false, "heartbeat": false, "gap": false,
                "navigationSocket": "/tmp/agentpet-dsh-0/h-preview/nav.sock"
            ]
            if let result { object["result"] = result.rawValue }
            if let ended = session.turnEndedAt { object["endedAt"] = ended.timeIntervalSinceReferenceDate }
            session.dsh = (try? JSONSerialization.data(withJSONObject: object))
                .flatMap { try? JSONDecoder().decode(DSHObservation.self, from: $0) }
        default:
            session.codexTurnResult = result
        }
    }
}
