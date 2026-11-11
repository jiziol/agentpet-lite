import Foundation

/// Ephemeral socket-only envelope. Never an AgentEvent or a persisted observation.
public struct OpencodeVisibleMessage: Sendable, Equatable, Decodable {
    public static let schema = "agentpet.opencode.speech.v1"
    public enum Mode: String, Sendable, Decodable { case snapshot, withdraw }
    public let sessionID: String
    public let turnID: String
    public let messageID: String
    public let partID: String
    public let processID: Int32
    public let revision: Int
    public let timestamp: Date
    public let mode: Mode
    public let text: String

    private enum CodingKeys: String, CodingKey {
        case schema, role, synthetic, ignored, revision, timestamp, mode, text
        case sessionID = "session_id", turnID = "parent_id", messageID = "message_id"
        case partID = "part_id", processID = "process_id", partType = "part_type"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        turnID = try c.decode(String.self, forKey: .turnID)
        messageID = try c.decode(String.self, forKey: .messageID)
        partID = try c.decode(String.self, forKey: .partID)
        processID = try c.decode(Int32.self, forKey: .processID)
        revision = try c.decode(Int.self, forKey: .revision)
        let seconds = try c.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: seconds)
        mode = try c.decode(Mode.self, forKey: .mode)
        text = try c.decode(String.self, forKey: .text)
        guard try c.decode(String.self, forKey: .schema) == Self.schema,
              try c.decode(String.self, forKey: .role) == "assistant",
              try c.decode(String.self, forKey: .partType) == "text",
              try c.decode(Bool.self, forKey: .synthetic) == false,
              try c.decode(Bool.self, forKey: .ignored) == false,
              Self.validID(sessionID, prefix: "ses_"), Self.validID(turnID, prefix: "msg_"),
              Self.validID(messageID, prefix: "msg_"), Self.validID(partID, prefix: "prt_"),
              processID > 1, revision > 0, revision <= 9_007_199_254_740_991,
              seconds.isFinite, text.utf8.count <= 2048,
              mode != .withdraw || text.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid visible-text envelope"))
        }
    }
    private static func validID(_ id: String, prefix: String) -> Bool {
        id.hasPrefix(prefix) && id.utf8.count > prefix.utf8.count && id.utf8.count <= 128 &&
            id.dropFirst(prefix.count).utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
    static func isEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["schema"] as? String else { return false }
        return name.hasPrefix("agentpet.opencode.speech.")
    }
    static func decode(_ data: Data) -> Self? {
        guard data.count <= 8192 else { return nil }
        return try? EventCoding.decoder.decode(Self.self, from: data)
    }
}

/// Coalesces an IO burst into one main-actor delivery. Text stays bounded in memory.
public final class OpencodeSpeechInbox: @unchecked Sendable {
    private struct Key: Hashable { let session: String; let part: String }
    private let lock = NSLock()
    private var pending: [Key: OpencodeVisibleMessage] = [:]
    private var scheduled = false
    public init() {}
    public func offer(_ message: OpencodeVisibleMessage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = Key(session: message.sessionID, part: message.partID)
        if let old = pending[key], old.timestamp > message.timestamp ||
            (old.timestamp == message.timestamp && old.revision >= message.revision) { return false }
        if pending[key] == nil && pending.count >= 128 { return false }
        pending[key] = message
        guard !scheduled else { return false }
        scheduled = true; return true
    }
    public func take() -> [OpencodeVisibleMessage] {
        lock.lock(); defer { lock.unlock() }
        let result = pending.values.sorted { $0.timestamp == $1.timestamp ? $0.revision < $1.revision : $0.timestamp < $1.timestamp }
        pending.removeAll(keepingCapacity: true); scheduled = false
        return result
    }
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll(); scheduled = false
    }
}
