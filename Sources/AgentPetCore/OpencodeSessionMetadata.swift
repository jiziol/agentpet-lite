import Foundation
import CSQLite

/// Exact, read-only parent lookup for legacy records. No message/body reads.
public enum OpencodeSessionMetadata {
    public static var defaultDatabasePath: String {
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? NSHomeDirectory() + "/.local/share"
        return data + "/opencode/opencode.db"
    }

    public static func parentID(sessionID: String, databasePath: String = defaultDatabasePath) -> String? {
        guard OpencodeHookPayload.validSessionID(sessionID), FileManager.default.fileExists(atPath: databasePath) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else { if let database { sqlite3_close(database) }; return nil }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT parent_id FROM session WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_bytes(statement, 0) <= 128,
              let bytes = sqlite3_column_text(statement, 0) else { return nil }
        let parent = String(cString: bytes)
        guard parent != sessionID, OpencodeHookPayload.validSessionID(parent) else { return nil }
        return parent
    }
}
