import Foundation
import CSQLite

/// A committed public response, not a token stream. These field numbers were
/// checked against the installed agy 1.3.2 descriptors and real completed rows.
public struct AntigravityVisibleMessage: Sendable {
    public struct Boundary: Sendable, Equatable {
        public let sessionID: String
        public let createdAt: Date
        public let generation: Int?
        public let startedAt: Date
        public let hookAt: Date
        public let stepFloor: Int
        public let enabledAt: Date
        public let hosted: Bool
        public let completedAt: Date?
        public init?(session: AgentSession, enabledAt: Date) {
            guard session.agentKind == .antigravity, UUID(uuidString: session.id) != nil,
                  [.working, .waiting, .done].contains(session.state), session.taskResult != .cancelled,
                  let started = session.turnStartedAt, let hook = session.antigravityEventAt,
                  let floor = session.antigravityStepFloor, floor >= 0 else { return nil }
            sessionID = session.id; createdAt = session.createdAt; generation = session.interactionGeneration
            startedAt = started; hookAt = hook; stepFloor = floor; self.enabledAt = enabledAt
            hosted = session.validAionUiConversation != nil
            completedAt = session.taskResult == .completed ? session.turnEndedAt : nil
        }
        public func matches(_ session: AgentSession) -> Bool {
            session.id == sessionID && session.agentKind == .antigravity && session.createdAt == createdAt
                && session.interactionGeneration == generation && session.turnStartedAt == startedAt
                && session.antigravityEventAt == hookAt && session.antigravityStepFloor == stepFloor
                && (session.validAionUiConversation != nil) == hosted
                && (session.taskResult == .completed ? session.turnEndedAt : nil) == completedAt
                && session.taskResult != .cancelled && [.working, .waiting, .done].contains(session.state)
        }
    }
    public enum Mode: Sendable { case snapshot, withdraw }
    public let boundary: Boundary
    public let executionID: String
    public let stepIndex: Int
    public let timestamp: Date
    public let revision: Int
    public let mode: Mode
    public let text: String
    public var itemID: String { "\(executionID):\(stepIndex)" }
}

enum AntigravityPublicResponse {
    struct Step: Sendable {
        let index: Int
        let executionID: String
        let completedAt: Date
        let text: String
    }
    struct Snapshot { let step: Step?; let cancelled: Bool }
    // Unknown fields are skipped by byte length. In particular, thinking and
    // raw_thinking are never copied or decoded as strings.
    static func fields(_ data: Data, selecting: Set<Int>) -> [Int: Data]? {
        guard data.count <= 1_048_576 else { return nil }
        return data.withUnsafeBytes { raw -> [Int: Data]? in
            let bytes = raw.bindMemory(to: UInt8.self); var offset = 0; var count = 0
            var result: [Int: Data] = [:]
            func varint() -> UInt64? {
                var value: UInt64 = 0
                for shift in stride(from: 0, through: 63, by: 7) {
                    guard offset < bytes.count else { return nil }
                    let byte = bytes[offset]; offset += 1
                    guard shift != 63 || byte <= 1 else { return nil }
                    value |= UInt64(byte & 127) << shift
                    if byte < 128 { return value }
                }
                return nil
            }
            while offset < bytes.count {
                count += 1
                guard count <= 4096, let tag = varint(), tag >> 3 > 0 else { return nil }
                let number = Int(tag >> 3)
                switch tag & 7 {
                case 0:
                    guard let value = varint() else { return nil }
                    if selecting.contains(number) {
                        var n = value.littleEndian
                        result[number] = withUnsafeBytes(of: &n) { Data($0) }
                    }
                case 2:
                    guard let length = varint(), length <= UInt64(bytes.count - offset) else { return nil }
                    let end = offset + Int(length)
                    if selecting.contains(number) { result[number] = Data(bytes[offset..<end]) }
                    offset = end
                case 1, 5:
                    let length = tag & 7 == 1 ? 8 : 4
                    guard offset + length <= bytes.count else { return nil }; offset += length
                default: return nil
                }
            }
            return result
        }
    }
    static func integer(_ data: Data?) -> UInt64? {
        guard let data, data.count == 8 else { return nil }
        return data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
    static func date(_ data: Data?) -> Date? {
        guard let data, let f = fields(data, selecting: [1, 2]), let seconds = integer(f[1]),
              seconds > 0, seconds < 253_402_300_800 else { return nil }
        let nanos = integer(f[2]) ?? 0
        guard nanos < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }
    static func step(index: Int, metadata: Data, payload: Data) -> Step? {
        guard index >= 0, let m = fields(metadata, selecting: [1, 6, 7, 8, 12]),
              let b = fields(payload, selecting: [1, 4, 20]), integer(b[1]) == 15, integer(b[4]) == 3,
              let planner = b[20], let response = fields(planner, selecting: [1, 8]),
              let id = m[12].flatMap({ String(data: $0, encoding: .utf8) }),
              HumanIntervention.validID(id), id.utf8.count <= 160, !id.contains(":"),
              let created = date(m[1]), let viewable = date(m[6]),
              let completed = [date(m[7]), date(m[8])].compactMap({ $0 }).max(),
              completed >= created, completed >= viewable else { return nil }
        let body = (response[8].flatMap { $0.isEmpty ? nil : $0 }) ?? response[1]
        guard let body, let text = String(data: body, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Step(index: index, executionID: id, completedAt: completed, text: text)
    }
    static func read(path: String, boundary: AntigravityVisibleMessage.Boundary) -> Snapshot? {
        let fm = FileManager.default
        guard let before = try? fm.attributesOfItem(atPath: path),
              ((before[.size] as? NSNumber)?.int64Value ?? .max) <= 67_108_864,
              !fm.fileExists(atPath: path + "-journal"), !fm.fileExists(atPath: path + "-wal") else { return nil }
        var url = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "mode", value: "ro"), .init(name: "immutable", value: "1")]
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.string!, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        var total = 0
        func blob(_ s: OpaquePointer?, _ column: Int32) -> Data? {
            let n = Int(sqlite3_column_bytes(s, column)); total += n
            guard n > 0, n <= 1_048_576, total <= 4_194_304, let p = sqlite3_column_blob(s, column) else { return nil }
            return Data(bytes: p, count: n)
        }
        var executor: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM executor_metadata ORDER BY idx DESC LIMIT 1", -1, &executor, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(executor) }
        guard sqlite3_step(executor) == SQLITE_ROW, let data = blob(executor, 0),
              let e = fields(data, selecting: [1, 3, 9]), let identity = e[9] else { return nil }
        let cancelled = integer(e[1]) == 2 && (integer(e[3]) ?? 0) >= UInt64(boundary.stepFloor)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT idx,metadata,step_payload FROM steps WHERE step_type=15 AND status=3 AND idx>=? AND length(metadata)<=1048576 AND length(step_payload)<=1048576 ORDER BY idx DESC LIMIT 32", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(boundary.stepFloor))
        var selected: Step?
        while !cancelled {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let meta = blob(stmt, 1), let payload = blob(stmt, 2) else { return nil }
            if let step = step(index: Int(sqlite3_column_int64(stmt, 0)), metadata: meta, payload: payload),
               Data(step.executionID.utf8) == identity, step.completedAt >= boundary.startedAt {
                selected = step; break
            }
        }
        guard let after = try? fm.attributesOfItem(atPath: path),
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
              !fm.fileExists(atPath: path + "-journal"), !fm.fileExists(atPath: path + "-wal") else { return nil }
        return Snapshot(step: selected, cancelled: cancelled)
    }
}

