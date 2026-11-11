import Foundation

/// Read-only hints for conventional Codex feature flags. Hooks are enabled by
/// default in the maintained client. Native config resolution (including
/// profiles, CLI flags and managed policy) and trust review remain authoritative.
/// Never edit shared TOML or hook trust as part of installing/removing AgentPet.
public enum CodexHookConfig {
    /// A project path mentioning AgentPet and an unrelated `features.hooks`
    /// flag are not a second registration. Inspect values in hooks/notify
    /// namespaces only; this is a read-only guard, not native TOML resolution.
    public static func hasAgentPetHookReference(in toml: String) -> Bool {
        var table: [String] = []
        for statement in statements(in: toml) {
            if statement.first == .mark("[") {
                let body = statement.drop(while: { $0 == .mark("[") })
                    .reversed().drop(while: { $0 == .mark("]") }).reversed()
                table = keyPath(Array(body)) ?? []
                continue
            }
            guard let equals = statement.firstIndex(of: .mark("=")),
                  let key = keyPath(Array(statement[..<equals])) else { continue }
            let path = table + key
            let root = path.first == "profiles" && path.count >= 3 ? path[2] : path.first
            guard root == "hooks" || root == "notify" else { continue }
            if statement.dropFirst(equals + 1).contains(where: {
                if case .string(let value) = $0 { return value.localizedCaseInsensitiveContains("agentpet") }
                return false
            }) { return true }
        }
        return false
    }

    private enum Token: Equatable {
        case word(String), string(String), mark(Character)
    }

    private static func keyPath(_ tokens: [Token]) -> [String]? {
        guard !tokens.isEmpty, tokens.count % 2 == 1 else { return nil }
        var path: [String] = []
        for (index, token) in tokens.enumerated() {
            if index % 2 == 1 {
                guard token == .mark(".") else { return nil }
            } else {
                switch token {
                case .word(let value), .string(let value): path.append(value)
                default: return nil
                }
            }
        }
        return path
    }

    /// Keep quoted strings opaque, including multiline strings and `#` inside
    /// commands. Newlines finish statements only outside arrays/inline tables.
    private static func statements(in text: String) -> [[Token]] {
        let chars = Array(text)
        var index = 0, depth = 0, current: [Token] = [], result: [[Token]] = []
        let marks: Set<Character> = ["[", "]", "{", "}", "=", ".", ","]
        while index < chars.count {
            let char = chars[index]
            if char == "#" {
                while index < chars.count, !chars[index].isNewline { index += 1 }
            } else if char == "\"" || char == "'" {
                let multiline = index + 2 < chars.count && chars[index + 1] == char && chars[index + 2] == char
                index += multiline ? 3 : 1
                var value = ""
                while index < chars.count {
                    if chars[index] == char,
                       !multiline || (index + 2 < chars.count && chars[index + 1] == char && chars[index + 2] == char) {
                        index += multiline ? 3 : 1
                        break
                    }
                    if char == "\"", chars[index] == "\\", index + 1 < chars.count {
                        index += 1
                        let escape = chars[index]
                        if escape == "u" || escape == "U" {
                            let length = escape == "u" ? 4 : 8
                            if index + length < chars.count,
                               let code = UInt32(String(chars[(index + 1)...(index + length)]), radix: 16),
                               let scalar = UnicodeScalar(code) {
                                value.unicodeScalars.append(scalar)
                                index += length + 1
                                continue
                            }
                        }
                    }
                    value.append(chars[index]); index += 1
                }
                current.append(.string(value))
            } else if char.isWhitespace {
                if char.isNewline, depth == 0, !current.isEmpty { result.append(current); current = [] }
                index += 1
            } else if marks.contains(char) {
                current.append(.mark(char))
                if char == "[" || char == "{" { depth += 1 }
                if char == "]" || char == "}" { depth = max(0, depth - 1) }
                index += 1
            } else {
                let start = index
                while index < chars.count, !chars[index].isWhitespace,
                      !marks.contains(chars[index]), !["#", "\"", "'"].contains(chars[index]) { index += 1 }
                current.append(.word(String(chars[start..<index])))
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func isExplicitlyDisabled(in toml: String) -> Bool {
        var table = "", values: [String: Bool] = [:]
        for raw in toml.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
                continue
            }
            guard table == "[features]", let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if ["hooks", "codex_hooks"].contains(key), ["true", "false"].contains(value) { values[key] = value == "true" }
        }
        return (values["hooks"] ?? values["codex_hooks"]) == false
    }
}
