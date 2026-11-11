import Foundation

/// Thrown when an agent's settings file exists but cannot be parsed as a JSON
/// object. Rewriting it anyway would replace whatever the user had with just
/// AgentPet's hooks, so install/uninstall refuse instead.
public enum HookInstallerError: LocalizedError, Equatable {
    case unreadableSettings(path: String)
    case foreignPlugin(path: String)
    case unsafeSettings(path: String)
    case settingsChanged(path: String)
    case unsupportedShape(path: String)
    case unrecognizedCommand

    public var errorDescription: String? {
        switch self {
        case .unsafeSettings(let path): return "Refusing linked or non-regular settings at \(path)."
        case .settingsChanged(let path): return "Settings changed; refusing to overwrite \(path)."
        case .unsupportedShape(let path): return "Unsupported hook structure at \(path); no files changed."
        case .unrecognizedCommand: return "Unsupported AgentPet hook command; no files changed."

        case .foreignPlugin(let path):
            return "Refusing to replace unrecognized plugin at \(path)."
        case .unreadableSettings(let path):
            return "\(path) is not valid JSON; fix or remove it and try again."
        }
    }
}

/// Installs/removes AgentPet's hook entries in an agent's config. Claude Code,
/// Codex, and Gemini share the nested `{"hooks": {...}}` shape; Cursor and
/// Windsurf use flatter JSON shapes; opencode uses a JS plugin file. The shape
/// is selected by `HookStyle`.
///
/// The dictionary transforms are pure (and tested); the `*OnDisk` helpers wrap
/// them with file IO. Our entries are identified by their command string, so
/// install is idempotent and foreign hooks are never touched.
public enum HookInstaller {
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SubagentStop",
    ]

    public static func defaultSettingsPath() -> String {
        NSHomeDirectory() + "/.claude/settings.json"
    }

    public static func isOurs(_ command: String) -> Bool {
        HookCommandOwnership.owns(command)
    }

    // MARK: - Claude-nested shape (Claude / Codex / Gemini)

    public static func isInstalled(in settings: [String: Any], events: [String] = events) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for event in events {
            guard let groups = hooks[event] as? [Any] else { continue }
            if groups.contains(where: { ($0 as? [String: Any]).map(groupIsOurs) ?? false }) { return true }
        }
        return false
    }

    public static func install(into settings: [String: Any], command: String, events: [String] = events) -> [String: Any] {
        var settings = settings
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { return settings }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            guard hooks[event] == nil || hooks[event] is [Any] else { continue }
            var groups = removingOwnedGroups(hooks[event] as? [Any] ?? [])
            groups.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    public static func uninstall(from settings: [String: Any], events: [String] = events) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        var modified = false
        for event in events {
            guard let groups = hooks[event] as? [Any] else { continue }
            let kept = removingOwnedGroups(groups)
            guard !NSArray(array: kept).isEqual(to: groups) else { continue }
            modified = true
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        guard modified else { return settings }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return settings
    }

    private static func groupIsOurs(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [Any] else { return false }
        return inner.contains { ($0 as? [String: Any]).map(handlerIsOurs) ?? false }
    }

    private static func removingOwnedHandlers(_ handlers: [Any]) -> [Any] {
        handlers.filter { !(($0 as? [String: Any]).map(handlerIsOurs) ?? false) }
    }

    static func removingOwnedGroups(_ groups: [Any], allowDirect: Bool = false) -> [Any] {
        groups.compactMap { value -> Any? in
            guard var group = value as? [String: Any] else { return value }
            if let handlers = group["hooks"] as? [Any] {
                let kept = removingOwnedHandlers(handlers)
                guard kept.count != handlers.count else { return value }
                if kept.isEmpty { return nil }
                group["hooks"] = kept
                return group
            }
            // Never reinterpret an unknown nested shape as a direct handler.
            if allowDirect && group["hooks"] == nil && handlerIsOurs(group) { return nil }
            return value
        }
    }

    // MARK: - Antigravity named-group shape (~/.gemini/config/hooks.json)
    // Same per-event structure as Claude-nested, but the event map sits under a
    // named hook group key instead of "hooks", alongside any other user groups:
    // {"agentpet": {Event: [{"hooks": [{"type": "command", "command": ...}]}]}}

    /// The hook-group key AgentPet owns in an Antigravity hooks.json.
    public static let antigravityGroup = "agentpet"

    /// Antigravity events that carry a tool `matcher` and a nested `hooks` array,
    /// like Claude. The rest (PreInvocation/PostInvocation/Stop) take a plain
    /// list of handlers directly under the event key.
    static let antigravityMatcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    /// A bare handler object `{"type":"command","command":...}` is ours.
    private static func handlerIsOurs(_ h: [String: Any]) -> Bool {
        (h["type"] == nil || h["type"] as? String == "command") && ((h["command"] as? String).map(isOurs) ?? false)
    }

    private static func antigravityEntryIsOurs(_ event: String, _ entry: [String: Any]) -> Bool {
        antigravityMatcherEvents.contains(event) ? groupIsOurs(entry) : handlerIsOurs(entry)
    }

    public static func installAntigravity(into settings: [String: Any], command: String, events: [String]) -> [String: Any] {
        var settings = settings
        guard settings[antigravityGroup] == nil || settings[antigravityGroup] is [String: Any] else { return settings }
        var group = settings[antigravityGroup] as? [String: Any] ?? [:]
        for event in Set(events + ["PreToolUse"]).sorted() {
            guard group[event] == nil || group[event] is [Any] else { continue }
            var entries = removingOwnedGroups(group[event] as? [Any] ?? [], allowDirect: true)
            guard events.contains(event) else {
                guard !NSArray(array: entries).isEqual(to: group[event] as? [Any] ?? []) else { continue }
                if entries.isEmpty { group.removeValue(forKey: event) } else { group[event] = entries }
                continue
            }
            if antigravityMatcherEvents.contains(event) {
                entries.append(["matcher": "*", "hooks": [["type": "command", "command": command]]])
            } else {
                entries.append(["type": "command", "command": command])
            }
            group[event] = entries
        }
        settings[antigravityGroup] = group
        return settings
    }

    public static func uninstallAntigravity(from settings: [String: Any], events: [String]) -> [String: Any] {
        var settings = settings
        guard var group = settings[antigravityGroup] as? [String: Any] else { return settings }
        var modified = false
        for event in Set(events + ["PreToolUse"]) {
            guard let entries = group[event] as? [Any] else { continue }
            let kept = removingOwnedGroups(entries, allowDirect: true)
            guard !NSArray(array: kept).isEqual(to: entries) else { continue }
            modified = true
            if kept.isEmpty { group.removeValue(forKey: event) } else { group[event] = kept }
        }
        guard modified else { return settings }
        if group.isEmpty { settings.removeValue(forKey: antigravityGroup) } else { settings[antigravityGroup] = group }
        return settings
    }

    public static func isInstalledAntigravity(in settings: [String: Any], events: [String]) -> Bool {
        guard let group = settings[antigravityGroup] as? [String: Any] else { return false }
        for event in events {
            guard let entries = group[event] as? [Any] else { continue }
            if entries.contains(where: { ($0 as? [String: Any]).map { antigravityEntryIsOurs(event, $0) } ?? false }) { return true }
        }
        return false
    }

    // MARK: - Flat shape (Cursor / Windsurf): {"hooks": {event: [{"command": ...}]}}

    private static func flatItemIsOurs(_ item: [String: Any]) -> Bool {
        handlerIsOurs(item)
    }

    static func installFlat(into settings: [String: Any], command: String, events: [String], style: HookStyle) -> [String: Any] {
        var settings = settings
        if style == .cursorFlat { settings["version"] = settings["version"] ?? 1 }
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { return settings }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            guard hooks[event] == nil || hooks[event] is [Any] else { continue }
            var items = removingOwnedHandlers(hooks[event] as? [Any] ?? [])
            var entry: [String: Any] = ["command": command]
            if style == .cursorFlat { entry["type"] = "command" }
            if style == .windsurfFlat { entry["show_output"] = false }
            items.append(entry)
            hooks[event] = items
        }
        settings["hooks"] = hooks
        return settings
    }

    static func uninstallFlat(from settings: [String: Any], events: [String]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        var modified = false
        for event in events {
            guard let items = hooks[event] as? [Any] else { continue }
            let kept = removingOwnedHandlers(items)
            guard !NSArray(array: kept).isEqual(to: items) else { continue }
            modified = true
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        guard modified else { return settings }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return settings
    }

    static func isInstalledFlat(in settings: [String: Any], events: [String]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for event in events {
            guard let items = hooks[event] as? [Any] else { continue }
            if items.contains(where: { ($0 as? [String: Any]).map(flatItemIsOurs) ?? false }) { return true }
        }
        return false
    }

    // MARK: - opencode JS plugin

    /// Extracts the agentpet binary path from a hook command like
    /// `"/path/to/agentpet" hook --agent opencode` (the first quoted token).
    static func binaryPath(fromCommand command: String) -> String {
        if let first = command.firstIndex(of: "\"") {
            let rest = command[command.index(after: first)...]
            if let second = rest.firstIndex(of: "\"") {
                return String(rest[..<second])
            }
        }
        return command.components(separatedBy: " ").first ?? command
    }

    static func opencodePlugin(binary: String) -> String {
        OpencodePlugin.source(binary: binary)
    }

    // MARK: - Pi TypeScript extension

    static func piExtension(binary: String) -> String {
        PiPlugin.source(binary: binary)
    }

    /// JSON-encodes a string for safe embedding in JS source. Slashes are left
    /// unescaped so embedded file paths stay readable (`"/a/b"`, not `"\/a\/b"`).
    private static func jsString(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        if let data = try? encoder.encode(s), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\(s)\""
    }

    // MARK: - Disk IO

    /// Reads an agent's settings file. A missing or empty file is an empty
    /// config; a file with content that does not parse as a JSON object throws,
    /// so callers never rewrite (and thereby wipe) settings they could not read.
    private static func decodeSettings(_ data: Data?, path: String) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.unreadableSettings(path: path)
        }
        return obj
    }

    public static func readSettings(path: String) throws -> [String: Any] {
        try decodeSettings(HookFileTransaction.read(path).data, path: path)
    }

    public static func writeSettings(_ settings: [String: Any], path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try HookFileTransaction.update(path: path) { before in
            _ = try decodeSettings(before, path: path)
            return data
        }
    }

    /// Unknown commands are preserved. Diagnostics identify locations only;
    /// they never print command text, arguments or arbitrary settings values.
    public static func ownershipWarnings(in value: Any, location: String = "settings") -> [String] {
        if let object = value as? [String: Any] {
            var warnings: [String] = []
            if let command = object["command"] as? String,
               command.localizedCaseInsensitiveContains("agentpet"), !handlerIsOurs(object) {
                warnings.append("Unrecognized AgentPet-like command preserved at " + location)
            }
            // Do not report arbitrary dictionary keys (they may contain user data).
            for key in ["hooks", antigravityGroup] {
                if let child = object[key] { warnings += ownershipWarnings(in: child, location: location + "." + key) }
            }
            for (index, key) in object.keys.sorted().enumerated() where key != "hooks" && key != antigravityGroup && key != "command" {
                if let child = object[key], child is [Any] || child is [String: Any] {
                    warnings += ownershipWarnings(in: child, location: location + ".entry[\(index)]")
                }
            }
            return warnings
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { ownershipWarnings(in: $0.element, location: location + "[\($0.offset)]") }
        }
        return []
    }

    static func validateRetiredSettings(_ settings: [String: Any], spec: AgentHookSpec) throws {
        try validate(settings, events: spec.events, style: spec.style, path: spec.settingsPath)
    }

    private static func validate(_ settings: [String: Any], events: [String], style: HookStyle, path: String) throws {
        let key = style == .antigravityNested ? antigravityGroup : "hooks"
        guard let value = settings[key] else { return }
        guard let map = value as? [String: Any] else { throw HookInstallerError.unsupportedShape(path: path) }
        for event in Set(events + (style == .antigravityNested ? ["PreToolUse"] : [])) {
            guard let value = map[event] else { continue }
            guard let entries = value as? [Any] else { throw HookInstallerError.unsupportedShape(path: path) }
            for entry in entries {
                if let group = entry as? [String: Any], let inner = group["hooks"], !(inner is [Any]) {
                    throw HookInstallerError.unsupportedShape(path: path)
                }
            }
        }
    }

    private static func editDisk(command: String?, path: String, events: [String], style: HookStyle) throws {
        if let command, !isOurs(command) { throw HookInstallerError.unrecognizedCommand }
        try HookFileTransaction.update(path: path) { before in
            switch style {
            case .opencodePlugin, .piExtension:
                if let before {
                    guard let old = String(data: before, encoding: .utf8),
                          style == .opencodePlugin ? OpencodePlugin.isOwned(old) : PiPlugin.isOwned(old) else {
                        throw HookInstallerError.foreignPlugin(path: path)
                    }
                }
                guard let command else { return nil }
                let binary = HookCommandOwnership.words(command)![0]
                return Data((style == .piExtension ? piExtension(binary: binary) : opencodePlugin(binary: binary)).utf8)
            case .jcodeToml:
                guard before == nil || String(data: before!, encoding: .utf8) != nil else {
                    throw HookInstallerError.unreadableSettings(path: path)
                }
                let old = before.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard command == nil else { throw HookInstallerError.unrecognizedCommand }
                let new = LegacyJcodeHookCodec.uninstall(in: old, events: events)
                return new == old ? before : Data(new.utf8)
            default:
                let old = try decodeSettings(before, path: path)
                try validate(old, events: events, style: style, path: path)
                for warning in ownershipWarnings(in: old) { fputs("AgentPet: \(warning)\n", stderr) }
                var new: [String: Any]
                switch style {
                case .claudeNested:
                    new = command.map { install(into: old, command: $0, events: events) } ?? uninstall(from: old, events: events)
                case .antigravityNested:
                    new = command.map { installAntigravity(into: old, command: $0, events: events) } ?? uninstallAntigravity(from: old, events: events)
                default:
                    guard command == nil else { throw HookInstallerError.unrecognizedCommand }
                    new = uninstallFlat(from: old, events: events)
                }
                let encoded = try JSONSerialization.data(withJSONObject: new, options: [.prettyPrinted, .sortedKeys])
                // Preserve exact original bytes (including formatting) on a no-op.
                let oldEncoded = try JSONSerialization.data(withJSONObject: old, options: [.prettyPrinted, .sortedKeys])
                return encoded == oldEncoded ? before : encoded
            }
        }
    }

    public static func installToDisk(command: String, path: String = defaultSettingsPath(),
                                     events: [String] = events, style: HookStyle = .claudeNested) throws {
        guard style != .cursorFlat, style != .windsurfFlat, style != .kiroFlat, style != .jcodeToml else {
            throw HookInstallerError.unrecognizedCommand
        }
        if let words = HookCommandOwnership.words(command), words.count == 4,
           let kind = AgentKind(rawValue: words[3]), RetiredAgentRegistry.ignores(kind) {
            throw HookInstallerError.unrecognizedCommand
        }
        try editDisk(command: command, path: path, events: events, style: style)
    }
    public static func uninstallFromDisk(path: String = defaultSettingsPath(),
                                         events: [String] = events, style: HookStyle = .claudeNested) throws {
        try editDisk(command: nil, path: path, events: events, style: style)
    }
    /// Restore a backup only while the installed bytes and permissions match.
    /// The rollback itself creates a new backup before making any change.
    public static func rollbackSettings(backup: String) throws {
        try HookFileTransaction.rollback(backup: backup)
    }

    public static func isInstalledOnDisk(path: String = defaultSettingsPath(),
                                         events: [String] = events, style: HookStyle = .claudeNested) -> Bool {
        switch style {
        case .claudeNested:
            return isInstalled(in: (try? readSettings(path: path)) ?? [:], events: events)
        case .cursorFlat, .windsurfFlat, .kiroFlat:
            return isInstalledFlat(in: (try? readSettings(path: path)) ?? [:], events: events)
        case .antigravityNested:
            return isInstalledAntigravity(in: (try? readSettings(path: path)) ?? [:], events: events)
        case .opencodePlugin, .piExtension:
            guard let snapshot = try? HookFileTransaction.read(path), let data = snapshot.data,
                  let s = String(data: data, encoding: .utf8) else { return false }
            return style == .opencodePlugin ? OpencodePlugin.isOwned(s) : PiPlugin.isOwned(s)
        case .jcodeToml:
            return LegacyJcodeHookCodec.isInstalled(in: ((try? String(contentsOfFile: path, encoding: .utf8)) ?? ""), events: events)
        }
    }
}
