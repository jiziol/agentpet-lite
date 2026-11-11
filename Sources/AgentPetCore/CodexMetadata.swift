import Foundation
import CSQLite
import CoreFoundation

/// Read-only, exact-ID metadata. Never select a conversation by working directory.
public enum CodexMetadata {
    public struct Record: Sendable, Equatable {
        public let title: String?
        public let model: String?
        public let rolloutPath: String?
        public let isDesktop: Bool
    }

    public static var defaultHome: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
    }

    public static func databasePath(home: String) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return files.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, home + "/" + name)
        }.max { $0.0 < $1.0 }?.1
    }

    public static func read(sessionID: String, home: String = defaultHome) -> Record? {
        guard UUID(uuidString: sessionID) != nil, let path = databasePath(home: home) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &schema, nil) == SQLITE_OK else { return nil }
        var columns = Set<String>()
        while sqlite3_step(schema) == SQLITE_ROW {
            if let value = sqlite3_column_text(schema, 1) { columns.insert(String(cString: value)) }
        }
        sqlite3_finalize(schema)
        guard columns.contains("id"), columns.contains("title") else { return nil }
        let title = columns.contains("name") ? "COALESCE(NULLIF(name, ''), title)" : "title"
        let model = columns.contains("model") ? "model" : "NULL"
        let rollout = columns.contains("rollout_path") ? "rollout_path" : "NULL"
        let origin = columns.contains("originator") ? "originator" : "NULL"
        let source = columns.contains("source") ? "source" : "NULL"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(title), \(model), \(rollout), \(origin), \(source) FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, sessionID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func string(_ index: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, index) else { return nil }
            let result = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }
        let originator = string(3)?.lowercased()
        // Resuming a CLI thread in Desktop retains codex-tui as its creator.
        // vscode is shared with the editor extension, so require Desktop's own
        // exact local-thread activity or saved tabs as navigation evidence.
        // A thread resumed in the CLI has source=cli and keeps terminal routing.
        let migratedDesktop = originator == "codex-tui" && string(4) == "vscode"
            && hasDesktopNavigationEvidence(sessionID: sessionID, home: home)
        return Record(title: string(0).map { String($0.prefix(240)) },
                      model: string(1).map { String($0.prefix(80)) }, rolloutPath: string(2),
                      isDesktop: originator?.contains("codex desktop") == true || migratedDesktop)
    }

    /// Persistent navigation availability, not exclusive live host ownership or
    /// a read receipt. Inspect only versioned activity/tab markers, never content.
    private static func hasDesktopNavigationEvidence(sessionID: String, home: String) -> Bool {
        let path = home + "/.codex-global-state.json"
        let limit = 4_194_304
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber,
              size.intValue <= limit, let data = FileManager.default.contents(atPath: path), data.count <= limit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atoms = root["electron-persisted-atom-state"] as? [String: Any] else { return false }
        if let activity = atoms["thread-user-activity-times-v1"] as? [String: Any],
           let timestamp = activity["[\"local\",\"\(sessionID)\"]"] as? NSNumber,
           CFGetTypeID(timestamp) != CFBooleanGetTypeID(),
           timestamp.doubleValue.isFinite, timestamp.doubleValue > 0 { return true }
        // Desktop may evict activity for a background thread. A saved tab
        // topology (including an empty one) is independent exact-ID evidence.
        guard let tabs = atoms["thread-tab-routes-v1:" + sessionID] as? [String: Any],
              let version = tabs["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              tabs["routes"] is [Any], tabs["topology"] is [String: Any] else { return false }
        return true
    }

    public static func threadURL(sessionID: String) -> URL? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        return URL(string: "codex://threads/\(sessionID)")
    }

    /// Read acknowledgement from the client's native persisted unread set.
    /// A true -> false transition after navigation is evidence of a read; a
    /// missing schema or an already-read thread is NOT a navigation receipt.
    public static func nativeUnread(sessionID: String, home: String = defaultHome) -> Bool? {
        let path = home + "/.codex-global-state.json"
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber,
              size.intValue <= 4_194_304,
              let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["electron-thread-read-state-v1"] as? [String: Any],
              state["version"] as? Int == 1,
              let identities = state["unreadByIdentity"] as? [String: [String: [String]]] else { return nil }
        return identities.values.contains { $0.values.contains { $0.contains(sessionID) } }
    }
}
