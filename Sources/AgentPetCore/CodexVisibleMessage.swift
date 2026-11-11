import Foundation

/// A bounded copy of user-visible assistant text. Never accepts reasoning,
/// prompts, tool arguments/results or messages without an explicit public phase.
public struct CodexVisibleMessage: Sendable, Equatable {
    public let turnID: String
    public let turnStartedAt: Date?
    public let timestamp: Date
    public let phase: String
    public let text: String

    public static func parse(_ data: Data, turnID: String?, turnStartedAt: Date? = nil) -> Self? {
        guard data.count <= 1_048_576, let turnID, !turnID.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "response_item",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "message", payload["role"] as? String == "assistant",
              let phase = payload["phase"] as? String, ["commentary", "final_answer"].contains(phase),
              let timestamp = CodexLifecycle.date(root["timestamp"]),
              let content = payload["content"] as? [[String: Any]] else { return nil }
        // Only plain output_text blocks are displayable. Bound before joining.
        let parts = content.prefix(16).compactMap { block -> String? in
            guard block["type"] as? String == "output_text", let text = block["text"] as? String else { return nil }
            return String(text.prefix(320))
        }
        let plain = parts.joined(separator: " ").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }.map(String.init).joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !plain.isEmpty else { return nil }
        let text = String(plain.prefix(160)) + (plain.count > 160 ? "…" : "")
        return Self(turnID: turnID, turnStartedAt: turnStartedAt, timestamp: timestamp, phase: phase, text: text)
    }
}
