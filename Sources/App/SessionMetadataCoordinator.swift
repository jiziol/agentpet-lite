import Foundation
import AgentPetCore

/// Source instance identity, independent of display filtering and message state.
struct SessionInstance: Equatable, Sendable {
    let id: String
    let kind: AgentKind
    let createdAt: Date
    init(_ session: AgentSession) { id = session.id; kind = session.agentKind; createdAt = session.createdAt }
    func matches(_ session: AgentSession?) -> Bool { session.map { SessionInstance($0) == self } ?? false }
}

/// Two background readers and a bounded, coalesced pending queue. Native event
/// ingestion/permission review has its own ordered lane and is never dropped here.
@MainActor
final class SessionMetadataCoordinator {
    private struct Key: Hashable { let id: String; let purpose: String }
    private struct Job { let key: Key; let run: () -> Task<Void, Never> }
    private var pending: [Job] = []
    private var running: [Key: Task<Void, Never>] = [:]
    private var lastRun: [Key: (SessionInstance, Date)] = [:]
    private var epoch = UUID()
    private var stopped = false
    private let current: (String) -> AgentSession?
    private let concurrency: Int
    private let capacity: Int
    let reviewQueue = DispatchQueue(label: "agentpet.codex-permission-review", qos: .utility)
    init(concurrency: Int = 2, capacity: Int = 128, current: @escaping (String) -> AgentSession?) {
        precondition(concurrency > 0 && capacity > 0)
        self.concurrency = concurrency; self.capacity = capacity; self.current = current
    }
    var pendingCount: Int { pending.count }
    var runningCount: Int { running.count }
    @discardableResult
    func read<Value: Sendable>(_ session: AgentSession, purpose: String, interval: TimeInterval = 0,
                               force: Bool = false, now: Date = Date(),
                               load: @escaping @Sendable () -> Value?,
                               apply: @escaping (Value) -> Void) -> Bool {
        guard !stopped else { return false }
        let key = Key(id: session.id, purpose: purpose)
        if !force, let last = lastRun[key], last.0.matches(session), now.timeIntervalSince(last.1) < interval { return false }
        let instance = SessionInstance(session), epoch = self.epoch
        let job = Job(key: key, run: { [weak self] in
            Task { [weak self] in
                guard let self, self.epoch == epoch, !Task.isCancelled else { return }
                let value = await Task.detached(priority: .utility) { load() }.value
                guard self.epoch == epoch else { return }
                self.running.removeValue(forKey: key)
                if !Task.isCancelled, instance.matches(self.current(instance.id)), let value { apply(value) }
                self.drain()
            }
        })
        if let index = pending.firstIndex(where: { $0.key == key }) { pending[index] = job }
        else {
            guard pending.count < capacity else { return false } // retry on the next refresh/event
            pending.append(job)
        }
        lastRun[key] = (instance, now)
        drain()
        return true
    }
    func retain(_ sessions: [AgentSession]) {
        let ids = Set(sessions.map(\.id))
        pending.removeAll { !ids.contains($0.key.id) }
        lastRun = lastRun.filter { ids.contains($0.key.id) }
        // Running I/O remains bounded; the instance check rejects removed/replaced results.
    }
    func stop() {
        stopped = true; epoch = UUID(); pending.removeAll(); lastRun.removeAll()
        for task in running.values { task.cancel() }; running.removeAll()
    }
    private func drain() {
        while !stopped, running.count < concurrency,
              let index = pending.firstIndex(where: { running[$0.key] == nil }) {
            let job = pending.remove(at: index); running[job.key] = job.run()
        }
    }
}
