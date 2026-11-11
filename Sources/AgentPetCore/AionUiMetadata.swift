import Foundation
import CSQLite

/// An exact host/native conversation association, independent of inherited TERM_PROGRAM.
public struct AionUiConversation: Codable, Equatable, Sendable {
    /// Membership role of this conversation's slot inside its AionUI Team.
    public enum TeamRole: String, Codable, Sendable { case lead, teammate }

    public let id: String
    public let nativeSessionID: String
    public let agentKind: AgentKind
    /// Validated AionUI Team identity; nil for non-Team conversations or when the
    /// stored team/slot association no longer checks out (archived, missing, reused).
    public let teamID: String?
    public let teamName: String?
    public let teamRole: TeamRole?

    public init(id: String, nativeSessionID: String, agentKind: AgentKind,
                teamID: String? = nil, teamName: String? = nil, teamRole: TeamRole? = nil) {
        self.id = id
        self.nativeSessionID = nativeSessionID
        self.agentKind = agentKind
        self.teamID = teamID
        self.teamName = teamName
        self.teamRole = teamRole
    }

    public var url: URL? {
        guard AionUiMetadata.validID(id) else { return nil }
        var components = URLComponents()
        components.scheme = "aionui"
        components.host = "navigate"
        components.queryItems = [URLQueryItem(name: "route", value: "/conversation/" + id)]
        return components.url
    }

    /// Team-level target; nil when the stored association is not a validated Team.
    public var teamURL: URL? {
        guard let teamID, AionUiMetadata.validID(teamID) else { return nil }
        var components = URLComponents()
        components.scheme = "aionui"
        components.host = "navigate"
        components.queryItems = [URLQueryItem(name: "route", value: "/team/" + teamID)]
        return components.url
    }
}

/// Attested live verification of one exact host association. Optional
/// everywhere so older snapshots stay readable: a missing record is
/// "historical / pending re-check", never a currently valid identity.
///
/// It binds the check to the exact identity it attested — the conversation,
/// the Team, the role and the session instance — so a recreated session, a
/// replaced conversation or a changed role cannot inherit an earlier check.
public struct AionUiVerification: Codable, Equatable, Sendable {
    public let conversationID: String
    public let teamID: String?
    public let teamRole: AionUiConversation.TeamRole?
    public let sessionCreatedAt: Date
    /// When the host check succeeded. A later failure drops the record
    /// entirely: an old success is history, not current evidence.
    public let verifiedAt: Date
    /// The process launch that produced this check. A check from an earlier
    /// launch is history even when it is only seconds old: a relaunch always
    /// waits for a fresh check. Optional so snapshots from older builds still
    /// decode (nil is never current).
    public let launchEpoch: String?

    public init(conversationID: String, teamID: String?, teamRole: AionUiConversation.TeamRole?,
                sessionCreatedAt: Date, verifiedAt: Date, launchEpoch: String? = nil) {
        self.conversationID = conversationID
        self.teamID = teamID
        self.teamRole = teamRole
        self.sessionCreatedAt = sessionCreatedAt
        self.verifiedAt = verifiedAt
        self.launchEpoch = launchEpoch
    }

    /// True when both attest the same identity (the check time and launch are
    /// not part of the identity, so a refreshed check never counts as a
    /// different one).
    public func attestsSameIdentity(as other: AionUiVerification?) -> Bool {
        guard let other else { return false }
        return conversationID == other.conversationID && teamID == other.teamID
            && teamRole == other.teamRole && sessionCreatedAt == other.sessionCreatedAt
    }
}

/// Identifies the current process launch. A host check stamped by an earlier
/// launch is history, never current evidence, so a relaunch always waits for a
/// fresh check instead of inheriting a recently persisted one.
public enum AionUiVerificationLaunch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = UUID().uuidString

    public static var epoch: String {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Test hook only: a real relaunch is a new process and therefore a new
    /// epoch. Production code never calls this.
    static func beginLaunch(_ id: String = UUID().uuidString) {
        lock.lock(); defer { lock.unlock() }
        current = id
    }
}

/// Reads association and display metadata only. Stored `finished` is NOT live turn state.
public enum AionUiMetadata {
    public struct Record: Equatable, Sendable {
        public let conversation: AionUiConversation
        public let title: String?

        public init(conversation: AionUiConversation, title: String?) {
            self.conversation = conversation
            self.title = title
        }
    }

    public enum Lookup: Equatable, Sendable {
        case matched(Record), notFound, ambiguous, unavailable
    }

