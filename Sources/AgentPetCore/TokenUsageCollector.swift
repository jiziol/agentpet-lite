import Foundation

/// Serial worker keeps all disk reads and ledger transactions off the UI actor.
public actor TokenUsageCollector {
    public typealias Reader = @Sendable (TokenUsageInstance, Date, Date) -> TokenReadResult
    private let url: URL
    private let mode: String
    private let reader: Reader
    private var ledger: TokenUsageLedger?
    public init(url: URL, mode: String = "formal", reader: @escaping Reader = { TokenUsageReader.read($0, since: $1, now: $2) }) {
        self.url = url; self.mode = mode; self.reader = reader
    }
    private func storage() throws -> TokenUsageLedger {
        if let ledger { return ledger }
        let value = try TokenUsageLedger(url: url, mode: mode); ledger = value; return value
    }
    public func states() throws -> [TokenCollectionState] { try storage().states() }
    public func enable(_ instance: TokenUsageInstance, at: Date) throws {
        // Validation reads are never imported. Formal start is a separate write.
        let validation = reader(instance, at, at)
        if validation.issues.contains("usage.error.unsupported") { throw TokenUsageError.unsupported }
        if validation.issues.contains("usage.error.corrupt") { throw TokenUsageError.corrupt }
        if validation.issues.contains("usage.error.invalid") { throw TokenUsageError.invalid("metadata") }
        if validation.issues.contains("usage.error.limit") { throw TokenUsageError.limit }
        guard validation.quality != .failed, !validation.issues.contains("usage.error.unavailable") else { throw TokenUsageError.unavailable }
        try storage().enable(instance, at: at)
    }
    public func pause(_ id: String, at: Date) throws { try storage().pause(instanceID: id, at: at) }
    public func poll(eligible: [TokenUsageInstance], removedIDs: Set<String> = [], automaticallyStart: Bool = false,
                     now: Date = Date(), calendar: Calendar = .current) throws -> TokenUsageSnapshot {
        let store = try storage(), eligibleIDs = Set(eligible.map(\.id))
        for state in try store.states() {
            if removedIDs.contains(state.instance.id) || eligible.contains(where: { $0.source == state.instance.source && $0.id != state.instance.id }) {
                try store.pause(instanceID: state.instance.id, at: now, reason: .integrationRemoved)
            }
        }
        if automaticallyStart {
            let states = Dictionary(uniqueKeysWithValues: try store.states().map { ($0.instance.id, $0) })
            for instance in eligible {
                // Integration is the sole switch. Older independently paused
                // states resume now without importing their closed intervals.
                guard states[instance.id]?.enabled != true else { continue }
                // Integration establishes the interval even before the first
                // native usage file exists. Read health is reported separately;
                // deferring the start until a successful read loses the first call.
                try store.enable(instance, at: now)
            }
        }
        let window = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        for state in try store.states() where state.enabled && eligibleIDs.contains(state.instance.id) {
            let read = reader(state.instance, max(state.startedAt!, window), now)
            try store.ingest(read, instanceID: state.instance.id, checkedAt: now)
        }
        return try store.snapshot(eligibleIDs: eligibleIDs, now: now, calendar: calendar)
    }
}
