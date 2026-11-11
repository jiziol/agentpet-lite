import Foundation

/// Socket-only public text. Never a lifecycle event or persisted session field.
public struct DSHVisibleMessage: Decodable, Sendable, Equatable {
    public enum Mode: String, Decodable, Sendable { case snapshot, withdraw }
    public let profileID: String
    public let hostID: String
    public let hostStartedAt: Date
    public let sessionID: String
    public let turn: Int
    public let nativeSeq: Int
    public let observationRevision: Int
    public let itemID: String
    public let revision: Int
    public let timestamp: Date
    public let mode: Mode
    public let text: String
    public var sessionKey: String { "dsh:\(profileID):\(sessionID)" }
    private enum CodingKeys: String, CodingKey {
        case schema, turn, revision, timestamp, mode, text, role
        case profileID = "profile_id", hostID = "host_id", hostStartedAt = "host_started_at"
        case sessionID = "session_id", nativeSeq = "native_seq", itemID = "item_id"
        case observationRevision = "observation_revision", partType = "part_type"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decode(String.self, forKey: .profileID)
        hostID = try c.decode(String.self, forKey: .hostID)
        hostStartedAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .hostStartedAt))
        sessionID = try c.decode(String.self, forKey: .sessionID)
        turn = try c.decode(Int.self, forKey: .turn)
        nativeSeq = try c.decode(Int.self, forKey: .nativeSeq)
        observationRevision = try c.decode(Int.self, forKey: .observationRevision)
        itemID = try c.decode(String.self, forKey: .itemID)
        revision = try c.decode(Int.self, forKey: .revision)
        timestamp = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .timestamp))
        mode = try c.decode(Mode.self, forKey: .mode)
        text = try c.decode(String.self, forKey: .text)
        guard try c.decode(String.self, forKey: .schema) == "agentpet.dsh.speech.v1",
              try c.decode(String.self, forKey: .role) == "assistant",
              try c.decode(String.self, forKey: .partType) == "text",
              profileID.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil,
              UUID(uuidString: hostID) != nil, DSHObservation.validID(sessionID),
              itemID.range(of: "^[0-9]{1,16}$", options: .regularExpression) != nil,
              turn >= 0, nativeSeq >= 0, observationRevision > 0, revision > 0,
              [turn, nativeSeq, observationRevision, revision].allSatisfy({ $0 <= 9_007_199_254_740_991 }),
              timestamp.timeIntervalSince1970.isFinite, hostStartedAt.timeIntervalSince1970.isFinite,
              hostStartedAt <= timestamp, text.utf8.count <= 2048,
              mode != .withdraw || text.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid DSH public text"))
        }
    }
    static func isEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = object["schema"] as? String else { return false }
        return schema.hasPrefix("agentpet.dsh.speech.")
    }
    public static func decode(_ data: Data) -> Self? {
        guard data.count <= 8192 else { return nil }
        return try? EventCoding.decoder.decode(Self.self, from: data)
    }
}

/// At most one scheduled main-actor drain per bounded IO burst.
public final class DSHSpeechInbox: @unchecked Sendable {
    private struct Key: Hashable { let host: String; let session: String; let item: String }
    private let lock = NSLock()
    private var pending: [Key: DSHVisibleMessage] = [:]
    private var scheduled = false
    public init() {}
    public func offer(_ message: DSHVisibleMessage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = Key(host: message.hostID, session: message.sessionKey, item: message.itemID)
        if let old = pending[key], old.revision >= message.revision { return false }
        guard pending[key] != nil || pending.count < 128 else { return false }
        pending[key] = message
        guard !scheduled else { return false }
        scheduled = true; return true
    }
    public func take() -> [DSHVisibleMessage] {
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