/// Host visibility is checked only for the exact native/session association.
/// A previously matched host row remains the authority for rewrite/withdraw.
enum AntigravityHostVisibility {
    struct Row { let id: String; let text: String? }
    static func read(nativeID: String, step: AntigravityPublicResponse.Step,
                     startedAt: Date, knownRow: String?, previouslyHosted: Bool = false, database: String) -> Row? {
        let target: AionUiConversation
        switch AionUiMetadata.read(sessionID: nativeID, agentKind: .antigravity, database: database) {
        case .matched(let record): target = record.conversation
        case .notFound:
            if let knownRow { return Row(id: knownRow, text: nil) }
            return previouslyHosted ? nil : Row(id: "", text: step.text)
        default: return nil
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db, 50)
        var s: OpaquePointer?
        let sql = "SELECT msg_id,content,hidden,type,position FROM messages WHERE conversation_id=? AND \(knownRow == nil ? "created_at>=? AND type='text' AND position='left'" : "msg_id=?") ORDER BY created_at DESC LIMIT 16"
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(s) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(s, 1, target.id, -1, transient)
        if let knownRow { sqlite3_bind_text(s, 2, knownRow, -1, transient) }
        else { sqlite3_bind_int64(s, 2, Int64(startedAt.timeIntervalSince1970 * 1000)) }
        var result: [Row] = []; var total = 0
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { break }; guard code == SQLITE_ROW else { return nil }
            func string(_ col: Int32, limit: Int = 1_048_576) -> String? {
                let n = Int(sqlite3_column_bytes(s, col)); total += n
                guard n <= limit, total <= 4_194_304, let p = sqlite3_column_text(s, col) else { return nil }
                return String(data: Data(bytes: p, count: n), encoding: .utf8)
            }
            guard let id = string(0, limit: 128), !id.isEmpty else { continue }
            if sqlite3_column_type(s, 2) == SQLITE_NULL || sqlite3_column_int(s, 2) != 0 || string(3, limit: 64) != "text" || string(4, limit: 16) != "left" {
                if knownRow != nil { return Row(id: id, text: nil) }; continue
            }
            guard let encoded = string(1)?.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  let text = root["content"] as? String else { continue }
            if knownRow != nil || text.trimmingCharacters(in: .whitespacesAndNewlines) == step.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                result.append(Row(id: id, text: knownRow == nil ? step.text : text))
            }
        }
        if result.isEmpty, let knownRow { return Row(id: knownRow, text: nil) }
        return result.count == 1 ? result.first : nil
    }
}
