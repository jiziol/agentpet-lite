import XCTest
@testable import agentpet
@testable import AgentPetCore

@MainActor
final class SettingsIntegrationTests: XCTestCase {
    func testSettingsActionsUseDiskStateAndSurfaceFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agentpet")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let setup = AgentIntegrationSetup(home: root.path, environment: [:], binary: binary.path,
                                         detectOpencode: { try OpencodeVersion(output: "1.19.0", executable: "/fixture/opencode") })
        let model = SettingsModel(integrationSetup: setup)
        model.refresh()
        for kind: AgentKind in [.codex, .antigravity, .opencode, .pi] {
            XCTAssertFalse(model.isInstalled(kind))
            model.configureIntegration(kind)
            XCTAssertNil(model.installError)
            XCTAssertTrue(model.isInstalled(kind))
            XCTAssertEqual(model.integrationStates[kind]?.configuration, .configured)
            XCTAssertNotNil(model.integrationNotice)
            // External removal between refresh and click: explicit install
            // must re-read disk instead of toggling a stale UI boolean.
            try setup.remove(kind)
            model.configureIntegration(kind)
            XCTAssertNil(model.installError)
            XCTAssertEqual(try setup.inspect(kind).configuration, .configured)
            model.configureIntegration(kind, remove: true)
            XCTAssertNil(model.installError)
            XCTAssertFalse(model.isInstalled(kind))
        }
        let codex = setup.spec(for: .codex)!.settingsPath
        try Data("invalid JSON".utf8).write(to: URL(fileURLWithPath: codex))
        model.refresh()
        XCTAssertNotNil(model.integrationConflicts[.codex])
        XCTAssertEqual(model.integrationStates[.codex]?.configuration, .absent)
        XCTAssertFalse(model.canConfigure(.codex))
        model.configureIntegration(.codex)
        XCTAssertNotNil(model.installError)
        XCTAssertEqual(try String(contentsOfFile: codex, encoding: .utf8), "invalid JSON")
    }
}

@MainActor
final class IntegrationConnectionModelTests: XCTestCase {
    private func setup(_ root: URL, binary: URL) -> AgentIntegrationSetup {
        .init(home: root.path, environment: [:], binary: binary.path,
              detectOpencode: { try OpencodeVersion(output: "2.1.3", executable: "/fixture/opencode") })
    }

    func testOldRegistrationRemainsConfiguredAndReadErrorBlocksMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ap-map-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agentpet")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let service = setup(root, binary: binary)
        try service.install(.codex)
        let old = AgentIntegrationSetup(home: root.path, environment: [:], binary: root.appendingPathComponent("AgentPet.app/agentpet").path)
        let model = SettingsModel(integrationSetup: old)
        model.refresh()
        XCTAssertEqual(model.integrationStates[.codex]?.configuration, .needsUpdate)
        XCTAssertEqual(model.configurationLabel(.codex), "已配置")
        XCTAssertTrue(model.canConfigure(.codex))
        let path = service.spec(for: .codex)!.settingsPath
        try Data("broken".utf8).write(to: URL(fileURLWithPath: path))
        model.refresh()
        XCTAssertEqual(model.configurationLabel(.codex), "已配置", "Read failure retains last known state, not an absent conclusion")
        XCTAssertFalse(model.canConfigure(.codex))
        XCTAssertNotNil(model.integrationConflicts[.codex])
    }

    func testDuplicateTestCancellationAndPerCardResultsDoNotChangeConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ap-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agentpet")
        try Data("#!/bin/sh\n/bin/sleep 60\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let service = setup(root, binary: binary)
        let model = SettingsModel(integrationSetup: service)
        model.refresh()
        XCTAssertEqual(model.configurationLabel(.codex), "未配置")
        let connection = LocalAgentConnectionTest(executableOverrides: [.codex: binary.path], timeout: 5)
        model.startConnectionTest(.codex, service: connection)
        let id = model.connectionTests[.codex]?.id
        model.startConnectionTest(.codex, service: connection)
        XCTAssertEqual(model.connectionTests[.codex]?.id, id)
        XCTAssertTrue(model.isTesting(.codex))
        XCTAssertFalse(model.canConfigure(.codex))
        model.configureIntegration(.codex)
        XCTAssertEqual(try service.inspect(.codex).configuration, .absent)
        model.startConnectionTest(.antigravity, service: connection)
        model.cancelConnectionTest(.codex)
        for _ in 0..<100 {
            if !model.isTesting(.codex) && !model.isTesting(.antigravity) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.connectionTests[.codex]?.result?.status, .cancelled)
        XCTAssertEqual(model.connectionTests[.antigravity]?.result?.status, .unsupported)
        XCTAssertEqual(model.configurationLabel(.codex), "未配置")
        XCTAssertEqual(try service.inspect(.codex).configuration, .absent)
        XCTAssertEqual(model.connectionTests[.codex]?.id, id)
    }
}
