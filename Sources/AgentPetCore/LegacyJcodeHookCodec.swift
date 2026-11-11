import Foundation

/// Legacy TOML codec for conservative retired Hook removal only.
public enum LegacyJcodeHookCodec {
    /// Line indices of the `[hooks]` table body: after its header, up to the
    /// next table header. `nil` when the table is absent.
    static func hooksBody(_ lines: [String]) -> (header: Int, end: Int)? {
        guard let header = lines.firstIndex(where: isHooksHeader) else { return nil }
        var end = header + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            end += 1
        }
        return (header, end)
    }

    /// True for any spelling of the `[hooks]` header TOML allows: a trailing
    /// comment, CRLF line endings, or spaces inside the brackets. Missing one
    /// would append a second `[hooks]` table, which is invalid TOML, and jcode
    /// then silently falls back to its default config.
    static func isHooksHeader(_ line: String) -> Bool {
        let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return code.filter { !$0.isWhitespace } == "[hooks]"
    }

    /// Index of the uncommented `key = ...` line in the hooks body, if any.
    static func keyLine(_ key: String, in lines: [String], body: (header: Int, end: Int)) -> Int? {
        (body.header + 1 ..< body.end).first { i in
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key) else { return false }
            return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
    }

    /// TOML string for `command`: a literal string when possible (no escaping
    /// of the embedded double quotes), otherwise an escaped basic string.
    static func tomlString(_ command: String) -> String {
        if !command.contains("'") && !command.contains("\n") { return "'\(command)'" }
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    public static func isInstalled(in toml: String, events: [String]) -> Bool {
        let lines = toml.components(separatedBy: "\n")
        guard let body = hooksBody(lines) else { return false }
        return events.contains { event in
            keyLine(event, in: lines, body: body).map { HookCommandOwnership.ownsTOMLAssignment(lines[$0]) } ?? false
        }
    }

    /// Removes only AgentPet's keys; foreign hooks and the table header stay.
    public static func uninstall(in toml: String, events: [String], retiredKind: AgentKind? = nil) -> String {
        var lines = toml.components(separatedBy: "\n")
        for event in events {
            guard let body = hooksBody(lines),
                  let i = keyLine(event, in: lines, body: body),
                  HookCommandOwnership.ownsTOMLAssignment(lines[i], retiredKind: retiredKind) else { continue }
            lines.remove(at: i)
        }
        return lines.joined(separator: "\n")
    }

}
