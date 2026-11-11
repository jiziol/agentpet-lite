import Foundation
import Combine
import AgentPetCore

struct TokenIntegrationAccess: Sendable {
    let instance: TokenUsageInstance
    let eligible: Bool
    /// Unknown/conflicting configuration suspends reads, but does not erase the
    /// collection interval. Confirmed removal closes it without backfilling gaps.
    let removed: Bool
}

@MainActor
final class DailyTokenUsageController: ObservableObject {
    static let shared = DailyTokenUsageController()
    @Published private(set) var snapshot = TokenUsageSnapshot()
    @Published private(set) var states: [TokenCollectionState] = []
    @Published private(set) var access: [TokenIntegrationAccess] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    private let worker: TokenUsageCollector
    private let eligibility: @MainActor () async -> [TokenIntegrationAccess]
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private let refreshInterval: TimeInterval
    private let integrationChanges: AnyPublisher<Void, Never>
    private var refreshRequested = false
    init(url: URL = URL(fileURLWithPath: AgentPetPaths.baseDir).appendingPathComponent("usage-v1/ledger.sqlite"),
         mode: String = "formal", refreshInterval: TimeInterval = 60,
         integrationChanges: AnyPublisher<Void, Never>? = nil, reader: @escaping TokenUsageCollector.Reader = { TokenUsageReader.read($0, since: $1, now: $2) },
         eligibility: @escaping @MainActor () async -> [TokenIntegrationAccess] = { await SettingsModel.shared.refreshTokenUsageAccess() }) {
        worker = TokenUsageCollector(url: url, mode: mode, reader: reader); self.eligibility = eligibility
        self.refreshInterval = refreshInterval
        self.integrationChanges = integrationChanges ?? SettingsModel.shared.$usageEligibilityRevision
            .dropFirst().map { _ in () }.eraseToAnyPublisher()
    }
    func start() {
        guard timer == nil else { return }
        refresh()
        subscription = integrationChanges.sink { [weak self] in self?.refresh() }
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil; subscription = nil }
    func refresh() { Task { await refreshNow() } }
    func refreshNow() async {
        guard !isRefreshing else { refreshRequested = true; return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequested { refreshRequested = false; refresh() }
        }
        do {
            access = await eligibility()
            snapshot = try await worker.poll(eligible: access.filter(\.eligible).map(\.instance), removedIDs: Set(access.filter(\.removed).map { $0.instance.id }), automaticallyStart: true)
            states = try await worker.states(); error = nil
        } catch { self.error = (error as? TokenUsageError)?.errorDescription ?? "usage.error.storage" }
    }
}
