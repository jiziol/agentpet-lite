import Foundation
import CSQLite

/// Narrow compatibility fallback for unpersisted internal tasks. Suggestions
/// and disposable Desktop starts require a confirmed exit. Unpersisted Desktop
/// forks and AionUi titles require their exact native creation span.
/// Unknown diagnostics never hide a conversation.
public enum CodexInternalTaskEvidence {
    /// Retain the exact native source before diagnostic log rotation. This is
    /// only a candidate while its owning process is alive or unknown.
    public struct DesktopSource: Codable, Sendable, Equatable {
        public let sessionID: String
        public let home: String
        public let process: String
        public let lastNativeAt: Date

        public init(sessionID: String, home: String, process: String, lastNativeAt: Date) {
            self.sessionID = sessionID; self.home = home
            self.process = process; self.lastNativeAt = lastNativeAt
        }

        var pid: Int32? {
            let parts = process.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "pid",
                  let pid = Int32(parts[1]), pid > 1, String(pid) == parts[1],
                  let uuid = UUID(uuidString: String(parts[2])),
                  uuid.uuidString.lowercased() == parts[2].lowercased() else { return nil }
            return pid
        }

        func isValid(sessionID: String, home: String, at now: Date) -> Bool {
            self.sessionID == sessionID && self.home == home && home.hasPrefix("/") &&
                UUID(uuidString: sessionID) != nil && pid != nil &&
                lastNativeAt.timeIntervalSince1970.isFinite && lastNativeAt.timeIntervalSince1970 > 0 &&
                now.timeIntervalSince1970.isFinite && lastNativeAt <= now
        }
    }

    public struct Record: Sendable, Equatable {
        public let sessionID: String
        public let home: String
        public let kind: String
        public let exitedAt: Date?
        public let observedAt: Date
        public let desktopSource: DesktopSource?

        public init(sessionID: String, home: String, kind: String, exitedAt: Date?, observedAt: Date,
                    desktopSource: DesktopSource? = nil) {
            self.sessionID = sessionID; self.home = home; self.kind = kind
            self.exitedAt = exitedAt; self.observedAt = observedAt
            self.desktopSource = desktopSource
        }
    }

    private final class Budget {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.025
    }

    private struct Row {
        let id: Int64
        let seconds: Int64
        let nanos: Int64
        let purpose: Bool
        let turnInput: Bool
        let exited: Bool
        let aionUiTitle: Bool
        let desktop: Bool
        let desktopFork: Bool
        let process: String

