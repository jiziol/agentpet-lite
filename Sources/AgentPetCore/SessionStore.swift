import Foundation

/// Queue-confined coordinator. Business transitions live in SessionReducer;
/// snapshot, archive and process IO are interpreted outside those rules.
public final class SessionStore {
    private let reducer: SessionReducer
    private let repository: SessionRepository
    private let archiveExecutor = ArchiveEffectExecutor()
    public var archiveStore: SessionArchiveStore? {
        didSet { reducer.archivingEnabled = archiveStore != nil; archiveExecutor.store = archiveStore }
    }
    public var persistenceURL: URL? {
        get { repository.url }
        set { repository.url = newValue }
    }
    public var persistenceError: String? { repository.error }
    public var snapshotSaveStatus: SnapshotSaveStatus { repository.status }
    @discardableResult
    public func flushSnapshots() -> SnapshotSaveStatus { repository.flush() }
    public var preserveReadResults: Bool {
        get { reducer.preserveReadResults }
        set { reducer.preserveReadResults = newValue }
    }
    public var doneToIdleAfter: TimeInterval {
        get { reducer.doneToIdleAfter }
        set { reducer.doneToIdleAfter = newValue }
    }
    public var removeIdleAfter: TimeInterval {
        get { reducer.removeIdleAfter }
        set { reducer.removeIdleAfter = newValue }
    }
    public var staleActiveAfter: TimeInterval {
        get { reducer.staleActiveAfter }
        set { reducer.staleActiveAfter = newValue }
    }
    public var staleRegisteredAfter: TimeInterval {
        get { reducer.staleRegisteredAfter }
        set { reducer.staleRegisteredAfter = newValue }
    }

    public init(doneToIdleAfter: TimeInterval = 30, removeIdleAfter: TimeInterval = 600,
                staleActiveAfter: TimeInterval = 300, staleRegisteredAfter: TimeInterval = 90,
                coalescesSnapshotWrites: Bool = false) {
        repository = SessionRepository(coalesces: coalescesSnapshotWrites)
        reducer = SessionReducer(doneToIdleAfter: doneToIdleAfter, removeIdleAfter: removeIdleAfter,
                                 staleActiveAfter: staleActiveAfter, staleRegisteredAfter: staleRegisteredAfter)
    }

    private func run<T>(_ transition: () -> T) -> T {
        let result = transition()
        reducer.projectAOAttention()
        drainEffects()
        return result
    }

    private func drainEffects() {
        while !reducer.effects.isEmpty {
            let effects = reducer.effects
            reducer.effects.removeAll(keepingCapacity: true)
            for effect in effects {
                switch effect {
                case .saveSnapshot(let snapshot): repository.save(snapshot)
                case .archive(let request):
                    reducer.finishArchive(archiveExecutor.execute(request))
                case .retryArchives:
                    for receipt in archiveExecutor.retry() { reducer.finishArchive(receipt, saveAfterRemoval: false) }
                case .pruneCheckpoint(let before): reducer.finishPruneCheckpoint(before)
                }
            }
        }
        archiveExecutor.retainSessionIDs(Set(reducer.sessions.map(\.id)))
    }

    public func restoreCodexSessions() {
        guard let snapshot = repository.load() else { return }
        run { reducer.restore(snapshot) }
    }

    public func persistCodexSessions() { run { reducer.persistCodexSessions() } }
    public var sessions: [AgentSession] { reducer.sessions }
    public var sorted: [AgentSession] { reducer.sorted }
    public func session(id: String) -> AgentSession? { reducer.session(id: id) }
    public func dshNavigationTarget(profileID: String, nativeSessionID: String, now: Date) -> DSHObservation? {
        reducer.dshNavigationTarget(profileID: profileID, nativeSessionID: nativeSessionID, now: now)
    }

    public func dshNavigationTarget(for clicked: AgentSession, now: Date) -> DSHObservation? {
        reducer.dshNavigationTarget(for: clicked, now: now)
    }

    @discardableResult
    public func reconcileOpencodeLiveness(now: Date,
        processIsAlive: (Int32) -> Bool? = OpencodeLiveness.processIsAlive) -> [AgentSession] {
        let receipts = reducer.sessions.filter { $0.agentKind == .opencode && !$0.isOpencodeSubagent &&
            ($0.state == .working || $0.state == .waiting) }.compactMap {
                LivenessEffectExecutor.observe($0, processIsAlive: processIsAlive)
            }
        return run { reducer.reconcileOpencodeLiveness(now: now, receipts: receipts) }
    }
    public func updateCodexMetadata(id: String, record: CodexMetadata.Record, home: String) {
        run { reducer.updateCodexMetadata(id: id, record: record, home: home) }
    }

