import Foundation

/// Explicit, one-shot migration of the eight known configuration files only.
/// No client uninstall, directory scan, trust edit or generic shell rewriting.
public enum RetiredHookMigration {
    public enum Status: String { case absent, unchanged, wouldRemove, removed, preservedUnrecognized, failed }
    public struct Report {
        public let kind: AgentKind
        public let path: String
        public let status: Status
        public let backup: String?
        public let diagnostic: String?
    }
    public static func run(home: String = NSHomeDirectory(), dryRun: Bool = true) -> [Report] {
        RetiredAgentRegistry.kinds.compactMap { kind in
            guard let spec = RetiredAgentRegistry.migrationSpec(for: kind, home: home) else { return nil }
            do {
                let before = try HookFileTransaction.read(spec.settingsPath)
                guard let data = before.data else { return Report(kind: kind, path: spec.settingsPath, status: .absent, backup: nil, diagnostic: nil) }
                let after: Data
                var unrecognized = false
                if spec.style == .jcodeToml {
                    guard let text = String(data: data, encoding: .utf8) else { throw HookInstallerError.unreadableSettings(path: spec.settingsPath) }
                    let output = LegacyJcodeHookCodec.uninstall(in: text, events: spec.events, retiredKind: kind)
                    after = Data(output.utf8)
                    unrecognized = output.localizedCaseInsensitiveContains("agentpet")
                } else {
                    guard let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw HookInstallerError.unreadableSettings(path: spec.settingsPath)
                    }
                    try HookInstaller.validateRetiredSettings(old, spec: spec)
                    let new = removingRetiredHooks(from: old, spec: spec)
                    unrecognized = !HookInstaller.ownershipWarnings(in: new).isEmpty
                    // No-op retains the exact bytes and permissions, including formatting.
                    if NSDictionary(dictionary: old).isEqual(to: new) { after = data }
                    else { after = try JSONSerialization.data(withJSONObject: new, options: [.prettyPrinted, .sortedKeys]) }
                }
                let changed = after != data
                let backup = changed && !dryRun ? try HookFileTransaction.commit(path: spec.settingsPath, before: before, after: after) : nil
                return Report(kind: kind, path: spec.settingsPath,
                    status: changed ? (dryRun ? .wouldRemove : .removed) : (unrecognized ? .preservedUnrecognized : .unchanged),
                    backup: backup, diagnostic: unrecognized ? "Unrecognized AgentPet-like entries preserved" : nil)
            } catch {
                // Never print malformed configuration or decoder details.
                return Report(kind: kind, path: spec.settingsPath, status: .failed, backup: nil,
                    diagnostic: "Configuration unreadable, unsafe, unsupported or changed; original preserved")
            }
        }
    }
    private static func removingRetiredHooks(from settings: [String: Any], spec: AgentHookSpec) -> [String: Any] {
        var result = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return result }
        func owned(_ value: Any) -> Bool {
            guard let handler = value as? [String: Any],
                  handler["type"] == nil || handler["type"] as? String == "command",
                  let command = handler["command"] as? String else { return false }
            return HookCommandOwnership.owns(command, retiredKind: spec.kind)
        }
        var modified = false
        for event in spec.events {
            guard let entries = hooks[event] as? [Any] else { continue }
            let kept: [Any] = entries.compactMap { value in
                if spec.style != .claudeNested { return owned(value) ? nil : value }
                guard var group = value as? [String: Any], let handlers = group["hooks"] as? [Any] else { return value }
                let retained = handlers.filter { !owned($0) }
                guard retained.count != handlers.count else { return value }
                if retained.isEmpty { return nil }
                group["hooks"] = retained
                return group
            }
            guard !NSArray(array: kept).isEqual(to: entries) else { continue }
            modified = true
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        guard modified else { return result }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }

}
