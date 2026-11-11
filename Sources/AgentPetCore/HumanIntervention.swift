import Foundation

/// Observer metadata only. Never contains questions, options, answers or commands.
public struct HumanRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case choice, reply, permission }
    public let id: String
    public let kind: Kind
    public let createdAt: Date

    public init(id: String, kind: Kind, createdAt: Date) {
        self.id = id; self.kind = kind; self.createdAt = createdAt
    }

    public var message: String {
        switch kind {
        case .choice: return "等待你的选择"
        case .reply: return "等待你的回复"
        case .permission: return "等待批准"
        }
    }
}

public struct HumanIntervention: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case asked, resolved }
    public let action: Action
    public let requests: [HumanRequest]
    public init(action: Action, requests: [HumanRequest]) {
        self.action = action; self.requests = requests
    }

    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 320 && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Explicit envelopes let new adapters share the same request/receipt rules.
    public static func decode(_ value: Any?, at timestamp: Date) -> HumanIntervention? {
        guard let object = value as? [String: Any],
              let action = (object["action"] as? String).flatMap(Action.init(rawValue:)),
              let ids = object["request_ids"] as? [String], !ids.isEmpty, ids.count <= 64,
              ids.allSatisfy(validID) else { return nil }
        let kind = (object["kind"] as? String).flatMap(HumanRequest.Kind.init(rawValue:)) ?? .reply
        return HumanIntervention(action: action, requests: Array(Set(ids)).sorted().map {
            HumanRequest(id: $0, kind: kind, createdAt: timestamp)
        })
    }

    /// Only known interactive tools, never a guess based on a message ending in '?'.
    public static func toolKind(_ tool: String?) -> HumanRequest.Kind? {
        let name = tool?.components(separatedBy: ".").last?.lowercased()
        switch name {
        case "askuserquestion", "request_user_input", "request_user_input_async": return .choice
        default: return nil
        }
    }
}
