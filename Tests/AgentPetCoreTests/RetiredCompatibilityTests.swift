import XCTest
@testable import AgentPetCore

final class RetiredCompatibilityTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 100)
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retired-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testAllLegacyIdentifiersRemainDecodableButCannotCreateSessions() throws {
        for kind in RetiredAgentRegistry.kinds {
            let event = AgentEvent(sessionId: "s", agentKind: kind, eventName: "working", timestamp: at)
            XCTAssertEqual(try EventCoding.decoder.decode(AgentEvent.self, from: EventCoding.encoder.encode(event)), event)
            XCTAssertNil(AgentHooks.spec(for: kind))
            XCTAssertNil(SessionStore().apply(event, now: at))
            XCTAssertNil(HookPayload.event(forAgent: kind, stdin: Data(#"{"session_id":"s","hook_event_name":"Stop"}"#.utf8), now: at))
            var unknown = event; unknown.agentKind = .unknown; unknown.agentName = kind.rawValue.uppercased()
            XCTAssertNil(SessionStore().apply(unknown, now: at))
        }
        let store = SessionStore()
        XCTAssertNotNil(store.apply(AgentEvent(sessionId: "custom", agentKind: .unknown, eventName: "working", agentName: "hermes", timestamp: at), now: at))
    }
    func testMixedV1SnapshotHidesAndPreservesLegacyRecordsOnSave() throws {
        let file = try root().appendingPathComponent("codex-sessions-v1.json")
        let retired = RetiredAgentRegistry.kinds.map { AgentSession(id: $0.rawValue, agentKind: $0, state: .done, source: .hook, updatedAt: at) }
        let active = AgentSession(id: "codex", agentKind: .codex, state: .done, source: .hook, updatedAt: at)
        struct Snapshot: Codable { let version: Int; let sessions: [AgentSession] }
        try JSONEncoder().encode(Snapshot(version: 1, sessions: retired + [active])).write(to: file)
        let store = SessionStore(); store.persistenceURL = file; store.restoreCodexSessions()
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.sessions.map(\.id), ["codex"])
        store.persistCodexSessions()
        let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(saved.sessions.filter { RetiredAgentRegistry.ignores($0.agentKind) }.sorted { $0.id < $1.id }, retired.sorted { $0.id < $1.id })
        XCTAssertEqual(saved.sessions.first { $0.id == "codex" }, active)
    }
    func testLegacyHistoryRemainsReadableAndRetiredInstallsAreRejected() throws {
        for kind in RetiredAgentRegistry.kinds {
            let record = SessionArchive(sessionId: kind.rawValue, agentKind: kind, project: nil, title: nil,
                message: nil, tokenCount: nil, startedAt: at, endedAt: at, duration: 0)
            let decoded = try JSONDecoder().decode(SessionArchive.self, from: JSONEncoder().encode(record))
            XCTAssertEqual(decoded.agentKind, kind)
            let path = try root().appendingPathComponent("new-config").path
            XCTAssertThrowsError(try HookInstaller.installToDisk(command: "agentpet hook --agent " + kind.rawValue, path: path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }
    func testMigrationAllShapesBackupRollbackAndForeignFields() throws {
        let home = try root()
        let command = "\"/Applications/AgentPet Local.app/Contents/MacOS/agentpet\" hook"
        var before: [AgentKind: Data] = [:]
        for kind in RetiredAgentRegistry.kinds {
            let spec = RetiredAgentRegistry.migrationSpec(for: kind, home: home.path)!
            let data: Data
            if spec.style == .jcodeToml {
                data = Data("# preserved\n[hooks]\nturn_end = '\(command) --agent jcode'\npre_tool = 'third-party'\n[trust]\napproved = true\n".utf8)
            } else {
                let handler: [String: Any] = ["type": "command", "command": command + " --agent " + kind.rawValue]
                let foreign: [String: Any] = ["type": "command", "command": "third-party", "trust": "approved"]
                let entries: [[String: Any]] = spec.style == .claudeNested ? [["matcher": "Bash", "timeout": 9, "hooks": [foreign, handler, foreign]]] : [foreign, handler, foreign]
                data = try JSONSerialization.data(withJSONObject: ["hooks": [spec.events.first!: entries], "name": "user-agent", "trust": ["approved": true]], options: [.prettyPrinted])
            }
            let path = URL(fileURLWithPath: spec.settingsPath)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path); before[kind] = data
        }
        XCTAssertTrue(RetiredHookMigration.run(home: home.path).allSatisfy { $0.status == .wouldRemove })
        for kind in RetiredAgentRegistry.kinds { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: RetiredAgentRegistry.migrationSpec(for: kind, home: home.path)!.settingsPath)), before[kind]) }
        let reports = RetiredHookMigration.run(home: home.path, dryRun: false)
        XCTAssertEqual(reports.count, 8)
        for report in reports {
            XCTAssertEqual(report.status, .removed)
            let output = try Data(contentsOf: URL(fileURLWithPath: report.path))
            if report.kind == .jcode {
                XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("pre_tool = 'third-party'"))
            } else {
                let object = try JSONSerialization.jsonObject(with: output) as! [String: Any]
                XCTAssertEqual(object["name"] as? String, "user-agent")
                XCTAssertEqual((object["trust"] as? [String: Bool])?["approved"], true)
                let hooks = object["hooks"] as! [String: Any]
                let entries = hooks.values.first as! [[String: Any]]
                if RetiredAgentRegistry.migrationSpec(for: report.kind)!.style == .claudeNested {
                    XCTAssertEqual(entries.first?["matcher"] as? String, "Bash")
                    XCTAssertEqual(entries.first?["timeout"] as? Int, 9)
                    XCTAssertEqual((entries.first?["hooks"] as? [[String: Any]])?.count, 2)
                } else { XCTAssertEqual(entries.count, 2) }
            }
            try HookInstaller.rollbackSettings(backup: XCTUnwrap(report.backup))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: report.path)), before[report.kind])
        }
    }
    func testMigrationCannotOverwriteLaterEditsOrMalformedConfig() throws {
        let home = try root(), spec = RetiredAgentRegistry.migrationSpec(for: .gemini, home: try root().path)!
        let target = URL(fileURLWithPath: spec.settingsPath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(#"{"hooks":{"AfterAgent":[{"hooks":[{"command":"agentpet hook --agent gemini"}]}]},"trust":true}"#.utf8)
        try data.write(to: target)
        let actualHome = target.deletingLastPathComponent().deletingLastPathComponent().path
        let report = RetiredHookMigration.run(home: actualHome, dryRun: false).first { $0.kind == .gemini }!
        let edited = Data(#"{"userEdited":true}"#.utf8); try edited.write(to: target)
        XCTAssertThrowsError(try HookInstaller.rollbackSettings(backup: XCTUnwrap(report.backup)))
        XCTAssertEqual(try Data(contentsOf: target), edited)
        let broken = URL(fileURLWithPath: RetiredAgentRegistry.migrationSpec(for: .cursor, home: home.path)!.settingsPath)
        try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: broken)
        XCTAssertEqual(RetiredHookMigration.run(home: home.path, dryRun: false).first { $0.kind == .cursor }?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: broken), Data("broken".utf8))
    }
    func testMigrationPreservesExplicitMaintainedCommandsAndAgyNativePath() throws {
        let home = try root()
        let settings = home.appendingPathComponent(".gemini/settings.json")
        let agy = home.appendingPathComponent(".gemini/config/hooks.json")
        try FileManager.default.createDirectory(at: agy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let native = Data("agy-native-config-untouched".utf8); try native.write(to: agy)
        let data = Data(#"{"hooks":{"BeforeTool":[{"matcher":"Bash","hooks":[{"command":"agentpet hook --agent gemini"},{"command":"agentpet hook --agent antigravity"}]}]},"trust":true}"#.utf8)
        try data.write(to: settings)
        let report = try XCTUnwrap(RetiredHookMigration.run(home: home.path, dryRun: false).first { $0.kind == .gemini })
        XCTAssertEqual(report.status, .removed)
        let after = String(decoding: try Data(contentsOf: settings), as: UTF8.self)
        XCTAssertFalse(after.contains("--agent gemini"))
        XCTAssertTrue(after.contains("--agent antigravity"))
        XCTAssertEqual(try Data(contentsOf: agy), native)
        let toml = "[hooks]\nturn_end = 'agentpet hook --agent claude'\nturn_start = 'agentpet hook --agent jcode'\n"
        let clean = LegacyJcodeHookCodec.uninstall(in: toml, events: ["turn_end", "turn_start"], retiredKind: .jcode)
        XCTAssertTrue(clean.contains("--agent claude")); XCTAssertFalse(clean.contains("--agent jcode"))
    }

}
