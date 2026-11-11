import Foundation
#if !HOOK_PORTABLE
@testable import AgentPetCore
#endif

enum HookOwnershipScenarios {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func runAll() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw Failure(description: name) }; count += 1
        }
        func equal(_ a: Any, _ b: Any) throws -> Bool {
            try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .fragmentsAllowed]) ==
                JSONSerialization.data(withJSONObject: b, options: [.sortedKeys, .fragmentsAllowed])
        }
        func rejects(_ name: String, _ action: () throws -> Void) throws {
            do { try action() } catch { count += 1; return }
            throw Failure(description: "Expected rejection: " + name)
        }
        let cmd = "\"/Applications/AgentPet Local.app/Contents/MacOS/agentpet\" hook --agent claude"
        let old = "/opt/agentpet hook"
        let owned: [String: Any] = ["type": "command", "command": old]
        let foreign: [String: Any] = ["type": "command", "command": "echo agentpet hook", "timeout": 7]
        let unusual: [String: Any] = ["type": "prompt", "command": old, "unknown": true]
        for command in [cmd, old, "agentpet hook", "'/a b/agentpet' hook --agent antigravity", "/a\\ b/agentpet hook --agent codex", "\"/a b's/agentpet\" hook"] {
            try check(HookInstaller.isOurs(command), "recognize direct invocation")
        }
        for command in ["echo agentpet hook", "agentpet-hook hook", "/tmp/agentpet-helper hook", "agentpet hook-other", "agentpet hook --agent unknown-agent", "agentpet hook; echo other", "agentpet hook && audit", "env agentpet hook", "sh -c 'agentpet hook'", "\"$(echo agentpet)\" hook", "agentpet hook > /tmp/a", "# agentpet hook", "agentpet hook\necho other", "\"agentpet hook", "agentpet hook --extra", "relative/agentpet hook", "agentpet hook --agent claude extra"] {
            try check(!HookInstaller.isOurs(command), "reject ambiguous invocation")
        }
        let group: [String: Any] = ["matcher": "Bash|Read", "timeout": 42, "future": ["keep": true], "hooks": [foreign, owned, unusual, 17, NSNull()]]
        let empty: [String: Any] = ["matcher": "original-empty", "hooks": []]
        let original: [String: Any] = ["model": "keep", "hooks": ["Stop": [group, empty, "future-group", ["hooks": [owned]]], "Untouched": [owned]]]
        var keptGroup = group; keptGroup["hooks"] = [foreign, unusual, 17, NSNull()]
        let expected: [String: Any] = ["model": "keep", "hooks": ["Stop": [keptGroup, empty, "future-group"], "Untouched": [owned]]]
        let removed = HookInstaller.uninstall(from: original, events: ["Stop"])
        try check(try equal(removed, expected), "uninstall preserves mixed group metadata, order and unknown members")
        let installed = HookInstaller.install(into: original, command: cmd, events: ["Stop"])
        try check(try equal(HookInstaller.uninstall(from: installed, events: ["Stop"]), expected), "install preserves all foreign content")
        try check(try equal(HookInstaller.install(into: installed, command: cmd, events: ["Stop"]), installed), "nested idempotence")
        try check(HookInstaller.isInstalled(in: installed, events: ["Stop"]), "detect with unknown array members")
        try check(!HookInstaller.isInstalled(in: removed, events: ["Stop"]), "foreign references not installed")
        try check(!HookInstaller.ownershipWarnings(in: original).isEmpty, "unknown ownership reports locations")
        for style: HookStyle in [.cursorFlat, .windsurfFlat, .kiroFlat] {
            let flat: [String: Any] = ["name": "keep", "hooks": ["Stop": [foreign, owned, unusual, 42]]]
            let result = HookInstaller.installFlat(into: flat, command: cmd, events: ["Stop"], style: style)
            let uninstalled = HookInstaller.uninstallFlat(from: result, events: ["Stop"])
            let handlers = (uninstalled["hooks"] as! [String: Any])["Stop"]!
            try check(try equal(handlers, [foreign, unusual, 42]), "flat preserves foreign handlers")
            try check(try equal(result, HookInstaller.installFlat(into: result, command: cmd, events: ["Stop"], style: style)), "flat idempotence")
        }
        let agy: [String: Any] = ["third-party": ["value": true], "agentpet": ["PreToolUse": [group], "Stop": [owned, foreign, 1]]]
        let agyInstalled = HookInstaller.installAntigravity(into: agy, command: cmd, events: ["Stop", "PostToolUse"])
        let agyRemoved = HookInstaller.uninstallAntigravity(from: agyInstalled, events: ["Stop", "PostToolUse"])
        let agyExpected: [String: Any] = ["third-party": ["value": true], "agentpet": ["PreToolUse": [keptGroup], "Stop": [foreign, 1]]]
        try check(try equal(agyRemoved, agyExpected), "agy legacy permission cleanup preserves third parties")
        try check(try equal(agyInstalled, HookInstaller.installAntigravity(into: agyInstalled, command: cmd, events: ["Stop", "PostToolUse"])), "agy idempotence")
        for unknown: [String: Any] in [["hooks": "future"], ["hooks": ["Stop": "future"]]] {
            try check(try equal(unknown, HookInstaller.install(into: unknown, command: cmd, events: ["Stop"])), "unknown pure shape preserved")
        }
        let untouchedEmpty: [String: Any] = ["hooks": ["Stop": []]]
        try check(try equal(untouchedEmpty, HookInstaller.uninstall(from: untouchedEmpty, events: ["Stop"])), "uninstall preserves preexisting empty events")
        try check(try equal(["hooks": [:]], HookInstaller.uninstall(from: ["hooks": [:]])), "uninstall preserves empty foreign map")
        let toml = "[hooks]\nturn_end = '\(old)' # own\nother = 'echo other'\n"
        let moved = toml
        try check(LegacyJcodeHookCodec.isInstalled(in: moved, events: ["turn_end"]), "TOML scalar recognized")
        try check(LegacyJcodeHookCodec.uninstall(in: moved, events: ["turn_end"]).contains("other = 'echo other'"), "TOML foreign line preserved")
        let shared = "[hooks]\nturn_end = ['\(old)', 'audit']\n"
        try check(LegacyJcodeHookCodec.uninstall(in: shared, events: ["turn_end"]) == shared, "TOML mixed array retained")
        try check(HookCommandOwnership.ownsTOMLAssignment("x = " + LegacyJcodeHookCodec.tomlString("\"/a b's/agentpet\" hook")), "TOML escaped basic string")
        let pi = PiPlugin.source(binary: "/x/agentpet")
        try check(PiPlugin.isOwned(pi), "Pi uses source ownership, not shell lexer")
        try check(!PiPlugin.isOwned(pi + "\n// custom"), "modified Pi preserved")
        try check(PiPlugin.isOwned(PiPlugin.legacySource(binary: "/Applications/AgentPet.app/Contents/MacOS/agentpet")), "official legacy Pi upgrade recognized")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentpet-hook-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("settings.json").path
        let url = URL(fileURLWithPath: path)
        try check(try HookInstaller.readSettings(path: path).isEmpty, "missing settings readable as empty")
        try HookInstaller.uninstallFromDisk(path: path)
        try check(!FileManager.default.fileExists(atPath: path), "uninstall missing creates no file")
        let initial = try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted])
        try initial.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        try HookInstaller.installToDisk(command: cmd, path: path, events: ["Stop"])
        let after = try Data(contentsOf: url)
        try check(HookInstaller.isInstalledOnDisk(path: path, events: ["Stop"]), "disk installation")
        try check(try HookFileTransaction.read(path).mode == 0o640, "mode retained")
        let backups = root.appendingPathComponent(".agentpet-backups")
        let first = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first!
        try check(try Data(contentsOf: first.appendingPathComponent("before")) == initial, "backup has exact original bytes")
        try HookInstaller.installToDisk(command: cmd, path: path, events: ["Stop"])
        try check(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).count == 1, "no-op produces no backup")
        try check(try Data(contentsOf: url) == after, "no-op preserves bytes")
        try Data("{\"user_edit\":true}".utf8).write(to: url)
        try rejects("rollback over third-party edit") { try HookInstaller.rollbackSettings(backup: first.path) }
        try check(try String(contentsOf: url, encoding: .utf8) == "{\"user_edit\":true}", "conflicting rollback preserves edit")
        try after.write(to: url)
        try HookInstaller.rollbackSettings(backup: first.path)
        try check(try Data(contentsOf: url) == initial, "rollback restores exact bytes")
        let captured = try HookFileTransaction.read(path)
        try Data("external-edit".utf8).write(to: url)
        try rejects("stale snapshot") { try HookFileTransaction.commit(path: path, before: captured, after: after) }
        try check(try String(contentsOf: url, encoding: .utf8) == "external-edit", "stale write preserves editor bytes")
        for raw in ["not-json", "[]", "{\"hooks\":7}", "{\"hooks\":{\"Stop\":7}}", "{\"hooks\":{\"Stop\":[{\"hooks\":7}]}}"] {
            let data = Data(raw.utf8); try data.write(to: url)
            try rejects("bad settings install") { try HookInstaller.installToDisk(command: cmd, path: path, events: ["Stop"]) }
            try rejects("bad settings uninstall") { try HookInstaller.uninstallFromDisk(path: path, events: ["Stop"]) }
            try check(try Data(contentsOf: url) == data, "bad settings unchanged")
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: root.appendingPathComponent("missing").path)
        try rejects("dangling symlink") { try HookInstaller.installToDisk(command: cmd, path: path) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try rejects("directory settings") { try HookInstaller.installToDisk(command: cmd, path: path) }
        try FileManager.default.removeItem(at: url)
        try initial.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        try rejects("unreadable file") { try HookInstaller.installToDisk(command: cmd, path: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try check(try Data(contentsOf: url) == initial, "unreadable file preserved")
        let hardlink = root.appendingPathComponent("hardlink.json")
        try FileManager.default.linkItem(at: url, to: hardlink)
        try rejects("hardlink settings") { try HookInstaller.installToDisk(command: cmd, path: path) }
        try FileManager.default.removeItem(at: hardlink)
        let absent = root.appendingPathComponent("new.json").path
        let creationBackup = try HookFileTransaction.update(path: absent) { _ in Data("{}".utf8) }!
        try HookInstaller.rollbackSettings(backup: creationBackup)
        try check(!FileManager.default.fileExists(atPath: absent), "rollback of creation removes only unchanged new file")
        let eraseBackup = try HookFileTransaction.update(path: path) { _ in nil }!
        try HookInstaller.rollbackSettings(backup: eraseBackup)
        try check(try Data(contentsOf: url) == initial, "rollback of deletion restores original")
        let isolated = root.appendingPathComponent("unsafe-backup")
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: isolated.appendingPathComponent(".agentpet-backups"), withDestinationURL: backups)
        try rejects("linked backup root") { try HookInstaller.installToDisk(command: cmd, path: isolated.appendingPathComponent("settings.json").path) }
        let corruptBackup = try HookFileTransaction.update(path: path) { _ in Data("{}".utf8) }!
        try Data("tamper".utf8).write(to: URL(fileURLWithPath: corruptBackup).appendingPathComponent("before"))
        try rejects("backup checksum mismatch") { try HookInstaller.rollbackSettings(backup: corruptBackup) }
        try check(try Data(contentsOf: url) == Data("{}".utf8), "corrupt backup does not alter target")
        for style: HookStyle in [.claudeNested, .antigravityNested, .opencodePlugin, .piExtension] {
            let file = root.appendingPathComponent(UUID().uuidString).path
            try HookInstaller.installToDisk(command: cmd, path: file, events: ["Stop"], style: style)
            try check(HookInstaller.isInstalledOnDisk(path: file, events: ["Stop"], style: style), "style round trip installed")
            try HookInstaller.uninstallFromDisk(path: file, events: ["Stop"], style: style)
            try check(!HookInstaller.isInstalledOnDisk(path: file, events: ["Stop"], style: style), "style round trip removed")
        }
        for style: HookStyle in [.cursorFlat, .windsurfFlat, .kiroFlat, .jcodeToml] {
            let file = root.appendingPathComponent(UUID().uuidString).path
            try rejects("retired installation style") { try HookInstaller.installToDisk(command: cmd, path: file, style: style) }
            try check(!FileManager.default.fileExists(atPath: file), "retired install creates no config")
        }
        let custom = root.appendingPathComponent("custom.ts")
        try Data((pi + "\n// custom").utf8).write(to: custom)
        try rejects("foreign Pi install") { try HookInstaller.installToDisk(command: cmd, path: custom.path, style: .piExtension) }
        try rejects("foreign Pi uninstall") { try HookInstaller.uninstallFromDisk(path: custom.path, style: .piExtension) }
        try check(try String(contentsOf: custom, encoding: .utf8) == pi + "\n// custom", "foreign Pi unchanged")
        print("PASS: \(count) Hook ownership and file transaction checks")
        return count
    }
}
