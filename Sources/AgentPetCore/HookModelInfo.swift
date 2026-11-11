import Foundation

/// Decodes a hook payload's `model` field into a display name. Tolerates
/// every shape we might see — `{"display_name": "...", "id": "..."}`,
/// `{"id": "..."}` only, a bare string, or the key being absent entirely —
/// and never throws, so an unexpected `model` shape can't fail the decode
/// of the surrounding hook payload.
public struct HookModelInfo: Decodable, Equatable {
    public let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case id
    }

    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            let name = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
            let id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
            displayName = name ?? id
        } else if let single = try? decoder.singleValueContainer(),
                  let str = try? single.decode(String.self) {
            displayName = str
        } else {
            displayName = nil
        }
    }
}

