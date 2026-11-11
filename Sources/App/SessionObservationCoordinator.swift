import Foundation
import AgentPetCore

/// A small synchronized fence only for crossing native watcher queues. Source
/// parsers keep their existing cursors, ordering, bounded tails and cancellation rules.
private final class ObservationInstanceFence: @unchecked Sendable {
    private let lock = NSLock()
    private var instances: [String: SessionInstance] = [:]
    func replace(_ sessions: [AgentSession]) {
        lock.lock(); defer { lock.unlock() }
        instances = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, SessionInstance($0)) })
    }
    func get(_ id: String) -> SessionInstance? { lock.lock(); defer { lock.unlock() }; return instances[id] }
}

/// Observer ownership follows Store sessions, including hidden unbound Codex
/// completions. UI visibility/occlusion never stops native observation.
@MainActor
final class SessionObservationCoordinator {
    private let fence = ObservationInstanceFence()
    private var instances: [String: SessionInstance] = [:]
    private var codexPaths: [String: String] = [:]
    private var stopped = false
    var trackedIDs: Set<String> { Set(instances.keys) }
    private let receive: (SessionObservation) -> Void
    private let human: (String, AgentKind, HumanIntervention, Date) -> Void
    private let current: (String) -> AgentSession?
    private let message: (String, CodexVisibleMessage) -> Void
    private let agyMessage: (String, AntigravityVisibleMessage) -> Void
    private let agySpeechPath: (String) -> String?
    private var messagesEnabledAt: Date?
    init(current: @escaping (String) -> AgentSession?, receive: @escaping (SessionObservation) -> Void,
         human: @escaping (String, AgentKind, HumanIntervention, Date) -> Void,
         message: @escaping (String, CodexVisibleMessage) -> Void = { _, _ in },
         agyMessage: @escaping (String, AntigravityVisibleMessage) -> Void = { _, _ in },
         agySpeechPath: @escaping (String) -> String? = { AntigravityHumanInput.databasePath(sessionID: $0) }) {
        self.current = current; self.receive = receive; self.human = human; self.message = message
        self.agyMessage = agyMessage
        self.agySpeechPath = agySpeechPath
    }
    private lazy var agySpeech = AntigravitySpeechWatcher { [weak self] id, message in
        Task { @MainActor [weak self] in
            guard let self, !self.stopped, self.messagesEnabledAt == message.boundary.enabledAt,
                  let session = self.current(id), message.boundary.matches(session) else { return }
            self.agyMessage(id, message)
        }
    }
    private lazy var aion = AionUiCancellationLogWatcher { [weak self] signal in
        Task { @MainActor [weak self] in self?.deliver(.init(.aionUiCancellation(signal), observedAt: Date()), instance: nil) }
    }
    private lazy var agyLogs: AntigravityCancellationLogWatcher = {
        let fence = self.fence
        return AntigravityCancellationLogWatcher { [weak self] signal in
            let instance = fence.get(signal.sessionID)
            Task { @MainActor [weak self] in self?.deliver(.init(.antigravityLog(signal), observedAt: Date()), instance: instance) }
        }
    }()
    private struct CodexBinding { let instance: SessionInstance; let watcher: CodexLifecycleWatcher }
    private struct AgyBinding { let instance: SessionInstance; let watcher: AntigravityHumanInputWatcher }
    private var codexBindings: [String: CodexBinding] = [:]
    private var agyBindings: [String: AgyBinding] = [:]
    private func codexWatcher(_ session: AgentSession) -> CodexLifecycleWatcher {
        let instance = SessionInstance(session)
        if let binding = codexBindings[session.id], binding.instance == instance { return binding.watcher }
        codexBindings.removeValue(forKey: session.id)?.watcher.retainObservationIDs([])
        let watcher = CodexLifecycleWatcher(inputHandler: { [weak self] id, change, at in
            Task { @MainActor [weak self] in self?.deliverHuman(id, kind: .codex, change: change, at: at, instance: instance) }
        }, messageHandler: { [weak self] id, message in
            Task { @MainActor [weak self] in
                guard let self, self.accepts(instance),
                      let floor = self.messagesEnabledAt, message.timestamp >= floor else { return }
                self.message(id, message)
            }
        }) { [weak self] id, event in
            Task { @MainActor [weak self] in self?.deliver(.init(.codexLifecycle(sessionID: id, event), observedAt: Date()), instance: instance) }
        }
        watcher.setMessagesEnabled(messagesEnabledAt != nil)
        codexBindings[session.id] = CodexBinding(instance: instance, watcher: watcher)
        return watcher
    }
    private func agyWatcher(_ session: AgentSession) -> AntigravityHumanInputWatcher? {
        let instance = SessionInstance(session)
        if let binding = agyBindings[session.id], binding.instance == instance { return binding.watcher }
        agyBindings.removeValue(forKey: session.id)?.watcher.retainObservationIDs([])
        guard agyBindings.count < 64 else { return nil } // retain the existing aggregate limit
        let watcher = AntigravityHumanInputWatcher(cancellationHandler: { [weak self] id, signal in
            Task { @MainActor [weak self] in self?.deliver(.init(.antigravitySQLite(sessionID: id, signal), observedAt: Date()), instance: instance) }
        }) { [weak self] id, change, at in
            Task { @MainActor [weak self] in self?.deliverHuman(id, kind: .antigravity, change: change, at: at, instance: instance) }
        }
        agyBindings[session.id] = AgyBinding(instance: instance, watcher: watcher)
        return watcher
    }
    private func accepts(_ instance: SessionInstance?) -> Bool {
        guard !stopped, let instance, instance.matches(current(instance.id)) else { return false }
        return true // Native turn/request timestamps may legitimately precede the first Hook.
    }
    private func deliver(_ observation: SessionObservation, instance: SessionInstance?) {
        if case .aionUiCancellation(let signal) = observation.payload {
            guard !stopped, current(signal.conversation.nativeSessionID)?.createdAt == signal.createdAt else { return }
        } else { guard accepts(instance) else { return } }
        receive(observation)
    }
    private func deliverHuman(_ id: String, kind: AgentKind, change: HumanIntervention, at: Date, instance: SessionInstance?) {
        guard accepts(instance), instance?.kind == kind else { return }
        human(id, kind, change, at)
    }
    func watchCodex(_ session: AgentSession, path: String) {
        guard !stopped else { return }
        instances[session.id] = SessionInstance(session)
        fence.replace(instances.values.compactMap { current($0.id) })
        codexPaths[session.id] = path
        codexWatcher(session).watch(sessionID: session.id, path: path)
    }

