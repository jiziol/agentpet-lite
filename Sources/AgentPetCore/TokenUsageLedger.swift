import Foundation
import CSQLite

/// An independent, transactional usage ledger. It never reads legacy XP or
/// project totals. The owning engine supplies only currently eligible sources.
public final class TokenUsageLedger: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let schemaVersion = "1"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL, mode: String = "formal") throws {
        guard url.isFileURL, !mode.isEmpty, mode.utf8.count <= 64 else { throw TokenUsageError.storage }
        encoder.outputFormatting = [.sortedKeys]
        // Date's native reference-seconds representation round-trips its full
        // precision. Multiplying Unix seconds into milliseconds can lose a bit
        // and falsely reject a later revision as a changed original timestamp.
        encoder.dateEncodingStrategy = .deferredToDate
        decoder.dateDecodingStrategy = .deferredToDate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw TokenUsageError.storage
        }
        do {
            sqlite3_busy_timeout(db, 1000)
            let tables = try strings("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            if tables.isEmpty {
                try transaction {
                    try execute("CREATE TABLE usage_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                    try execute("CREATE TABLE usage_sources (id TEXT PRIMARY KEY, state BLOB NOT NULL)")
                    try execute("""
                    CREATE TABLE usage_records (
                        source_id TEXT NOT NULL REFERENCES usage_sources(id),
                        id TEXT NOT NULL, occurred_at REAL NOT NULL, revision INTEGER NOT NULL,
                        record BLOB NOT NULL, PRIMARY KEY(source_id,id)
                    )
                    """)
                    try execute("CREATE INDEX usage_record_time ON usage_records(occurred_at)")
                    try execute("INSERT INTO usage_meta(key,value) VALUES('schema',?),('mode',?)", [.text(Self.schemaVersion), .text(mode)])
                    try execute("INSERT INTO usage_meta(key,value) VALUES('time_encoding','reference_seconds')")
                    try execute("PRAGMA user_version=1")
                }
            } else {
                guard tables.contains("usage_meta"), tables.contains("usage_sources"), tables.contains("usage_records"),
                      try strings("SELECT value FROM usage_meta WHERE key='schema'").first == Self.schemaVersion,
                      try strings("SELECT value FROM usage_meta WHERE key='time_encoding'").first == "reference_seconds",
                      try strings("SELECT value FROM usage_meta WHERE key='mode'").first == mode else {
                    throw TokenUsageError.unsupported
                }
            }
            // These writes apply only to our own compatible ledger, never a
            // source database. Unknown schemas/modes are rejected beforehand.
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
        } catch {
            if let db { sqlite3_close(db) }; db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    public func states() throws -> [TokenCollectionState] {
        try locked { try readStates() }
    }

    /// Idempotent within an open interval. Re-enabling starts a new interval,
    /// leaving the original formal start and the paused gap intact.
    public func enable(_ instance: TokenUsageInstance, at: Date) throws {
        try locked {
            guard valid(at), instance.root.isFileURL else { throw TokenUsageError.invalid("start") }
            try transaction {
                var state = try readState(instance.id) ?? TokenCollectionState(instance: instance, intervals: [], checkedAt: nil, quality: nil)
                guard state.instance == instance else { throw TokenUsageError.invalid("instance") }
                if state.enabled { return }
                if let end = state.intervals.last?.end, at < end { throw TokenUsageError.invalid("start") }
                state.intervals.append(.init(start: at, end: nil))
                state.pauseReason = nil
                state.checkedAt = nil; state.quality = nil; state.issues = []
                try save(state)
            }
        }
    }

    /// Also used when integration eligibility disappears. A late asynchronous
    /// scan cannot continue writing after this interval is closed.
    public func pause(instanceID: String, at: Date, reason: TokenCollectionPauseReason = .user) throws {
        try locked {
            guard valid(at) else { throw TokenUsageError.invalid("pause") }
            try transaction {
                guard var state = try readState(instanceID), state.enabled else { return }
                let index = state.intervals.count - 1
                guard at >= state.intervals[index].start else { throw TokenUsageError.invalid("pause") }
                state.intervals[index].end = at
                state.pauseReason = reason
                try save(state)
            }
        }
    }

    /// Stores valid records and coverage together. Malformed records are
    /// quarantined as diagnostics; they never become a zero-valued call.
    public func ingest(_ result: TokenReadResult, instanceID: String, checkedAt: Date) throws {
        try locked {
            guard valid(checkedAt) else { throw TokenUsageError.invalid("check time") }
            try transaction {
                guard var state = try readState(instanceID), state.enabled else { return }
                // Results begun before a pause/re-enable must not report the
                // new collection interval as checked.
                guard checkedAt >= state.intervals.last!.start,
                      state.checkedAt == nil || checkedAt >= state.checkedAt! else { return }
                var issues = result.issues
                var quality = result.quality
                func issue(_ key: String) {
                    issues.insert(key)
                    if quality == .complete { quality = .partial }
                }
                if result.quality == .complete, !state.files.isSubset(of: result.files) {
                    issue("usage.issue.missingFiles")
                }
                // Keep known identities so a missing file cannot become a
                // successful empty scan on the next poll.
                state.files.formUnion(result.files)
                var candidates: [String: TokenRecord] = [:]
                var conflicts = Set<String>()
                for record in result.records {
                    guard isValid(record, for: state.instance.source), record.occurredAt <= checkedAt else {
                        issue("usage.issue.invalidRecord"); continue
                    }
                    guard state.accepts(record.occurredAt) else { continue }
                    if let previous = candidates[record.id] {
                        if record.revision > previous.revision {
                            candidates[record.id] = record; conflicts.remove(record.id)
                        } else if record.revision == previous.revision, record != previous {
                            conflicts.insert(record.id)
                        }
                    } else { candidates[record.id] = record }
                }
                if !conflicts.isEmpty { issue("usage.issue.conflictingRevision") }
                for id in candidates.keys.sorted() where !conflicts.contains(id) {
                    let record = candidates[id]!
                    if let previous = try readRecord(sourceID: instanceID, id: id) {
                        if record.revision < previous.revision { continue }
                        if record.revision == previous.revision {
                            if record != previous { issue("usage.issue.conflictingRevision") }
                            continue
                        }
                        // A revision can correct counts/route, never move a
                        // native call to another day or across the formal start.
                        guard record.occurredAt == previous.occurredAt else {
                            issue("usage.issue.changedTime"); continue
                        }
                    }
                    try execute("""
                    INSERT INTO usage_records(source_id,id,occurred_at,revision,record) VALUES(?,?,?,?,?)
                    ON CONFLICT(source_id,id) DO UPDATE SET revision=excluded.revision, record=excluded.record
                    """, [.text(instanceID), .text(id), .real(record.occurredAt.timeIntervalSince1970),
                           .integer(record.revision), .data(try encoder.encode(record))])
                }
                state.checkedAt = checkedAt; state.quality = quality; state.issues = issues
                try save(state)
            }
        }
    }

    public func snapshot(eligibleIDs: Set<String>, now: Date = Date(), calendar: Calendar = .current) throws -> TokenUsageSnapshot {
        try locked {
            guard valid(now) else { throw TokenUsageError.invalid("snapshot time") }
            let today = calendar.startOfDay(for: now)
            let dates = try (-29...0).map { offset -> Date in
                guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { throw TokenUsageError.invalid("calendar") }
                return date
            }
            let states = try readStates().filter { eligibleIDs.contains($0.instance.id) }
            let stateByID = Dictionary(uniqueKeysWithValues: states.map { ($0.instance.id, $0) })
            let statement = try prepare("SELECT source_id,record FROM usage_records WHERE occurred_at >= ? AND occurred_at <= ? ORDER BY occurred_at,source_id,id",
                                        [.real(dates[0].timeIntervalSince1970), .real(now.timeIntervalSince1970)])
            defer { sqlite3_finalize(statement) }
            var records: [TokenRecord] = []
            var byDay: [Date: [TokenAgent: TokenBuckets]] = [:]
            var dataSources: [Date: Set<String>] = [:]
            while try step(statement) {
                let sourceID = try string(statement, 0)
                guard let state = stateByID[sourceID] else { continue }
                let record = try decode(TokenRecord.self, statement, 1)
                guard isValid(record, for: state.instance.source), state.accepts(record.occurredAt) else { throw TokenUsageError.corrupt }
                let day = calendar.startOfDay(for: record.occurredAt)
                let previous = byDay[day]?[record.agent] ?? .zero
                byDay[day, default: [:]][record.agent] = try previous.adding(record.buckets)
                dataSources[day, default: []].insert(sourceID)
                records.append(record)
            }
            let days = try dates.map { date -> TokenUsageDay in
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { throw TokenUsageError.invalid("calendar") }
                let coverage = combinedCoverage(states, day: date, next: next, now: now, dataSources: dataSources[date] ?? [])
                return .init(date: date, byAgent: byDay[date] ?? [:], coverage: coverage)
            }
            return .init(days: days, states: states, records: records)
        }
    }

    private func combinedCoverage(_ states: [TokenCollectionState], day: Date, next: Date,
                                  now: Date, dataSources: Set<String>) -> TokenDayCoverage {
        let values = states.map { coverage($0, day: day, next: next, now: now, hasData: dataSources.contains($0.instance.id)) }
        if values.isEmpty || values.allSatisfy({ $0 == .notStarted }) { return .notStarted }
        if values.allSatisfy({ $0 == .complete }) { return .complete }
        if values.allSatisfy({ $0 == .unknown || $0 == .notStarted }), dataSources.isEmpty { return .unknown }
        return .partial
    }

    private func coverage(_ state: TokenCollectionState, day: Date, next: Date, now: Date, hasData: Bool) -> TokenDayCoverage {
        guard let start = state.startedAt, start < next else { return .notStarted }
        let end = min(next, now)
        let incomplete: TokenDayCoverage = hasData ? .partial : .unknown
        guard end >= day, let checked = state.checkedAt else { return incomplete }
        // A current-day reading describes the latest scan, not the unelapsed
        // remainder of today. Once polling is stale it cannot confirm zero.
        let currentDay = next > now
        let checkedThrough = checked >= end || (currentDay && now.timeIntervalSince(checked) <= 120)
        guard state.quality == .complete, checkedThrough else { return incomplete }
        var cursor = day
        for interval in state.intervals {
            let intervalEnd = min(interval.end ?? now, now)
            if intervalEnd < cursor { continue }
            if interval.start > cursor { return .partial }
            cursor = max(cursor, intervalEnd)
            if cursor >= end { return .complete }
        }
        return .partial
    }

    private func valid(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 >= 0
            && date.timeIntervalSince1970 <= 253_402_300_799
    }

    private func isValid(_ record: TokenRecord, for source: TokenSource) -> Bool {
        guard !record.id.isEmpty, record.id.utf8.count <= 4096, valid(record.occurredAt), record.revision >= 0,
              (record.model?.utf8.count ?? 0) <= 2048, (record.provider?.utf8.count ?? 0) <= 2048,
              (try? TokenBuckets(input: record.buckets.input, cacheRead: record.buckets.cacheRead,
                                 cacheWrite: record.buckets.cacheWrite, output: record.buckets.output)) != nil else { return false }
        switch source {
        case .dsh: return record.agent == .dsh || (record.agent == .agy && record.provider == "antigravity")
        case .codex: return record.agent == .codex
        case .opencode: return record.agent == .opencode
        case .claude: return record.agent == .claude
        }
    }

    private func readStates() throws -> [TokenCollectionState] {
        let statement = try prepare("SELECT id,state FROM usage_sources ORDER BY id")
        defer { sqlite3_finalize(statement) }
        var states: [TokenCollectionState] = []
        while try step(statement) {
            let state = try decode(TokenCollectionState.self, statement, 1)
            guard state.instance.id == (try string(statement, 0)), validState(state) else { throw TokenUsageError.corrupt }
            states.append(state)
        }
        return states
    }

    private func readState(_ id: String) throws -> TokenCollectionState? {
        let statement = try prepare("SELECT state FROM usage_sources WHERE id=?", [.text(id)])
        defer { sqlite3_finalize(statement) }
        guard try step(statement) else { return nil }
        let state = try decode(TokenCollectionState.self, statement, 0)
        guard state.instance.id == id, validState(state) else { throw TokenUsageError.corrupt }
        return state
    }

    private func validState(_ state: TokenCollectionState) -> Bool {
        guard state.instance.root.isFileURL, !state.intervals.isEmpty else { return false }
        var previousEnd: Date?
        for (index, interval) in state.intervals.enumerated() {
            guard valid(interval.start), previousEnd == nil || interval.start >= previousEnd! else { return false }
            if let end = interval.end {
                guard valid(end), end >= interval.start else { return false }; previousEnd = end
            } else if index != state.intervals.count - 1 { return false }
        }
        return state.checkedAt.map(valid) ?? true
    }

    private func readRecord(sourceID: String, id: String) throws -> TokenRecord? {
        let statement = try prepare("SELECT record FROM usage_records WHERE source_id=? AND id=?", [.text(sourceID), .text(id)])
        defer { sqlite3_finalize(statement) }
        return try step(statement) ? decode(TokenRecord.self, statement, 0) : nil
    }

    private func save(_ state: TokenCollectionState) throws {
        try execute("INSERT INTO usage_sources(id,state) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state",
                    [.text(state.instance.id), .data(try encoder.encode(state))])
    }

    private enum Binding {
        case text(String), data(Data), integer(Int64), real(Double)
    }

    private func prepare(_ sql: String, _ bindings: [Binding] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw TokenUsageError.storage }
        do {
            for (index, binding) in bindings.enumerated() {
                let column = Int32(index + 1)
                let result: Int32
                switch binding {
                case .text(let value): result = sqlite3_bind_text(statement, column, value, -1, Self.transient)
                case .integer(let value): result = sqlite3_bind_int64(statement, column, value)
                case .real(let value): result = sqlite3_bind_double(statement, column, value)
                case .data(let value):
                    result = value.withUnsafeBytes { sqlite3_bind_blob(statement, column, $0.baseAddress, Int32($0.count), Self.transient) }
                }
                guard result == SQLITE_OK else { throw TokenUsageError.storage }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }

    private func execute(_ sql: String, _ bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        while try step(statement) {}
    }

    private func strings(_ sql: String) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while try step(statement) { values.append(try string(statement, 0)) }
        return values
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw TokenUsageError.storage
        }
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { throw TokenUsageError.corrupt }
        return String(cString: bytes)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ statement: OpaquePointer, _ column: Int32) throws -> T {
        guard let bytes = sqlite3_column_blob(statement, column) else { throw TokenUsageError.corrupt }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        do { return try decoder.decode(type, from: data) }
        catch { throw TokenUsageError.corrupt }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
