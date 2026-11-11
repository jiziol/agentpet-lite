import Foundation
import CSQLite

/// Select only usage metadata inside a read-only, consistent SQLite snapshot.
enum TokenUsageOpenCode {
    static func read(_ instance: TokenUsageInstance, since: Date, now: Date) -> TokenReadResult {
        var result = TokenReadResult()
        let url = instance.root.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true,
              sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; result.quality = .failed; result.issue("usage.error.unavailable"); return result
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        result.files.insert(TokenUsageInstance.digest(url.path))
        guard sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN", nil, nil, nil) == SQLITE_OK else {
            result.quality = .failed; result.issue("usage.error.unavailable"); return result
        }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        func columns(_ table: String) -> Set<String> {
            var statement: OpaquePointer?, names = Set<String>()
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW { if let p = sqlite3_column_text(statement, 1) { names.insert(String(cString: p)) } }
            return names
        }
        let v2 = columns("session_message"), v1 = columns("message"), session = columns("session_v2")
        let hasV2 = ["id", "session_id", "type", "data", "time_created", "time_updated"].allSatisfy(v2.contains)
        let hasV1 = ["id", "session_id", "data", "time_created", "time_updated"].allSatisfy(v1.contains)
        guard hasV1 || hasV2 else { result.quality = .failed; result.issue("usage.error.unsupported"); return result }
        var slots: [String: TokenRecord] = [:]
        for table in ["message", "session_message"] {
            if table == "message" && !hasV1 || table == "session_message" && !hasV2 { continue }
            let modern = table == "session_message"
            let canFork = modern && ["id", "fork_session_id", "time_created"].allSatisfy(session.contains)
            let role = modern ? "m.type" : "json_extract(m.data,'$.role')"
            let model = modern ? "json_extract(m.data,'$.model.id')" : "json_extract(m.data,'$.modelID')"
            let join = canFork ? "LEFT JOIN session_v2 s ON s.id=m.session_id" : ""
            let fork = canFork ? "s.fork_session_id,s.time_created" : "NULL,NULL"
            // V2 is authoritative for an ID present in both projections. Legacy-only
            // rows stay eligible; do not discard an entire old table after upgrade.
            let dedup = !modern && hasV2 ? "AND NOT EXISTS(SELECT 1 FROM session_message n WHERE n.id=m.id)" : ""
            let sql = """
            SELECT m.id,json_extract(m.data,'$.tokens'),\(model),
                   json_extract(m.data,'$.time.created'),json_extract(m.data,'$.time.completed'),
                   m.time_created,m.time_updated,\(fork)
            FROM \(table) m \(join)
            WHERE \(role)='assistant' AND json_type(m.data,'$.tokens')='object'
              AND m.time_updated >= ? \(dedup)
            ORDER BY m.time_updated,m.id LIMIT 100001
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { result.issue("usage.error.unsupported"); continue }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970 * 1000)
            var count = 0, code = sqlite3_step(stmt)
            while code == SQLITE_ROW {
                count += 1
                if count > 100000 { result.issue("usage.error.limit"); break }
                func text(_ index: Int32) -> String? { sqlite3_column_text(stmt, index).map { String(cString: $0) } }
                do {
                    guard let id = text(0), let encoded = text(1), let data = encoded.data(using: .utf8), let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], let cache = raw["cache"] as? [String: Any] else { throw TokenUsageError.invalid("tokens") }
                    // Pending messages do not yet have final usage; never make them zero.
                    guard sqlite3_column_type(stmt, 4) != SQLITE_NULL else { result.issue("usage.error.partial"); code = sqlite3_step(stmt); continue }
                    let completed = sqlite3_column_double(stmt, 4), created = sqlite3_column_double(stmt, 3)
                    guard created.isFinite, completed.isFinite, created > 0, completed >= created else { throw TokenUsageError.invalid("time") }
                    if text(7) != nil && created < sqlite3_column_double(stmt, 8) { code = sqlite3_step(stmt); continue }
                    let input = try UsageJSON.count(raw["input"]), read = try UsageJSON.count(cache["read"]), write = try UsageJSON.count(cache["write"])
                    let output = try UsageJSON.count(raw["output"]), reasoning = try UsageJSON.count(raw["reasoning"])
                    let b = try TokenBuckets(input: input, cacheRead: read, cacheWrite: write, output: output + reasoning)
                    if let total = raw["total"], try UsageJSON.count(total) != b.total { throw TokenUsageError.invalid("total") }
                    let at = Date(timeIntervalSince1970: completed / 1000)
                    if at >= since && at <= now {
                        slots[id] = TokenRecord(id: id, occurredAt: at, revision: sqlite3_column_int64(stmt, 6), agent: .opencode, buckets: b, model: text(2))
                    }
                    // Older V1 has no proven fork identity. Keep recorded usage and
                    // disclose coverage instead of claiming full fork deduplication.
                    if !modern { result.issue("usage.error.legacyFork") }
                } catch { result.issue("usage.error.invalid") }
                code = sqlite3_step(stmt)
            }
            if code != SQLITE_DONE && count <= 100000 { result.issue("usage.error.unavailable") }
        }
        result.records = Array(slots.values); return result
    }
}