    func setMessagesEnabled(_ enabled: Bool) {
        messagesEnabledAt = enabled ? Date() : nil
        for binding in codexBindings.values { binding.watcher.setMessagesEnabled(enabled) }
        reconcile(instances.values.compactMap { current($0.id) })
    }

    func reconcile(_ sessions: [AgentSession]) {
        guard !stopped else { return }
        let next = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, SessionInstance($0)) })
        let changed = Set(instances.keys.filter { next[$0] != instances[$0] })
        codexPaths = codexPaths.filter { next[$0.key] != nil && !changed.contains($0.key) }
        instances = next; fence.replace(sessions)
        let codexIDs = Set(sessions.filter { $0.agentKind == .codex }.map(\.id))
        for id in Array(codexBindings.keys) where !codexIDs.contains(id) || changed.contains(id) {
            codexBindings.removeValue(forKey: id)?.watcher.retainObservationIDs([])
        }
        for session in sessions where codexIDs.contains(session.id) {
            if let path = codexPaths[session.id] { codexWatcher(session).watch(sessionID: session.id, path: path) }
        }
        let agy = sessions.filter { $0.agentKind == .antigravity }
        let agyIDs = Set(agy.map(\.id))
        let speech = agy.compactMap { session in
            messagesEnabledAt.flatMap { AntigravityVisibleMessage.Boundary(session: session, enabledAt: $0) }
        }
        agySpeech.retain(sessionIDs: Set(speech.map(\.sessionID)))
        for boundary in speech {
            if let path = agySpeechPath(boundary.sessionID) {
                agySpeech.watch(path: path, boundary: boundary)
            }
        }
        for id in Array(agyBindings.keys) where !agyIDs.contains(id) || changed.contains(id) {
            agyBindings.removeValue(forKey: id)?.watcher.retainObservationIDs([])
        }
        let active = agy.filter { $0.state == .working || $0.state == .waiting }
        let hosted = active.filter { $0.validAionUiConversation != nil }
        aion.retainObservationIDs(Set(hosted.compactMap { $0.validAionUiConversation?.id }))
        for session in hosted { aion.watch(session) }
        agyLogs.retainObservationIDs(Set(active.map(\.id)).subtracting(changed))
        for session in active { agyLogs.watch(sessionID: session.id, latestHookAt: session.antigravityEventAt ?? session.updatedAt) }
        for session in agy {
            if let path = AntigravityHumanInput.databasePath(sessionID: session.id) {
                agyWatcher(session)?.watch(sessionID: session.id, path: path, pending: session.humanRequests ?? [],
                    latestHookAt: session.antigravityEventAt ?? session.updatedAt, stepFloor: session.antigravityStepFloor)
            }
        }
    }
    func stop() {
        stopped = true; instances.removeAll(); codexPaths.removeAll(); fence.replace([])
        for binding in codexBindings.values { binding.watcher.retainObservationIDs([]) }
        for binding in agyBindings.values { binding.watcher.retainObservationIDs([]) }
        codexBindings.removeAll(); agyBindings.removeAll()
        agyLogs.retainObservationIDs([]); aion.retainObservationIDs([])
        agySpeech.retain(sessionIDs: [])
    }
}