        var time: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000) }
        func precedes(_ other: Row) -> Bool {
            if seconds != other.seconds { return seconds < other.seconds }
            if nanos != other.nanos { return nanos < other.nanos }
            return id < other.id
        }
    }

    private static func database(home: String, prefix: String) -> String? {
        guard home.hasPrefix("/"),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: home), entries.count <= 512 else { return nil }
        return entries.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(prefix.count).dropLast(7)), version >= 0 else { return nil }
            return (version, home + "/" + name)
        }.max { $0.0 < $1.0 }?.1
    }

    private static func withDatabase<Value>(_ path: String, _ body: (OpaquePointer) -> Value?) -> Value? {
        guard (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 262_144)
        let budget = Budget()
        sqlite3_progress_handler(db, 500, { context in
            guard let context else { return 1 }
            let budget = Unmanaged<Budget>.fromOpaque(context).takeUnretainedValue()
            return ProcessInfo.processInfo.systemUptime > budget.deadline ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        return withExtendedLifetime(budget) { body(db) }
    }

    private static func columns(_ table: String, db: OpaquePointer) -> [(String, String, Int32)]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [(String, String, Int32)] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW, result.count < 128 {
            guard let name = sqlite3_column_text(statement, 1), let type = sqlite3_column_text(statement, 2) else { return nil }
            result.append((String(cString: name), String(cString: type), sqlite3_column_int(statement, 5)))
            status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE ? result : nil
    }

    /// Missing/unreadable metadata is unknown, never evidence of non-persistence.
    private static func hasNoNativeThread(_ id: String, db: OpaquePointer) -> Bool? {
        guard let schema = columns("threads", db: db),
              schema.filter({ $0.2 > 0 }).count == 1,
              schema.contains(where: { $0.0 == "id" && $0.1.uppercased() == "TEXT" && $0.2 == 1 }) else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return true
        case SQLITE_ROW: return false
        default: return nil
        }
    }

    private static func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func indexedLogs(_ db: OpaquePointer) -> Bool {
        let required: Set<String> = ["id", "ts", "ts_nanos", "target", "feedback_log_body", "thread_id", "process_uuid"]
        guard let schema = columns("logs", db: db), required.isSubset(of: Set(schema.map(\.0))) else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA index_list(logs)", -1, &statement, nil) == SQLITE_OK else { return false }
        var found = false, count = 0
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW, count < 128 {
            count += 1
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == "idx_logs_thread_id_ts",
               sqlite3_column_int(statement, 4) == 0 { found = true }
            status = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        guard found, status == SQLITE_DONE else { return false }
        guard sqlite3_prepare_v2(db, "PRAGMA index_info(idx_logs_thread_id_ts)", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        status = sqlite3_step(statement)
        while status == SQLITE_ROW, names.count < 8 {
            guard let name = sqlite3_column_text(statement, 2) else { return false }
            names.append(String(cString: name)); status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE && names == ["thread_id", "ts", "ts_nanos", "id"]
    }

    private static func rows(_ id: String, db: OpaquePointer, newest: Bool) -> [Row]? {
        let prefix = "session_loop{thread_id=\(id)}"
        let purpose = "text: \"# Overview\\n\\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project"
        let order = newest ? "DESC" : "ASC"
        let limit = newest ? 1 : 32
        // Only booleans, timestamps, row identity and bounded process metadata
        // leave SQLite. Neither submitted text nor tool output is returned.
        let sql = """
        SELECT id, ts, ts_nanos,
          CASE WHEN target = 'codex_core::session::handlers'
            AND length(feedback_log_body) BETWEEN 1 AND 16384
            AND substr(feedback_log_body, 1, length(?2)) = ?2
            AND instr(feedback_log_body, 'op: TurnInput { request: TurnInputRequest {') > 0
            AND instr(feedback_log_body, 'text: "') > 0
            AND substr(feedback_log_body, instr(feedback_log_body, 'text: "'), length(?3)) = ?3
            THEN 1 ELSE 0 END,
          CASE WHEN target = 'codex_core::session::handlers'
            AND length(feedback_log_body) BETWEEN 1 AND 16384
            AND substr(feedback_log_body, 1, length(?2)) = ?2
            AND (instr(feedback_log_body, 'op: TurnInput { request: TurnInputRequest {') > 0
              OR (instr(feedback_log_body, ' operation="turn_input" ') > 0
                AND instr(feedback_log_body, ' op=TurnInput { requested_settings: ThreadSettingsOverrides {') > 0))
            THEN 1 ELSE 0 END,
          CASE WHEN target = 'codex_core::session::handlers'
            AND feedback_log_body = ?4 THEN 1 ELSE 0 END,
          CASE WHEN length(process_uuid) BETWEEN 1 AND 128 THEN process_uuid ELSE NULL END,
          CASE WHEN target = 'codex_core::shell_snapshot'
            AND length(feedback_log_body) BETWEEN 1 AND 16384
            AND substr(feedback_log_body, 1, 19) = 'app_server.request{'
            AND instr(feedback_log_body, '}:') BETWEEN 1 AND 4096
            AND instr(substr(feedback_log_body, 1, instr(feedback_log_body, '}:')), ' rpc.method="thread/start" ') > 0
            AND instr(substr(feedback_log_body, 1, instr(feedback_log_body, '}:')), ' app_server.client_name="aionui-title" ') > 0
            THEN 1 ELSE 0 END,
          CASE WHEN target = 'codex_core::shell_snapshot'
            AND length(feedback_log_body) BETWEEN 1 AND 16384
            AND substr(feedback_log_body, 1, 19) = 'app_server.request{'
            AND instr(feedback_log_body, '}:') BETWEEN 1 AND 4096
            AND instr(substr(feedback_log_body, 1, instr(feedback_log_body, '}:')), ' rpc.method="thread/start" ') > 0
            AND instr(substr(feedback_log_body, 1, instr(feedback_log_body, '}:')), ' app_server.client_name="Codex Desktop" ') > 0
            THEN 1 ELSE 0 END,
          CASE WHEN target = 'codex_core::shell_snapshot'
            AND length(feedback_log_body) BETWEEN 1 AND 16384
            AND substr(feedback_log_body, 1, 19) = 'app_server.request{'
            AND instr(feedback_log_body, '}:') BETWEEN 1 AND 4096
            AND instr(substr(feedback_log_body, 1, instr(feedback_log_body, '}:')), ' rpc.method="thread/fork" ') > 0
            AND instr(substr(feedback_log_body, 1, instr(feedback_log_body, '}:')), ' app_server.client_name="Codex Desktop" ') > 0
            THEN 1 ELSE 0 END
        FROM logs INDEXED BY idx_logs_thread_id_ts WHERE thread_id = ?1
        ORDER BY ts \(order), ts_nanos \(order), id \(order) LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1); bind(prefix, to: statement, at: 2)
        bind(purpose, to: statement, at: 3); bind(prefix + ": Agent loop exited", to: statement, at: 4)
        var result: [Row] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW, result.count < limit {
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                  let process = sqlite3_column_text(statement, 6) else { return nil }
            let seconds = sqlite3_column_int64(statement, 1), nanos = sqlite3_column_int64(statement, 2)
            guard seconds > 0, (0..<1_000_000_000).contains(nanos) else { return nil }
            result.append(Row(id: sqlite3_column_int64(statement, 0), seconds: seconds, nanos: nanos,
                purpose: sqlite3_column_int(statement, 3) == 1, turnInput: sqlite3_column_int(statement, 4) == 1,
                exited: sqlite3_column_int(statement, 5) == 1,
                aionUiTitle: sqlite3_column_int(statement, 7) == 1,
                desktop: sqlite3_column_int(statement, 8) == 1,
                desktopFork: sqlite3_column_int(statement, 9) == 1, process: String(cString: process)))
            status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE ? result : nil
    }

    public static func read(sessionID: String, home: String, now: Date = Date(),
                            cachedSource: DesktopSource? = nil,
                            processIsAlive: (Int32) -> Bool? = OpencodeLiveness.processIsAlive) -> Record? {
        guard UUID(uuidString: sessionID) != nil, now.timeIntervalSince1970.isFinite,
              let state = database(home: home, prefix: "state_"),
              withDatabase(state, { hasNoNativeThread(sessionID, db: $0) }) == true else { return nil }
        var beginning: [Row] = [], latest: Row?
        if let logs = database(home: home, prefix: "logs_") {
            guard let snapshot = withDatabase(logs, { db -> ([Row], Row?)? in
                guard indexedLogs(db), let start = rows(sessionID, db: db, newest: false),
                      let end = rows(sessionID, db: db, newest: true) else { return nil }
                return (start, end.first)
            }) else { return nil }
            (beginning, latest) = snapshot
        }
        func ownerRecord(_ source: DesktopSource) -> Record? {
            guard source.isValid(sessionID: sessionID, home: home, at: now), let pid = source.pid else { return nil }
            // A live/reused PID, EPERM or an unknown probe cannot hide a task.
            // OS absence does not tell us a native exit time or turn outcome.
            let kind = processIsAlive(pid) == false ? "desktopProcessExited" : "desktopTransientCandidate"
            return Record(sessionID: sessionID, home: home, kind: kind, exitedAt: nil,
                          observedAt: now, desktopSource: source)
        }
        var record: Record?
        if let first = beginning.first(where: \.turnInput), let last = latest,
           first.process == last.process, first.precedes(last), last.time <= now {
            var kind: String?
            var exit: Date?
            if beginning.contains(where: { $0.desktopFork && $0.process == first.process && $0.precedes(first) }) {
                // Desktop side chats fork an ephemeral thread. A durable fork
                // has a native thread row and is rejected by both exact-ID
                // checks. Do not wait for exit or infer from title/cwd/model.
                kind = "desktopSideConversation"; exit = nil
            } else if beginning.contains(where: { $0.aionUiTitle && $0.process == first.process && $0.time <= now }) {
                // The exact thread's native creation span identifies AionUi's
                // disposable title client, even while alive. Do not invent a
                // turn result or exit when its process is force-terminated.
                kind = "aionUiTitle"; exit = nil
            } else if first.purpose, last.exited {
                kind = "projectSuggestions"; exit = last.time
            } else if last.exited, beginning.contains(where: { $0.desktop && $0.process == first.process && $0.time <= now }) {
                // Current Desktop diagnostics redact TurnInput text. A native
                // Desktop creation span + exact final process exit + two absent
                // thread checks identify a disposable desktop run, not its purpose.
                kind = "desktopTransient"; exit = last.time
            } else if beginning.allSatisfy({ $0.process == first.process }),
                      beginning.contains(where: { $0.desktop && $0.process == first.process && $0.time <= now }) {
                record = ownerRecord(DesktopSource(sessionID: sessionID, home: home,
                                                   process: first.process, lastNativeAt: last.time))
            }
            if let kind {
                record = Record(sessionID: sessionID, home: home, kind: kind, exitedAt: exit, observedAt: now)
            }
        }
        // Only previously captured exact source evidence survives a rotated
        // log. A contradictory/new process or future event invalidates it.
        if record == nil, let source = cachedSource,
           beginning.allSatisfy({ $0.process == source.process }),
           latest.map({ $0.process == source.process && $0.time <= now }) ?? true {
            record = ownerRecord(source)
        }
        // A normal conversation persisted during the diagnostic read wins.
        guard withDatabase(state, { hasNoNativeThread(sessionID, db: $0) }) == true else { return nil }
        return record
    }
}
