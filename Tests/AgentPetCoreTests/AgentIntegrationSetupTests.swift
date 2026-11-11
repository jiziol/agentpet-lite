import XCTest
@testable import AgentPetCore

final class AgentIntegrationSetupTests: XCTestCase {
    private func sandbox(_ body: (AgentIntegrationSetup, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("Pet's $safe `literal` app/agentpet")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\ncat > \"$CAPTURE\"\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let setup = AgentIntegrationSetup(home: root.path, environment: [:], binary: binary.path, speechSocket: root.appendingPathComponent("test.sock").path,
                                         detectOpencode: { try OpencodeVersion(output: "1.19.0", executable: "/fixture/opencode") })
        try body(setup, root)
    }
    private func write(_ value: Any, path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    func testFreshInstallRepeatedUpdateAndCompleteRemove() throws {
        try sandbox { setup, _ in
            for kind: AgentKind in [.codex, .antigravity, .opencode, .pi] {
                let path = setup.spec(for: kind)!.settingsPath
                XCTAssertEqual(try setup.inspect(kind).configuration, .absent)
                try setup.install(kind)
                XCTAssertEqual(try setup.inspect(kind).configuration, .configured)
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                try setup.install(kind)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
                try setup.remove(kind)
                XCTAssertEqual(try setup.inspect(kind).configuration, .absent)
                try setup.remove(kind)
                if kind == .opencode || kind == .pi { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
                else { XCTAssertTrue(try HookInstaller.readSettings(path: path).isEmpty) }
            }
        }
    }

    func testPiPreviousTemplateUpdateAndRemovePreserveUserFiles() throws {
        try sandbox { setup, root in
            let path = setup.spec(for: .pi)!.settingsPath
            let foreign = root.appendingPathComponent(".pi/agent/extensions/user.ts")
            let auth = root.appendingPathComponent(".pi/agent/auth.json")
            try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture credential".utf8).write(to: auth)
            try Data("// user's extension".utf8).write(to: foreign)
            for old in [PiPlugin.previousSource(binary: "/old/agentpet"), PiPlugin.legacySource(binary: "/old/agentpet")] {
                try old.write(toFile: path, atomically: true, encoding: .utf8)
                XCTAssertEqual(try setup.inspect(.pi).configuration, .needsUpdate)
                try setup.install(.pi)
                XCTAssertEqual(try setup.inspect(.pi).configuration, .configured)
                try setup.remove(.pi)
                XCTAssertEqual(try setup.inspect(.pi).configuration, .absent)
                XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            }
            let modified = PiPlugin.previousSource(binary: "/old/agentpet") + "\n// customization"
            try modified.write(toFile: path, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try setup.install(.pi))
            XCTAssertThrowsError(try setup.remove(.pi))
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), modified)
            XCTAssertEqual(try String(contentsOf: auth, encoding: .utf8), "fixture credential")
            XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "// user's extension")
        }
    }

    func testLiteralShellCommandReachesCorrectExecutable() throws {
        try sandbox { setup, root in
            let capture = root.appendingPathComponent("capture.json")
            let command = AgentIntegrationSetup.command(binary: setup.binary, kind: .codex)
            XCTAssertEqual(HookCommandOwnership.words(command), [setup.binary, "hook", "--agent", "codex"])
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh"); task.arguments = ["-c", command]
            task.environment = ["CAPTURE": capture.path, "PATH": "/bin:/usr/bin"]
            let input = Pipe(); task.standardInput = input
            try task.run(); try input.fileHandleForWriting.write(contentsOf: Data("{}".utf8)); try input.fileHandleForWriting.close()
            task.waitUntilExit()
            XCTAssertEqual(task.terminationStatus, 0)
            XCTAssertEqual(try String(contentsOf: capture, encoding: .utf8), "{}")
        }
    }

    func testPartialAndStaleCommandsRepairedAndLegacyEventsRemoved() throws {
        try sandbox { setup, _ in
            let path = setup.spec(for: .codex)!.settingsPath
            let foreign: [String: Any] = ["type": "command", "command": "echo foreign", "timeout": 17]
            let old: [String: Any] = ["type": "command", "command": "'/old/agentpet' hook --agent codex"]
            try write(["custom": ["theme": "dark"], "hooks": ["SessionStart": [["matcher": "*", "hooks": [foreign, old]]], "LegacyEvent": [["hooks": [old]]]]], path: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
            XCTAssertEqual(try setup.inspect(.codex).configuration, .needsUpdate)
            try setup.install(.codex)
            XCTAssertEqual(try setup.inspect(.codex).configuration, .configured)
            let installed = try HookInstaller.readSettings(path: path)
            XCTAssertNil((installed["hooks"] as? [String: Any])?["LegacyEvent"])
            try setup.remove(.codex)
            let result = try HookInstaller.readSettings(path: path)
            XCTAssertEqual((result["custom"] as? [String: String])?["theme"], "dark")
            let hooks = result["hooks"] as! [String: Any]
            XCTAssertEqual(hooks.count, 1)
            XCTAssertTrue(NSDictionary(dictionary: (hooks["SessionStart"] as! [[String: Any]])[0]).isEqual(to: ["matcher": "*", "hooks": [foreign]]))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        }
    }

    func testAgyAllGroupsLegacyPermissionGateAndForeignHandlers() throws {
        try sandbox { setup, _ in
            let path = setup.spec(for: .antigravity)!.settingsPath
            let own = ["type": "command", "command": "'/old/agentpet' hook --agent antigravity"]
            let foreign = ["type": "command", "command": "echo keep"]
            try write(["other": ["enabled": true, "PreToolUse": [["matcher": "*", "hooks": [own, foreign]]], "UnknownEvent": [own]], "agentpet": ["Stop": [own]]], path: path)
            try setup.install(.antigravity)
            let configured = try HookInstaller.readSettings(path: path)
            XCTAssertNil((configured["agentpet"] as? [String: Any])?["PreToolUse"])
            try setup.remove(.antigravity)
            let result = try HookInstaller.readSettings(path: path)
            XCTAssertNil(result["agentpet"])
            let group = result["other"] as! [String: Any]
            XCTAssertNil(group["UnknownEvent"])
            XCTAssertEqual(group["enabled"] as? Bool, true)
            let handlers = ((group["PreToolUse"] as! [[String: Any]])[0]["hooks"] as! [[String: String]])
            XCTAssertEqual(handlers, [foreign])
        }
    }

    func testPluginDuplicatesConsolidatedThenRemovedAndCustomPluginRefused() throws {
        try sandbox { setup, _ in
            let path = setup.spec(for: .opencode)!.settingsPath
            let duplicate = path.replacingOccurrences(of: "/plugin/", with: "/plugins/").replacingOccurrences(of: ".js", with: ".ts")
            let legacy = OpencodePlugin.source(binary: "/old/agentpet", speechSocketPath: "/old/socket")
            try FileManager.default.createDirectory(atPath: (duplicate as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try legacy.write(toFile: duplicate, atomically: true, encoding: .utf8)
            XCTAssertEqual(try setup.inspect(.opencode).configuration, .needsUpdate)
            try setup.install(.opencode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate))
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), OpencodePlugin.source(binary: setup.binary, speechSocketPath: setup.speechSocket))
            try setup.remove(.opencode)
            let custom = legacy + "\nconsole.log('my customization')"
            try custom.write(toFile: duplicate, atomically: true, encoding: .utf8)
            XCTAssertFalse(OpencodePlugin.isOwned(custom))
            XCTAssertThrowsError(try setup.inspect(.opencode))
            XCTAssertThrowsError(try setup.install(.opencode))
            XCTAssertThrowsError(try setup.remove(.opencode))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            XCTAssertEqual(try String(contentsOfFile: duplicate, encoding: .utf8), custom)
        }
    }

    func testMalformedSymlinkAndUnsupportedStructuresRefuseWithoutChanges() throws {
        try sandbox { setup, root in
            let path = setup.spec(for: .codex)!.settingsPath
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("{invalid".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try setup.inspect(.codex)); XCTAssertThrowsError(try setup.remove(.codex))
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{invalid")
            try FileManager.default.removeItem(atPath: path)
            let target = root.appendingPathComponent("foreign.json"); try Data("{}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
            XCTAssertThrowsError(try setup.install(.codex)); XCTAssertThrowsError(try setup.remove(.codex))
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "{}")
            try FileManager.default.removeItem(atPath: path)
            try write(["hooks": ["SessionStart": ["command": "'/old/agentpet' hook --agent codex"]]], path: path)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try setup.inspect(.codex)); XCTAssertThrowsError(try setup.install(.codex)); XCTAssertThrowsError(try setup.remove(.codex))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        }
    }

    func testCodexFeatureAndInlineSourcesArePreserved() throws {
        try sandbox { setup, _ in
            let config = (setup.spec(for: .codex)!.settingsPath as NSString).deletingLastPathComponent + "/config.toml"
            try FileManager.default.createDirectory(atPath: (config as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let disabled = "[features]\nhooks = false # user choice\n"
            try disabled.write(toFile: config, atomically: true, encoding: .utf8)
            XCTAssertNotNil(try setup.inspect(.codex).clientNotice)
            XCTAssertThrowsError(try setup.install(.codex))
            XCTAssertEqual(try String(contentsOfFile: config, encoding: .utf8), disabled)
            let enabled = "[features]\nhooks = true\n"
            try enabled.write(toFile: config, atomically: true, encoding: .utf8)
            try setup.install(.codex); try setup.remove(.codex)
            XCTAssertEqual(try String(contentsOfFile: config, encoding: .utf8), enabled)
            let inline = enabled + "\n[[hooks.Stop]]\ncommand = \"/old/agentpet hook\"\n"
            try inline.write(toFile: config, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try setup.install(.codex)); XCTAssertThrowsError(try setup.remove(.codex))
            XCTAssertEqual(try String(contentsOfFile: config, encoding: .utf8), inline)
        }
    }

    func testProjectTrustEntryDoesNotCountAsCodexHook() throws {
        try sandbox { setup, root in
            let config = root.appendingPathComponent(".codex/config.toml")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = "[features]\nhooks = true\n[projects.\"\(root.path)/agentpet-lite\"]\ntrust_level = \"trusted\"\n"
            // The old whole-file substring check confused this normal trust
            // entry with a second hook registration and blocked even Remove.
            try text.write(to: config, atomically: true, encoding: .utf8)
            XCTAssertEqual(try setup.inspect(.codex).configuration, .absent)
            try setup.install(.codex)
            XCTAssertEqual(try setup.inspect(.codex).configuration, .configured)
            try setup.remove(.codex)
            XCTAssertEqual(try setup.inspect(.codex).configuration, .absent)
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text)
        }
    }

    func testCodexExtraHookReferencesStillBlockWithoutMutatingSources() throws {
        try sandbox { setup, root in
            try setup.install(.codex)
            let hookURL = URL(fileURLWithPath: setup.spec(for: .codex)!.settingsPath)
            let before = try Data(contentsOf: hookURL)
            let config = root.appendingPathComponent(".codex/config.toml")
            let sources = [
                "[[hooks.Stop]]\ncommand = \"/old/agentpet hook\"\n",
                "[[\"hooks\".\"Stop\".\"hooks\"]]\ncommand = '/old/AgentPet hook'\n",
                "hooks.Stop = [{ command = '/old/agentpet hook' }]\n",
                "hooks = { Stop = [{ hooks = [{ command = '/old/agentpet hook' }] }] }\n",
                "[profiles.work.hooks.Stop]\ncommand = '/old/agentpet hook'\n",
                "notify = [\n '/old/agentpet', # keep this legacy registration\n 'hook'\n]\n",
                #"hooks.Stop.command = "/old/\u0061gentpet hook""# + "\n",
                "[[hooks.Stop]]\ncommand = '/old/agentpet#local hook'\n"
            ]
            for text in sources {
                try text.write(to: config, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try setup.inspect(.codex), text)
                XCTAssertThrowsError(try setup.install(.codex), text)
                XCTAssertThrowsError(try setup.remove(.codex), text)
                XCTAssertEqual(try Data(contentsOf: hookURL), before)
                XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text)
            }
        }
    }

    func testCodexCommentsAndDescriptionsAreNotHookRegistrations() throws {
        try sandbox { setup, root in
            let config = root.appendingPathComponent(".codex/config.toml")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = #"""
            developer_instructions = """
            Example only:
            [[hooks.Stop]]
            command = '/old/agentpet hook'
            """
            # hooks.Stop.command = '/old/agentpet hook'
            [features]
            hooks = true # agentpet is a project, not a registration
            [[hooks.Stop]]
            command = 'echo keep' # agentpet is not called
            [projects."/work/agentpet-hooks"]
            trust_level = "trusted"
            description = "agentpet # hook"
            """# + "\n"
            for contents in [text, text.replacingOccurrences(of: "\n", with: "\r\n")] {
                try contents.write(to: config, atomically: true, encoding: .utf8)
                try setup.install(.codex)
                XCTAssertEqual(try setup.inspect(.codex).configuration, .configured)
                try setup.remove(.codex)
                XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), contents)
            }
        }
    }

    func testEnvironmentOverridesMatchNativeLocations() throws {
        try sandbox { setup, root in
            let custom = AgentIntegrationSetup(home: setup.home, environment: ["CODEX_HOME": root.path + "/codex-custom", "XDG_CONFIG_HOME": root.path + "/xdg"], binary: setup.binary)
            XCTAssertEqual(custom.spec(for: .codex)?.settingsPath, root.path + "/codex-custom/hooks.json")
            XCTAssertEqual(custom.spec(for: .opencode)?.settingsPath, root.path + "/xdg/opencode/plugin/agentpet.js")
            try custom.install(.codex)
            XCTAssertFalse(FileManager.default.fileExists(atPath: setup.spec(for: .codex)!.settingsPath))
            try custom.remove(.codex)
        }
    }

    func testMultiFileFailureRollsBackEarlierPluginChange() throws {
        try sandbox { setup, _ in
            let path = setup.spec(for: .opencode)!.settingsPath
            let duplicate = path.replacingOccurrences(of: "/plugin/", with: "/plugins/")
            let original = OpencodePlugin.source(binary: "/old/agentpet", speechSocketPath: "/old/socket")
            for file in [path, duplicate] {
                try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try original.write(toFile: file, atomically: true, encoding: .utf8)
            }
            // Read preflight succeeds; the second commit cannot create a safe
            // backup, after the first commit has already updated the primary.
            let blockedBackup = (duplicate as NSString).deletingLastPathComponent + "/.agentpet-backups"
            try Data("foreign file".utf8).write(to: URL(fileURLWithPath: blockedBackup))
            XCTAssertThrowsError(try setup.install(.opencode))
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
            XCTAssertEqual(try String(contentsOfFile: duplicate, encoding: .utf8), original)
            XCTAssertEqual(try String(contentsOfFile: blockedBackup, encoding: .utf8), "foreign file")
        }
    }

    func testExplicitOpenCodePluginReferenceIsNotSilentlyLeftDangling() throws {
        try sandbox { setup, _ in
            try setup.install(.opencode)
            let path = setup.spec(for: .opencode)!.settingsPath
            let root = ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            try write(["plugin": ["./plugin/agentpet.js"]], path: root + "/opencode.json")
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try setup.inspect(.opencode))
            XCTAssertThrowsError(try setup.remove(.opencode))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
            let custom = AgentIntegrationSetup(home: setup.home, environment: ["OPENCODE_CONFIG_DIR": root + "/custom"], binary: setup.binary)
            XCTAssertThrowsError(try custom.install(.opencode))
        }
    }
}
