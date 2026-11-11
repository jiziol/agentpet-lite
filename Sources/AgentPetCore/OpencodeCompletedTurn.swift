import Foundation
import CSQLite

/// A missing idle Hook can be recovered from the exact root turn's native
/// final message. This reads metadata only, never parts' text or reasoning.
public enum OpencodeCompletedTurn {
    public struct Record: Equatable, Sendable {
        public let sessionID: String
        public let turnID: String
        public let completedAt: Date
        public init(sessionID: String, turnID: String, completedAt: Date) {
            self.sessionID = sessionID; self.turnID = turnID; self.completedAt = completedAt
        }
    }

    public static func read(sessionID: String, turnID: String,
                            databasePath: String = OpencodeSessionMetadata.defaultDatabasePath,
                            now: Date = Date()) -> Record? {
        guard OpencodeHookPayload.validSessionID(sessionID), turnID.count <= 128,
              turnID.range(of: "^msg_[A-Za-z0-9]+$", options: .regularExpression) != nil,
              FileManager.default.fileExists(atPath: databasePath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        // One statement gives a consistent SQLite snapshot across session,
        // latest user/assistant metadata and outstanding tools in that turn.
        let sql = """
        SELECT a.id, json_extract(a.data,'$.time.completed')
        FROM session s JOIN message a ON a.session_id = s.id
        WHERE s.id = ? AND s.parent_id IS NULL
          AND a.id = (SELECT id FROM message WHERE session_id=s.id
            AND json_extract(data,'$.role')='assistant' ORDER BY time_created DESC,id DESC LIMIT 1)
          AND ? = (SELECT id FROM message WHERE session_id=s.id
            AND json_extract(data,'$.role')='user' ORDER BY time_created DESC,id DESC LIMIT 1)
          AND json_extract(a.data,'$.parentID') = ?
          AND json_extract(a.data,'$.finish') = 'stop'
          AND (json_type(a.data,'$.error') IS NULL OR json_type(a.data,'$.error')='null')
          AND json_type(a.data,'$.time.completed') IN ('integer','real')
          AND json_extract(a.data,'$.time.completed') >= a.time_created
          AND NOT EXISTS (SELECT 1 FROM part p JOIN message m ON m.id=p.message_id
            WHERE m.session_id=s.id AND json_extract(m.data,'$.role')='assistant'
              AND json_extract(m.data,'$.parentID') = ?
              AND json_extract(p.data,'$.type')='tool'
              AND json_extract(p.data,'$.state.status') IN ('pending','running'))
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in [sessionID, turnID, turnID, turnID].enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { return nil }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let milliseconds = sqlite3_column_double(statement, 1)
        guard milliseconds.isFinite, milliseconds > 0 else { return nil }
        let completed = Date(timeIntervalSince1970: milliseconds / 1000)
        guard completed <= now else { return nil }
        return Record(sessionID: sessionID, turnID: turnID, completedAt: completed)
    }
}