    public static var defaultDatabase: String {
        NSHomeDirectory() + "/Library/Application Support/AionUi/aionui/aionui-backend.db"
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    public static func read(sessionID: String, agentKind: AgentKind,
                            database: String = defaultDatabase,
                            piSessionMap: String = NSHomeDirectory() + "/.pi/pi-acp/session-map.json") -> Lookup {
        var nativeID = sessionID
        if agentKind == .pi {
            switch PiACPIdentity.read(sessionID: sessionID, path: piSessionMap) {
            case .matched(let id): nativeID = id
            case .notFound: return .notFound
            case .ambiguous: return .ambiguous
            case .unavailable: return .unavailable
            }
        }
        return lookup(sessionID: sessionID, nativeID: nativeID, agentKind: agentKind, conversationID: nil, database: database)
    }

    /// A suspended ACP runtime can drop its native anchor. A previously verified
    /// binding still names the same conversation; never infer this from cwd/title.
    public static func revalidate(_ target: AionUiConversation, database: String = defaultDatabase) -> Lookup {
        guard target.url != nil else { return .notFound }
        return lookup(sessionID: target.nativeSessionID, nativeID: target.nativeSessionID, agentKind: target.agentKind,
                      conversationID: target.id, database: database)
    }

    private static func lookup(sessionID: String, nativeID: String, agentKind: AgentKind, conversationID: String?, database: String) -> Lookup {
        guard (agentKind == .pi ? PiACPIdentity.sessionFile(sessionID) != nil : validID(sessionID)),
              conversationID != nil || validID(nativeID),
              [.codex, .antigravity, .opencode, .pi].contains(agentKind) else { return .notFound }
        guard FileManager.default.fileExists(atPath: database) else { return .notFound }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return .unavailable
        }
        defer { sqlite3_close(db) }
        guard let connection = db else { return .unavailable }
        sqlite3_busy_timeout(connection, 100)
        var statement: OpaquePointer?
        let sql = """
        SELECT c.id, c.name, c.type, c.extra
        FROM conversations c LEFT JOIN acp_session s ON c.id = s.conversation_id
        WHERE \(conversationID == nil ? "s.session_id" : "c.id") = ? AND c.archived_at IS NULL LIMIT 17
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return .unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, conversationID ?? nativeID, -1, transient)
        var matches: [Record] = []
        var count = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return .unavailable }
            count += 1
            guard count <= 16 else { return .ambiguous }
            func string(_ column: Int32) -> String? {
                guard let pointer = sqlite3_column_text(statement, column), sqlite3_column_bytes(statement, column) <= 65_536 else { return nil }
                // Preserve the full SQLite byte length: a NUL must not turn an
                // invalid stored ID into a different, apparently valid route.
                return String(data: Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
            }
            guard let id = string(0), validID(id), let raw = string(3)?.data(using: .utf8),
                  let extra = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { continue }
            // ACP is a transport, not an agent identity. Never match by title/cwd.
            guard let backend = extra["backend"] as? String ?? string(2), backend == agentKind.rawValue else { continue }
            let title = string(1).map { String($0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(240)) }
            // A Team mark is kept even when verification fails: the session must
            // not silently degrade into an independent member page.
            let teamID = (extra["teamId"] as? String).flatMap { validID($0) ? $0 : nil }
            let team = teamInfo(db: connection, conversationID: id, backend: backend, teamID: teamID,
                                slotID: extra["slot_id"] as? String)
            matches.append(Record(conversation: AionUiConversation(id: id, nativeSessionID: sessionID, agentKind: agentKind,
                                                                   teamID: teamID, teamName: team?.name, teamRole: team?.role),
                                  title: title.flatMap { $0.isEmpty ? nil : $0 }))
        }
        guard matches.count <= 1 else { return .ambiguous }
        return matches.first.map(Lookup.matched) ?? .notFound
    }

    /// Verified Team membership for one stored association, evaluated on the
    /// caller's existing read-only connection so one lookup sees one snapshot.
    /// Requirements: the team exists and is not archived; exactly one `agents`
    /// entry names this slot; that entry's `conversation_id` and `backend` name
    /// this exact conversation; and role and `lead_agent_id` agree before a
    /// lead claim is accepted. The shipped spelling is `lead`; an unversioned
    /// `leader` alias is accepted defensively. Any shortfall returns nil while
    /// the raw Team mark stays on the conversation for safe display/navigation.
    static func teamInfo(db: OpaquePointer, conversationID: String, backend: String, teamID: String?, slotID: String?)
        -> (id: String, name: String, role: AionUiConversation.TeamRole)? {
        guard let teamID, let slotID, validID(teamID), validID(slotID) else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT name, lead_agent_id, agents FROM teams WHERE id = ? AND archived_at IS NULL LIMIT 2"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, teamID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func string(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column), sqlite3_column_bytes(statement, column) <= 65_536 else { return nil }
            return String(data: Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
        }
        guard let rawName = string(0), !rawName.isEmpty,
              let raw = string(2)?.data(using: .utf8),
              let agents = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else { return nil }
        let matching = agents.filter { $0["slot_id"] as? String == slotID }
        guard matching.count == 1, let slot = matching.first,
              slot["conversation_id"] as? String == conversationID,
              slot["backend"] as? String == backend,
              let roleText = slot["role"] as? String else { return nil }
        let lead = string(1)
        let isLeadSlot = lead == slotID
        let role: AionUiConversation.TeamRole
        switch roleText {
        case "lead", "leader":
            // A lead claim only holds while lead_agent_id names the same slot.
            guard isLeadSlot else { return nil }
            role = .lead
        case "teammate":
            // A slot that owns lead_agent_id must not present itself as a teammate.
            guard !isLeadSlot else { return nil }
            role = .teammate
        default: return nil
        }
        let name = String(rawName.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(240))
        guard !name.isEmpty else { return nil }
        return (teamID, name, role)
    }
}
