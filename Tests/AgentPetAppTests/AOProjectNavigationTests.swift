import XCTest
import AgentPetCore
@testable import agentpet

@MainActor
final class AOProjectNavigationTests: XCTestCase {
    private let instance = "apprun-native-test"
    private let uuid = "11111111-1111-4111-8111-111111111111"
    private var target: AOProjectNavigation.Target {
        .init(projectID: "proj", projectName: "Project", orchestratorIDs: ["old-leader"], instanceID: instance)
    }
    private func capability(now: Date = Date()) -> AOProjectNavigation.Capability {
        .init(version: 1, instanceId: uuid, appRunId: instance, pid: 1234,
              appPath: "/Applications/AO.app", updatedAt: now.timeIntervalSince1970 * 1000)
    }
    private final class Driver: AOProjectNavigation.Driver {
        var opened: [AOProjectNavigation.Target] = []
        var outcome: AOProjectNavigation.Outcome = .opened(.board)
        var onOpen: (() -> Void)?
        func open(_ target: AOProjectNavigation.Target, validate: @escaping @MainActor () -> Bool) async -> AOProjectNavigation.Outcome {
            opened.append(target); onOpen?(); return outcome
        }
    }
    func testTargetDriverPreservesOrchestratorAndBoardEvidenceWithoutAcknowledgement() async {
        let driver = Driver()
        for destination in [AOProjectNavigation.Destination.orchestrator("new-leader"), .board] {
            driver.outcome = .opened(destination)
            let result = await AOProjectNavigation.open(target, driver: driver, validate: { true })
            guard case .opened(let actual) = result else { return XCTFail("expected native page evidence") }
            XCTAssertEqual(actual, destination)
            XCTAssertFalse(SessionNavigationResult.Evidence.aoProject(destination).acknowledgesNativeSession)
        }
        XCTAssertEqual(driver.opened, [target, target])
    }
    func testInvalidOrStandaloneProjectAndMissingGenerationNeverDispatch() async {
        let driver = Driver()
        for id in ["../proj", "proj:one", ".", AOHostMapping.standaloneProjectID] {
            let invalid = AOProjectNavigation.Target(projectID: id, projectName: "Project", orchestratorIDs: [], instanceID: instance)
            guard case .failed = await AOProjectNavigation.open(invalid, driver: driver, validate: { true }) else { return XCTFail("invalid project must fail") }
        }
        var missing = target; missing.instanceID = nil
        guard case .failed = await AOProjectNavigation.open(missing, driver: driver, validate: { true }) else { return XCTFail("generation required") }
        XCTAssertTrue(driver.opened.isEmpty)
    }
    func testSupersededClickCannotDispatchOrReturnSuccess() async {
        let driver = Driver()
        guard case .superseded = await AOProjectNavigation.open(target, driver: driver, validate: { false }) else { return XCTFail() }
        XCTAssertTrue(driver.opened.isEmpty)
        var valid = true; driver.onOpen = { valid = false }
        guard case .superseded = await AOProjectNavigation.open(target, driver: driver, validate: { valid }) else { return XCTFail() }
    }
    func testURLUsesOnlyStableIDsAndVersionedEntry() throws {
        let request = UUID().uuidString.lowercased()
        let url = try XCTUnwrap(AOProjectNavigation.requestURL(target: target, capability: capability(), requestID: request))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "ao-app"); XCTAssertEqual(parts.host, "navigate")
        let query = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query, ["v": "1", "instance": uuid, "request": request, "run": instance, "project": "proj"])
        XCTAssertNil(AOProjectNavigation.requestURL(target: target, capability: capability(), requestID: "../../file"))
    }
    func testCapabilityRequiresFreshMatchingDaemonGeneration() {
        let now = Date()
        let run = AORunFile(port: 3001, pid: 777, appRunID: instance)
        XCTAssertTrue(capability(now: now).isCurrent(run: run, target: target, now: now))
        XCTAssertFalse(capability(now: now.addingTimeInterval(-31)).isCurrent(run: run, target: target, now: now))
        XCTAssertFalse(capability(now: now.addingTimeInterval(1)).isCurrent(run: run, target: target, now: now))
        XCTAssertFalse(capability(now: now).isCurrent(run: .init(port: 3001, pid: 777, appRunID: "apprun-other-test"), target: target, now: now))
        var other = target; other.instanceID = "apprun-other-test"
        XCTAssertFalse(capability(now: now).isCurrent(run: run, target: other, now: now))
    }
    func testStandaloneTargetRequiresAdvertisedExtensionAndUsesOnlySessionID() throws {
        let standalone = AOProjectNavigation.Target(projectID: AOHostMapping.standaloneProjectID,
            projectName: "Standalone", orchestratorIDs: [], instanceID: instance, sessionID: "standalone-1")
        let now = Date(), run = AORunFile(port: 3001, pid: 777, appRunID: instance)
        XCTAssertFalse(capability(now: now).isCurrent(run: run, target: standalone, now: now))
        var supported = capability(now: now); supported.capabilities = ["standalone-session.v1"]
        XCTAssertTrue(supported.isCurrent(run: run, target: standalone, now: now))
        let url = try XCTUnwrap(AOProjectNavigation.requestURL(target: standalone, capability: supported, requestID: uuid))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "session" }?.value, "standalone-1")
        XCTAssertFalse(items.contains { $0.name == "project" })
        let exact = receipt(path: "/sessions/standalone-1", session: "standalone-1", project: AOHostMapping.standaloneProjectID)
        XCTAssertEqual(exact.destination(target: standalone), .session("standalone-1"))
        XCTAssertNil(receipt(path: "/sessions/other", session: "other", project: AOHostMapping.standaloneProjectID).destination(target: standalone))
        XCTAssertNil(receipt(path: "/projects/proj/sessions/standalone-1", session: "standalone-1").destination(target: standalone))
    }
    private func receipt(path: String?, session: String? = nil, project: String = "proj", status: String = "confirmed", completedAt: Double = 1000) -> AOProjectNavigation.Receipt {
        .init(version: 1, instanceId: uuid, appRunId: instance, projectId: project,
              requestId: uuid, status: status, path: path, sessionId: session, completedAt: completedAt)
    }
    func testExactProjectMemberRequiresOwnCapabilityAndBothIDs() throws {
        var member = target; member.sessionID = "worker-2"
        let now = Date(), run = AORunFile(port: 3001, pid: 777, appRunID: instance)
        var supported = capability(now: now); supported.capabilities = ["project.v1", "standalone-session.v1"]
        XCTAssertFalse(supported.isCurrent(run: run, target: member, now: now))
        supported.capabilities?.append("project-session.v1")
        XCTAssertTrue(supported.isCurrent(run: run, target: member, now: now))
        let url = try XCTUnwrap(AOProjectNavigation.requestURL(target: member, capability: supported, requestID: uuid))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(parts.first { $0.name == "project" }?.value, "proj")
        XCTAssertEqual(parts.first { $0.name == "session" }?.value, "worker-2")
        XCTAssertEqual(receipt(path: "/projects/proj/sessions/worker-2", session: "worker-2").destination(target: member), .session("worker-2"))
        for wrong in [receipt(path: "/projects/proj"), receipt(path: "/projects/proj/sessions/leader", session: "leader"),
                      receipt(path: "/sessions/worker-2", session: "worker-2"),
                      receipt(path: "/projects/other/sessions/worker-2", session: "worker-2", project: "other")] {
            XCTAssertNil(wrong.destination(target: member))
        }
    }
    func testReceiptRequiresExactProjectAndRoute() {
        XCTAssertEqual(receipt(path: "/projects/proj").destination(projectID: "proj"), .board)
        XCTAssertEqual(receipt(path: "/projects/proj/sessions/new-leader", session: "new-leader").destination(projectID: "proj"), .orchestrator("new-leader"))
        for invalid in [receipt(path: "/projects/proj-extra"), receipt(path: "/projects/other", project: "other"), receipt(path: "/projects/proj", status: "failed"), receipt(path: "/projects/proj/sessions/leader", session: "worker"), receipt(path: "/projects/proj/settings")] {
            XCTAssertNil(invalid.destination(projectID: "proj"))
        }
    }
    func testReceiptCannotReuseEarlierRequestOrTimestamp() {
        let start = Date(timeIntervalSince1970: 1), end = Date(timeIntervalSince1970: 2)
        XCTAssertTrue(receipt(path: "/projects/proj").matches(capability: capability(), target: target, requestID: uuid, since: start, now: end))
        XCTAssertFalse(receipt(path: "/projects/proj").matches(capability: capability(), target: target, requestID: UUID().uuidString, since: start, now: end))
        XCTAssertFalse(receipt(path: "/projects/proj", completedAt: 999).matches(capability: capability(), target: target, requestID: uuid, since: start, now: end))
        XCTAssertFalse(receipt(path: "/projects/proj", completedAt: 2001).matches(capability: capability(), target: target, requestID: uuid, since: start, now: end))
    }
    func testOfficialBuildWithoutCapabilityFailsWithoutRequestingPermission() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runFile = dir.appendingPathComponent("running.json")
        try Data("{\"port\":3001,\"pid\":1234,\"appRunId\":\"apprun-native-test\"}".utf8).write(to: runFile)
        let result = await AOProjectNavigation.open(target, driver: SystemAOProjectNavigationDriver(runFilePath: runFile.path), validate: { true })
        guard case .failed = result else { return XCTFail("capability absence must fail closed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("navigation-receipts").path))
    }
}
