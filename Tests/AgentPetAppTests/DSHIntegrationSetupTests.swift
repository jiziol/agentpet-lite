import Foundation
import XCTest
@testable import agentpet
@testable import AgentPetCore

final class DSHIntegrationSetupTests: XCTestCase {
    private final class Fixture: @unchecked Sendable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-independent-" + UUID().uuidString).resolvingSymlinksInPath()
        var app: URL { root.appendingPathComponent("DSH.app") }
        var home: URL { root.appendingPathComponent("home") }
        var profile: URL { home.appendingPathComponent("profiles/desktop") }
        var package: URL { profile.appendingPathComponent("node_modules/@agentpet-lite/dsh-bridge") }
        init() throws {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try info("99.0.0-rc.42")
            try json(["dependencies": [:], "dsh": ["profile": ["bundles": []]]], at: profile.appendingPathComponent("package.json"))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func info(_ version: String, identifier: String = "com.deepseek.dsh") throws {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
                "CFBundleExecutable": "DeepSeek Harness", "CFBundleShortVersionString": version], format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        func json(_ object: [String: Any], at path: URL) throws {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: path)
        }
        func register(_ version: String = "0.1.8") throws {
            try json(["dependencies": ["@agentpet-lite/dsh-bridge": version], "dsh": ["profile": ["bundles": ["@agentpet-lite/dsh-bridge"]]]], at: profile.appendingPathComponent("package.json"))
            try json(["name": "@agentpet-lite/dsh-bridge", "version": version, "main": "lib/index.js",
                "exports": ["./client": "./lib/client.js"], "dsh": ["bundle": ["patch": "./cordis.patch.yml"]]], at: package.appendingPathComponent("package.json"))
            for name in ["lib/index.js", "lib/client.js", "cordis.patch.yml"] {
                let file = package.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("independent release bytes".utf8).write(to: file)
            }
        }
        func setup(running: Bool = true) -> DSHIntegrationSetup {
            .init(target: .init(application: app, home: home), isRunning: { running })
        }
    }

    func testIndependentOlderAndNewerPackagesDoNotRequireBundledResourcesOrMatchingSDK() throws {
        let f = try Fixture()
        for version in ["0.1.6", "0.1.8", "9.4.3"] {
            try f.register(version)
            let before = try Data(contentsOf: f.package.appendingPathComponent("package.json"))
            XCTAssertEqual(try f.setup().inspect().configuration, .configured)
            XCTAssertEqual(before, try Data(contentsOf: f.package.appendingPathComponent("package.json")))
        }
        try Data("different valid release code".utf8).write(to: f.package.appendingPathComponent("lib/client.js"))
        XCTAssertEqual(try f.setup().inspect().configuration, .configured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.app.appendingPathComponent("Contents/Resources").path))
    }

    func testRegistrationIsDiagnosticAndReadOnlyWhileStructuralDamageIsReported() throws {
        let f = try Fixture()
        XCTAssertEqual(try f.setup().inspect().configuration, .absent)
        try f.register()
        let before = try Data(contentsOf: f.profile.appendingPathComponent("package.json"))
        try FileManager.default.removeItem(at: f.package.appendingPathComponent("lib/client.js"))
        XCTAssertEqual(try f.setup().inspect().configuration, .needsUpdate)
        XCTAssertEqual(before, try Data(contentsOf: f.profile.appendingPathComponent("package.json")))
        try f.info("1.0.0", identifier: "not.dsh")
        XCTAssertThrowsError(try f.setup().inspect())
    }

    func testExternalPackageAndEntryLinksAreRejectedWithoutChangingThem() throws {
        let f = try Fixture(); try f.register()
        let external = f.root.appendingPathComponent("external")
        try FileManager.default.moveItem(at: f.package, to: external)
        try FileManager.default.createSymbolicLink(at: f.package, withDestinationURL: external)
        XCTAssertThrowsError(try f.setup().inspect())
        try FileManager.default.removeItem(at: f.package)
        try FileManager.default.moveItem(at: external, to: f.package)
        let entry = f.package.appendingPathComponent("lib/client.js")
        try FileManager.default.removeItem(at: entry)
        try Data("keep".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: external)
        XCTAssertThrowsError(try f.setup().inspect())
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "keep")
    }

    private func probe(_ setup: DSHIntegrationSetup, version: String = "0.1.8", major: Int = 1,
                       clients: Int = 1, eventConnected: Bool = true, capabilities: [String]? = nil) -> DSHBridgeProtocol.Probe {
        let status = DSHBridgeProtocol.Status(schema: 1, requestID: UUID().uuidString,
            profileID: DSHLiveSignals.profileID(setup.target), hostID: UUID().uuidString,
            hostStartedAt: Date().timeIntervalSince1970 - 30, protocolMajor: major,
            capabilities: capabilities ?? ["lifecycle.v1", "navigation.v1", "pending.v1", "speech.v1"],
            packageVersion: version, clientCount: clients, eventConnected: eventConnected, eventSocket: AgentPetPaths.socketPath)
        return .init(status: status, socketPath: "/tmp/fixture-unused.sock", peerPID: getpid())
    }

    @MainActor
    func testHealthyBridgeWithoutRegisteredPackageOrAnySessionIsConfirmed() async throws {
        let f = try Fixture(), setup = f.setup()
        for version in ["0.1.8", "9.4.3"] {
            let state = probe(setup, version: version)
            let result = await DSHReadinessTest.run(setup: setup, cancellation: .init(), timeout: 0,
                signal: { _, _ in XCTFail("health should not manufacture or require task events"); return nil },
                health: { _ in [state] })
            XCTAssertEqual(result.status, .connected)
            XCTAssertTrue(result.evidence.contains(version))
        }
        XCTAssertEqual(try setup.inspect().configuration, .absent)
    }

    @MainActor
    func testMigratedCompatibilityEndpointRequiresAnExplicitAcceptedRoot() async throws {
        let f = try Fixture(), setup = f.setup()
        var status = probe(setup).status
        status.eventSocket = "/tmp/local-source/agentpet.sock"
        let legacy = DSHBridgeProtocol.Probe(status: status, socketPath: "/tmp/fixture-unused.sock", peerPID: getpid())
        let refused = await DSHReadinessTest.run(setup: setup, cancellation: .init(), timeout: 0,
            signal: { _, _ in nil }, health: { _ in [legacy] }, acceptedEventSockets: [AgentPetPaths.socketPath])
        XCTAssertEqual(refused.status, .endpointUnavailable)
        let accepted = await DSHReadinessTest.run(setup: setup, cancellation: .init(), timeout: 0,
            signal: { _, _ in nil }, health: { _ in [legacy] },
            acceptedEventSockets: [AgentPetPaths.socketPath, status.eventSocket])
        XCTAssertEqual(accepted.status, .connected)
        status.eventConnected = false
        let disconnected = DSHBridgeProtocol.Probe(status: status, socketPath: "/tmp/fixture-unused.sock", peerPID: getpid())
        let stillRefused = await DSHReadinessTest.run(setup: setup, cancellation: .init(), timeout: 0,
            signal: { _, _ in nil }, health: { _ in [disconnected] }, acceptedEventSockets: [status.eventSocket])
        XCTAssertEqual(stillRefused.status, .endpointUnavailable)
    }

    @MainActor
    func testProtocolCapabilitiesAndAmbiguousEndpointsAreReportedSeparately() async throws {
        let f = try Fixture(), setup = f.setup()
        let cases: [(DSHBridgeProtocol.Probe, DSHReadinessResult.Status)] = [
            (probe(setup, major: 2), .incompatible),
            (probe(setup, clients: 0), .limited),
            (probe(setup, clients: 2), .limited),
            (probe(setup, eventConnected: false), .endpointUnavailable),
            (probe(setup, capabilities: ["lifecycle.v1", "future.v7"]), .limited),
        ]
        for (state, expected) in cases {
            let result = await DSHReadinessTest.run(setup: setup, cancellation: .init(), timeout: 0,
                signal: { _, _ in nil }, health: { _ in [state] })
            XCTAssertEqual(result.status, expected)
        }
        let state = probe(setup)
        let ambiguous = await DSHReadinessTest.run(setup: setup, cancellation: .init(), timeout: 0,
            signal: { _, _ in nil }, health: { _ in [state, state] })
        XCTAssertEqual(ambiguous.status, .endpointUnavailable)
    }

    @MainActor
    func testLegacyV1EventsRemainUsableDespiteMissingOrDamagedRegistration() async throws {
        let f = try Fixture(); try f.register()
        try FileManager.default.removeItem(at: f.package.appendingPathComponent("lib/client.js"))
        let setup = f.setup()
        let observation = DSHObservation(schema: 1, profileID: DSHLiveSignals.profileID(setup.target),
            hostID: UUID().uuidString, hostStartedAt: Date().addingTimeInterval(-20), nativeSessionID: "fixture",
            revision: 1, nativeSeq: 0, turn: nil, phase: .idle, pending: [], baseline: true, heartbeat: false, gap: false)
        let result = await DSHReadinessTest.run(setup: setup, cancellation: .init(), timeout: 0.02,
            signal: { _, _ in .init(observation: observation, receivedAt: Date()) }, verifyPeer: { _, _ in true })
        XCTAssertEqual(result.status, .connected)
        let wrongPeer = await DSHReadinessTest.run(setup: setup, cancellation: .init(), timeout: 0.02,
            signal: { _, _ in .init(observation: observation, receivedAt: Date()) }, verifyPeer: { _, _ in false })
        XCTAssertEqual(wrongPeer.status, .endpointUnavailable)
    }

    @MainActor
    func testCancellationAndStoppedHostNeverClaimConnection() async throws {
        let f = try Fixture(); try f.register()
        let stopped = await DSHReadinessTest.run(setup: f.setup(running: false), cancellation: .init(), timeout: 0,
            signal: { _, _ in nil })
        XCTAssertEqual(stopped.status, .startRequired)
        let cancellation = LocalAgentTestCancellation(); cancellation.cancel()
        let cancelled = await DSHReadinessTest.run(setup: f.setup(), cancellation: cancellation, timeout: 0,
            signal: { _, _ in XCTFail("cancelled"); return nil })
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    @MainActor
    func testDSHManagementRemainsAvailableWhenRegistrationNeedsRepair() throws {
        let f = try Fixture()
        try Data("not json".utf8).write(to: f.profile.appendingPathComponent("package.json"))
        let model = SettingsModel(dshSetup: f.setup())
        model.refresh()
        XCTAssertNotNil(model.integrationConflicts[.dsh])
        XCTAssertTrue(model.canConfigure(.dsh), "Native management is the repair path; bad registration cannot disable it")
    }
}
