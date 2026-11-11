import XCTest
@testable import AgentPetCore

final class OpencodeVersionTests: XCTestCase {
    func testTUINavigationVersionGateAndDirectoryMigrationPreserveOlderObservers() throws {
        for value in ["2.0.29", "2.1.9", "2.2.1", "2.2.2-beta.1"] {
            XCTAssertFalse(try OpencodeVersion(output: value, executable: "").supportsTUINavigation)
        }
        for value in ["2.2.2", "2.2.3", "2.3.0"] {
            XCTAssertTrue(try OpencodeVersion(output: value, executable: "").supportsTUINavigation)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agentpet")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        var version = "2.0.29"
        let setup = AgentIntegrationSetup(home: root.path, environment: [:], binary: binary.path,
            speechSocket: root.path + "/speech.sock", detectOpencode: { try .init(output: version, executable: "") })
        let legacy = setup.spec(for: .opencode)!.settingsPath
        let directory = root.appendingPathComponent(".config/opencode/plugins/agentpet-lite")
        try setup.install(.opencode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy))
        version = "2.2.2"
        XCTAssertEqual(try setup.inspect(.opencode).configuration, .needsUpdate)
        try setup.install(.opencode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("package.json"), encoding: .utf8), OpencodeTUIPlugin.manifest)
        XCTAssertTrue(try OpencodeTUIPlugin.isOwned(String(contentsOf: directory.appendingPathComponent("tui.js"), encoding: .utf8)))
        XCTAssertEqual(try setup.inspect(.opencode).configuration, .configured)
        let foreign = directory.appendingPathComponent("foreign.js")
        try "// user".write(to: foreign, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try setup.install(.opencode)); XCTAssertThrowsError(try setup.remove(.opencode))
        try FileManager.default.removeItem(at: foreign)
        version = "2.1.0"
        try setup.install(.opencode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tui.js").path))
        version = "2.2.2"; try setup.install(.opencode)
        version = "3.0.0" // Native version detection may block Install, never owned Remove.
        try setup.remove(.opencode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.js").path))
        XCTAssertEqual(try setup.inspect(.opencode).configuration, .absent)
    }

    func testNavigationPackageRejectsSymlinkAndCustomizedOwnedFilesWithoutPartialMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agentpet")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        var version = "2.0.29"
        let setup = AgentIntegrationSetup(home: root.path, environment: [:], binary: binary.path,
            detectOpencode: { try .init(output: version, executable: "") })
        try setup.install(.opencode)
        let legacy = setup.spec(for: .opencode)!.settingsPath
        let original = try Data(contentsOf: URL(fileURLWithPath: legacy))
        let plugins = root.appendingPathComponent(".config/opencode/plugins")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: plugins, withDestinationURL: outside)
        version = "2.2.2"
        XCTAssertThrowsError(try setup.install(.opencode))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: legacy)), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: plugins)
        try setup.install(.opencode)
        let tui = plugins.appendingPathComponent("agentpet-lite/tui.js")
        let custom = try String(contentsOf: tui, encoding: .utf8) + "\n// local changes"
        try custom.write(to: tui, atomically: true, encoding: .utf8)
        version = "2.0.29"
        XCTAssertThrowsError(try setup.install(.opencode))
        XCTAssertThrowsError(try setup.remove(.opencode))
        XCTAssertEqual(try String(contentsOf: tui, encoding: .utf8), custom)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy))
    }

    func testParsesBothNativeVersionFormatsAndRejectsUnsupportedGenerations() throws {
        XCTAssertEqual(try OpencodeVersion(output: "1.19.0\n", executable: "/test/opencode").generation, .v1)
        XCTAssertEqual(try OpencodeVersion(output: "opencode v2.0.29\n", executable: "/test/opencode").generation, .v2)
        for output in ["1.18.33", "2.0.28", "3.0.0", "garbage", "2.0.29\nmalformed"] {
            XCTAssertThrowsError(try OpencodeVersion(output: output, executable: "/test/opencode"))
        }
    }

    func testDetectionExecutesFirstCLIWithoutShellExpansion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oc version '$` " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("opencode")
        try "#!/bin/sh\n[ \"$1\" = --version ] || exit 42\nprintf 'opencode v2.0.29\\n'\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let version = try OpencodeVersion.detect(home: root.path, environment: ["PATH": root.path + ":/bin"])
        XCTAssertEqual(version.version, "2.0.29")
        XCTAssertEqual(version.executable, cli.path)
        try "#!/bin/sh\nexit 9\n".write(to: cli, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OpencodeVersion.detect(home: root.path, environment: ["PATH": root.path]))
    }

    func testSwitchingGenerationUpdatesOnlyOwnedPluginAndRemoveNeedsNoCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oc versions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var output: String? = "1.19.0"
        let binary = root.appendingPathComponent("agentpet")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let setup = AgentIntegrationSetup(home: root.path, environment: [:], binary: binary.path, speechSocket: root.path + "/test.sock", detectOpencode: {
            guard let output else { throw IntegrationSetupError.manualReview("CLI unavailable") }
            return try OpencodeVersion(output: output, executable: "/test/opencode")
        })
        let path = setup.spec(for: .opencode)!.settingsPath
        try setup.install(.opencode)
        let v1 = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(v1.contains("export const AgentPet"))
        output = "opencode v2.0.29"
        let state = try setup.inspect(.opencode)
        XCTAssertEqual(state.configuration, .needsUpdate)
        XCTAssertTrue(state.clientNotice?.contains("2.0.29") == true)
        XCTAssertTrue(state.clientNotice?.contains("API 不兼容") == true)
        let duplicate = path.replacingOccurrences(of: "/plugin/", with: "/plugins/")
        try FileManager.default.createDirectory(atPath: (duplicate as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try v1.write(toFile: duplicate, atomically: true, encoding: .utf8)
        let foreign = (path as NSString).deletingLastPathComponent + "/other.js"
        try "// foreign".write(toFile: foreign, atomically: true, encoding: .utf8)
        try setup.install(.opencode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate))
        let v2 = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(v2.contains("id: \"agentpet-lite.observer.v2\""))
        XCTAssertTrue(OpencodePlugin.isOwned(v1)); XCTAssertTrue(OpencodePlugin.isOwned(v2))
        XCTAssertFalse(OpencodePlugin.isOwned(v2 + "\n// custom change"))
        XCTAssertEqual(try setup.inspect(.opencode).configuration, .configured)
        output = "3.0.0"
        XCTAssertNotNil(try setup.inspect(.opencode).installBlockReason)
        XCTAssertThrowsError(try setup.install(.opencode))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), v2)
        output = nil
        XCTAssertNotNil(try setup.inspect(.opencode).installBlockReason)
        try setup.remove(.opencode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try String(contentsOfFile: foreign, encoding: .utf8), "// foreign")
    }

    func testUnknownNativeInterruptionNeverBecomesACompletedTurn() throws {
        let store = SessionStore(), now = Date()
        func event(_ name: String, _ offset: Double, _ values: [String: Any]) throws -> AgentEvent {
            let frame = ["version": 1, "session_id": "ses_v2Unknown", "event": name, "turn_id": "msg_v2Unknown", "timestamp": now.addingTimeInterval(offset).timeIntervalSince1970] as [String: Any]
            return try XCTUnwrap(OpencodeHookPayload.event(from: JSONSerialization.data(withJSONObject: frame.merging(values) { _, new in new }), now: now))
        }
        let start = try event("working", 0, ["new_turn": true])
        store.apply(start, now: start.timestamp)
        let end = try event("done", 1, ["result": "unknown"])
        store.apply(end, now: end.timestamp)
        let row = try XCTUnwrap(store.session(id: start.sessionId))
        XCTAssertNil(row.taskResult)
        XCTAssertNotNil(row.opencodeDisconnectedAt)
        XCTAssertEqual(row.message, "会话连接已中断，任务结果未知")
    }
}
