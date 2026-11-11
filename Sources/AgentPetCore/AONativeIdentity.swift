import Foundation
import CSQLite
import Darwin

public struct AONativeIdentity: Sendable, Equatable {
    public let sessionID: String
    public let nativeSessionID: String
    public let agentKind: AgentKind
    public init(sessionID: String, nativeSessionID: String, agentKind: AgentKind) {
        self.sessionID = sessionID; self.nativeSessionID = nativeSessionID; self.agentKind = agentKind
    }

    /// DSH owns a raw session ID while AgentPet scopes its key by the emitting
    /// profile. Resolve only a unique, validated observation; never guess a
    /// profile path or construct a native row from an AO handle alone.
    func materializedSession(in sessions: [String: AgentSession]) -> AgentSession? {
        if agentKind != .dsh {
            guard let row = sessions[nativeSessionID], !row.isAOPlaceholder, row.agentKind == agentKind else { return nil }
            return row
        }
        let owners = sessions.values.filter { row in
            guard row.agentKind == .dsh, !row.isAOPlaceholder, let observation = row.dsh,
                  observation.valid, row.id == observation.sessionKey else { return false }
            return observation.nativeSessionID == nativeSessionID
        }
        return owners.count == 1 ? owners.first : nil
    }
}

/// AO v0.14.6 does not expose native handles on its sessions HTTP projection.
/// Read only identity columns, by primary key, from the same local installation.
/// No prompts, messages, accounts, provider configuration or credentials leave
/// SQLite. Missing schema, ambiguity and an unproven TUI launch fail closed.
public enum AONativeIdentityReader {
    private final class Budget { let deadline = ProcessInfo.processInfo.systemUptime + 0.05 }
    public static var defaultPath: String { NSHomeDirectory() + "/.ao/data/ao.db" }

    public static func read(snapshot: AOSnapshot, path: String = defaultPath,
                            piMap: String? = nil) -> [AONativeIdentity] {
        guard snapshot.sessions.count <= 200, path.hasPrefix("/") else { return [] }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() else { return [] }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close(handle) }; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 16_384)
        let budget = Budget()
        sqlite3_progress_handler(db, 100, { context in
            guard let context else { return 1 }
            return ProcessInfo.processInfo.systemUptime > Unmanaged<Budget>.fromOpaque(context).takeUnretainedValue().deadline ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        return withExtendedLifetime(budget) {
            // The exact supported schema must retain its indexed identity key.
            var schema: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(sessions)", -1, &schema, nil) == SQLITE_OK else { return [] }
            var primary: [String] = []
            while sqlite3_step(schema) == SQLITE_ROW {
                if sqlite3_column_int(schema, 5) > 0, let value = sqlite3_column_text(schema, 1) {
                    primary.append(String(cString: value))
                }
            }
            sqlite3_finalize(schema)
            guard primary == ["id"] else { return [] }
            let sql = """
                SELECT project_id, harness, session_mode, agent_session_id,
                       provider_conversation_id, runtime_launch_id, agent_session_id_launch_id
                FROM sessions WHERE id = ? LIMIT 1
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var found: [AONativeIdentity] = []
            for host in snapshot.sessions where host.valid && host.available && host.instanceID == snapshot.instanceID {
                guard ProcessInfo.processInfo.systemUptime <= budget.deadline else { return [] }
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, host.sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { continue }
                guard status == SQLITE_ROW else { return [] }
                func text(_ column: Int32) -> String {
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                }
                guard text(0) == host.projectID || (text(0).isEmpty && host.projectID == AOHostMapping.standaloneProjectID),
                      text(1) == host.harness else { continue }
                let kind = AOHostMapping.agentKind(for: host.harness)
                let raw: String
                if text(2) == "chat" { raw = text(4) }
                else if text(2) == "tui", !text(5).isEmpty, text(5) == text(6) { raw = text(3) }
                else { continue }
                let native: String
                switch kind {
                case .codex:
                    guard UUID(uuidString: raw) != nil else { continue }; native = raw
                case .opencode:
                    let prefix = "ao-harness:\(host.harness):"
                    if text(2) == "chat", raw.hasPrefix(prefix) { native = String(raw.dropFirst(prefix.count)) }
                    else if text(2) == "tui" || host.harness == "opencode" { native = raw }
                    else { continue }
                    guard native.hasPrefix("ses_"), AOHostObservation.validID(native) else { continue }
                case .pi:
                    guard let id = PiACPIdentity.sessionID(nativeID: raw, path: piMap ?? PiACPIdentity.defaultMap) else { continue }
                    native = id
                case .dsh:
                    // AO's DSH ACP provider returns the actual persistent
                    // session UUID. Terminal headless runs expose no such proof.
                    guard text(2) == "chat", UUID(uuidString: raw) != nil else { continue }
                    native = raw
                default: continue
                }
                guard HumanIntervention.validID(native) else { continue }
                found.append(.init(sessionID: host.sessionID, nativeSessionID: native, agentKind: kind))
            }
            let counts = Dictionary(grouping: found, by: { "\($0.agentKind.rawValue):\($0.nativeSessionID)" })
            return found.filter { counts["\($0.agentKind.rawValue):\($0.nativeSessionID)"]?.count == 1 }
        }
    }
}