    @discardableResult
    public func applyCodexInternalTaskEvidence(expected: AgentSession,
                                               evidence: CodexInternalTaskEvidence.Record) -> Bool {
        run { reducer.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence) }
    }

    @discardableResult
    public func updateOpencodeParent(id: String, createdAt: Date, parentID: String) -> Bool {
        run { reducer.updateOpencodeParent(id: id, createdAt: createdAt, parentID: parentID) }
    }

    @discardableResult
    public func reconcileOpencodeCompletion(expected: AgentSession, record: OpencodeCompletedTurn.Record,
                                            now: Date) -> AgentSession? {
        run { reducer.reconcileOpencodeCompletion(expected: expected, record: record, now: now) }
    }

    @discardableResult
    public func reconcileCodexLifecycle(id: String, event: CodexLifecycle) -> AgentSession? {
        return run { reducer.reconcileCodexLifecycle(id: id, event: event) }
    }

    @discardableResult
    public func updateAionUiMetadata(id: String, createdAt: Date, record: AionUiMetadata.Record,
                                     verifiedAt: Date = Date()) -> Bool {
        return run { reducer.updateAionUiMetadata(id: id, createdAt: createdAt, record: record, verifiedAt: verifiedAt) }
    }
    /// Latest formal host facts include idle orchestrators omitted from bubbles.
    /// These are transient observations, never persisted as current evidence.
    public var aoHostObservations: [AOHostObservation] { Array(reducer.aoSessions.values) }
    /// Exact AO host observations are separate from native Hook results.
    @discardableResult
    public func applyAOSnapshot(_ snapshot: AOSnapshot, now: Date) -> [AOHostTransition] {
        run { reducer.applyAOSnapshot(snapshot, now: now) }
    }
    @discardableResult
    public func markAOUnavailable(now: Date) -> [AOHostTransition] {
        run { reducer.markAOUnavailable(now: now) }
    }
    @discardableResult
    public func renewAOHostBinding(nativeSessionID: String, createdAt: Date?, binding: AOBinding, now: Date) -> Bool {
        run { reducer.recordAOBinding(binding, nativeSessionID: nativeSessionID, createdAt: createdAt, now: now) }
    }
    @discardableResult
    public func bindAOHostEnvironment(from event: AgentEvent, now: Date) -> Bool {
        run { reducer.bindAOHostEnvironment(from: event, now: now) }
    }
    /// Drops queued/pre-launch AO claims while keeping native rows/receipts.
    @discardableResult
    public func clearAOHostClaims() -> Bool {
        let changed = run { reducer.clearAOHostClaims() }
        if changed { run { reducer.persistCodexSessions() } }
        return changed
    }
    /// Drops the cached live verification (see
    /// `SessionReducer.clearAionUiVerification`).
    @discardableResult
    public func clearAionUiVerification(id: String, createdAt: Date, clearRole: Bool) -> Bool {
        return run { reducer.clearAionUiVerification(id: id, createdAt: createdAt, clearRole: clearRole) }
    }
    @discardableResult
    public func markAntigravityDSHBackend(expected: AgentSession) -> Bool {
        run { reducer.markAntigravityDSHBackend(expected: expected) }
    }

    public func updateAntigravityActivity(id: String, message: String, since: Date) {
        run { reducer.updateAntigravityActivity(id: id, message: message, since: since) }
    }
    public func markRead(id: String, through version: Int) {
        run { reducer.markRead(id: id, through: version) }
    }

    @discardableResult
    public func markOpened(_ clicked: AgentSession, at: Date) -> Bool {
        return run { reducer.markOpened(clicked, at: at) }
    }
    /// Explicitly acknowledges only the displayed AO source revision. Native
    /// navigation/read callbacks intentionally do not invoke this operation.
    @discardableResult
    public func acknowledgeAO(_ receipt: AOAttentionReceipt, at: Date) -> Bool {
        run { reducer.acknowledgeAO(receipt, at: at) }
    }
    public func clear() {
        run { reducer.clear() }
    }
    public func remove(id: String) {
        run { reducer.remove(id: id) }
    }
    public func updateTitle(id: String, title: String) {
        run { reducer.updateTitle(id: id, title: title) }
    }
    public func updateModel(id: String, model: String) {
        run { reducer.updateModel(id: id, model: model) }
    }
    public func refineState(id: String, from expected: AgentState, to refined: AgentState, since: Date) {
        run { reducer.refineState(id: id, from: expected, to: refined, since: since) }
    }

    @discardableResult
    public func apply(_ event: AgentEvent, now: Date) -> AgentSession? {
        let updated = run { reducer.apply(event, now: now) }
        return updated.flatMap { reducer.session(id: $0.id) }
    }

    @discardableResult
    public func apply(_ observation: SessionObservation) -> AgentSession? {
        let updated = run { reducer.apply(observation) }
        return updated.flatMap { reducer.session(id: $0.id) }
    }

    @discardableResult
    public func markDSHOpened(_ clicked: AgentSession, target: DSHObservation, at: Date) -> Bool {
        return run { reducer.markDSHOpened(clicked, target: target, at: at) }
    }

    @discardableResult
    public func reconcileAntigravityCancellation(id: String, cancellation: AntigravityHumanInput.Cancellation) -> AgentSession? {
        return run { reducer.reconcileAntigravityCancellation(id: id, cancellation: cancellation) }
    }

    @discardableResult
    public func reconcileAntigravityCancellationSignal(_ signal: AntigravityCancellationSignal, observedAt: Date = Date()) -> AgentSession? {
        return run { reducer.reconcileAntigravityCancellationSignal(signal, observedAt: observedAt) }
    }

    @discardableResult
    public func reconcileAionUiCancellation(_ signal: AionUiCancellationSignal, observedAt: Date = Date()) -> AgentSession? {
        return run { reducer.reconcileAionUiCancellation(signal, observedAt: observedAt) }
    }

    @discardableResult
    public func resolveApproval(id: String, requestId: String) -> Bool {
        return run { reducer.resolveApproval(id: id, requestId: requestId) }
    }
    public func prune(now: Date) {
        run { reducer.prune(now: now) }
    }
    public func reconcileDSHConnection(now: Date) {
        run { reducer.reconcileDSHConnection(now: now) }
    }
}
