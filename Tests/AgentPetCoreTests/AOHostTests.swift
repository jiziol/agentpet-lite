import XCTest
import Foundation
@testable import AgentPetCore

final class AOHostTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_000)
    private let instance = "apprun-11111111-1111-1111-1111-111111111111"

    private func observation(
        _ id: String = "proj-1", project: String = "proj",
        role: AOHostRole = .worker, harness: String = "opencode-v2",
        status: String = "working", displayStatus: String? = nil,
        activity: AOHostActivity = .active, terminated: Bool = false,
        createdAt: Date? = nil, updatedAt: Date? = nil, observedAt: Date? = nil,
        available: Bool = true, orchestration: AOOrchestration? = nil,
        projectName: String? = "AgentPet"
    ) -> AOHostObservation {
        AOHostObservation(
            sessionID: id, projectID: project, projectName: projectName, role: role,
            harness: harness, displayName: role == .orchestrator ? "Leader" : "Worker",
            branch: "ao/test", status: status, displayStatus: displayStatus,
            activity: activity, activityAt: updatedAt ?? at,
            isTerminated: terminated, createdAt: createdAt ?? at,
            updatedAt: updatedAt ?? at, lastEventAt: updatedAt ?? at,
            observedAt: observedAt ?? at, instanceID: instance, available: available,
            orchestration: orchestration)
    }

    private func snapshot(_ rows: [AOHostObservation], instanceID: String? = nil,
                          at time: Date? = nil) -> AOSnapshot {
        AOSnapshot(instanceID: instanceID ?? instance, observedAt: time ?? at,
                   projectNames: ["proj": "AgentPet"], sessions: rows)
    }

    private func hook(_ id: String, kind: AgentKind = .opencode, name: String = "working",
                      ao: String? = "proj-1", project: String? = "proj",
                      launch: String? = nil, at time: Date? = nil) -> AgentEvent {
        var event = AgentEvent(sessionId: id, agentKind: kind, eventName: name,
                               timestamp: time ?? at)
        event.aoSessionID = ao
        event.aoProjectID = project
        event.aoLaunchID = launch
        return event
    }

    // MARK: - Mapping

    func testAOStateMappingNeverClaimsSuccessFromHostFacts() {
        var working = observation()
        XCTAssertEqual(AOHostMapping.state(for: working), .working)
        XCTAssertEqual(AOHostMapping.message(for: working), "工作中")
        XCTAssertEqual(AOHostMapping.placeholderSession(for: working).taskResult, nil)

        working.activity = .waitingInput
        working.status = "needs_input"
        XCTAssertEqual(AOHostMapping.state(for: working), .waiting)
        XCTAssertEqual(AOHostMapping.message(for: working), "等待用户输入")
        XCTAssertEqual(AOHostMapping.placeholderSession(for: working).notificationVersion, 1)

        working.activity = .blocked
        working.status = "needs_input"
        XCTAssertEqual(AOHostMapping.state(for: working), .waiting)
        XCTAssertEqual(AOHostMapping.message(for: working), "等待人工处理")

        let terminated = observation(status: "terminated", activity: .exited, terminated: true)
        XCTAssertEqual(AOHostMapping.state(for: terminated), .idle)
        XCTAssertEqual(AOHostMapping.message(for: terminated), "AO 会话已退出")
        XCTAssertEqual(AOHostMapping.placeholderSession(for: terminated).taskResult, nil)

        let merged = observation(status: "merged", displayStatus: "Merged", activity: .idle)
        XCTAssertEqual(AOHostMapping.state(for: merged), .idle)
        XCTAssertTrue(AOHostMapping.message(for: merged).contains("PR 状态"))
        XCTAssertEqual(AOHostMapping.placeholderSession(for: merged).taskResult, nil)

        let noSignal = observation(status: "no_signal", displayStatus: "No signal", activity: .idle)
        XCTAssertEqual(AOHostMapping.state(for: noSignal), .idle)
        XCTAssertEqual(AOHostMapping.message(for: noSignal), "AO 无信号，结果未知")

        let unreachable = observation(activity: .active, available: false)
        XCTAssertEqual(AOHostMapping.state(for: unreachable), .idle)
        XCTAssertEqual(AOHostMapping.message(for: unreachable), "AO 不可达，状态未知")
    }

    func testHarnessMappingPreservesSourceIdentity() {
        XCTAssertEqual(AOHostMapping.agentKind(for: "codex"), .codex)
        XCTAssertEqual(AOHostMapping.agentKind(for: "opencode-v2"), .opencode)
        XCTAssertEqual(AOHostMapping.agentKind(for: "pi"), .pi)
        XCTAssertEqual(AOHostMapping.agentKind(for: "claude-code"), .claude)
        XCTAssertEqual(AOHostMapping.agentKind(for: "agy"), .antigravity)
        XCTAssertEqual(AOHostMapping.agentKind(for: "dsh"), .dsh)
        XCTAssertEqual(AOHostMapping.agentKind(for: "grok"), .grok)
        XCTAssertEqual(AOHostMapping.agentKind(for: "unknown-harness"), .unknown)
        let custom = AOHostMapping.placeholderSession(for: observation(harness: "unknown-harness"))
        XCTAssertEqual(custom.agentName, "unknown-harness")
        XCTAssertEqual(custom.id, "ao:proj-1")
        XCTAssertEqual(custom.source, .passive)
        XCTAssertTrue(custom.isAOPlaceholder)
    }

    func testEnvironmentCaptureRequiresExactSessionAndOptionalProject() {
        XCTAssertEqual(AOHostEnvironment.capture([
            "AO_SESSION_ID": "proj-1", "AO_PROJECT_ID": "proj",
        ]), .init(sessionID: "proj-1", projectID: "proj"))
        XCTAssertEqual(AOHostEnvironment.capture([
            "AO_SESSION_ID": "proj-1", "AO_PROJECT_ID": "proj",
            "AO_RUNTIME_LAUNCH_ID": "launch-1",
        ]), .init(sessionID: "proj-1", projectID: "proj", launchID: "launch-1"))
        XCTAssertEqual(AOHostEnvironment.capture(["AO_SESSION_ID": "proj-1"]),
                       .init(sessionID: "proj-1", projectID: nil))
        XCTAssertEqual(AOHostEnvironment.capture(["AO_SESSION_ID": "proj-1", "AO_PROJECT_ID": ""]),
                       .init(sessionID: "proj-1", projectID: nil))
        XCTAssertNil(AOHostEnvironment.capture(["AO_PROJECT_ID": "proj"]))
        XCTAssertNil(AOHostEnvironment.capture(["AO_SESSION_ID": "../bad", "AO_PROJECT_ID": "proj"]))
        XCTAssertNil(AOHostEnvironment.capture(["AO_SESSION_ID": "proj-1", "AO_PROJECT_ID": "../bad"]))
        XCTAssertNil(AOHostEnvironment.capture(["AO_SESSION_ID": "", "AO_PROJECT_ID": "proj"]))
    }

    // MARK: - Discovery and parsing

    func testRunFileIsBoundedAndRequiresRunScopedIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("running.json").path
        let body = """
        {"pid":42,"port":3001,"appRunId":"\(instance)","startedAt":"2026-10-23T05:00:00.000Z"}
        """
        try Data(body.utf8).write(to: URL(fileURLWithPath: path))
        let run = try XCTUnwrap(AORunFile.read(path: path))
        XCTAssertEqual(run.port, 3001)
        XCTAssertEqual(run.pid, 42)
        XCTAssertEqual(run.appRunID, instance)
        XCTAssertNotNil(run.startedAt)

        for invalid in [
            "{\"pid\":42,\"port\":0,\"appRunId\":\"\(instance)\"}",
            "{\"pid\":42,\"port\":3001}",
            "{\"pid\":0,\"port\":3001,\"appRunId\":\"\(instance)\"}",
            "{\"pid\":42,\"port\":3001,\"appRunId\":\"nope\"}",
        ] {
            try Data(invalid.utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertNil(AORunFile.read(path: path), invalid)
        }
    }

    func testSnapshotParserGroupsExactProjectsWithoutInventingParentRelationships() throws {
        let sessions = """
        {"sessions":[
          {"id":"proj-1","projectId":"proj","kind":"orchestrator","harness":"codex",
           "displayName":"Leader","branch":"ao/orch","status":"idle","displayStatus":"Working",
           "isTerminated":false,"createdAt":"2026-10-23T05:00:00.000Z",
           "updatedAt":"2026-10-23T05:10:00.000Z","lastEventAt":"2026-10-23T05:10:00.000Z",
           "activity":{"state":"active","lastActivityAt":"2026-10-23T05:10:00.000Z"}},
          {"id":"proj-2","projectId":"proj","kind":"worker","harness":"opencode-v2",
           "displayName":"Worker","status":"needs_input","displayStatus":"Blocked",
           "isTerminated":false,"createdAt":"2026-10-23T05:01:00.000Z",
           "updatedAt":"2026-10-23T05:11:00.000Z",
           "activity":{"state":"waiting_input","lastActivityAt":"2026-10-23T05:11:00.000Z"}},
          {"id":"solo-1","kind":"worker","harness":"pi",
           "status":"working","createdAt":"2026-10-23T05:02:00Z",
           "updatedAt":"2026-10-23T05:12:00Z",
           "activity":{"state":"active","lastActivityAt":"2026-10-23T05:12:00Z"}},
          {"id":"bad id","projectId":"proj","kind":"worker","harness":"codex",
           "status":"working","createdAt":"2026-10-23T05:00:00Z","updatedAt":"2026-10-23T05:00:00Z"}
        ]}
        """
        let projects = """
        {"projects":[{"id":"proj","name":"AgentPet"},{"id":"../bad","name":"Bad"}]}
        """
        let run = AORunFile(port: 3001, pid: 42, appRunID: instance)
        let parsed = try XCTUnwrap(AOSnapshotParser.parse(
            sessionsData: Data(sessions.utf8), projectsData: Data(projects.utf8),
            run: run, observedAt: at))
        XCTAssertEqual(parsed.instanceID, instance)
        XCTAssertEqual(parsed.projectNames, ["proj": "AgentPet"])
        XCTAssertEqual(parsed.sessions.count, 3)
        let leader = try XCTUnwrap(parsed.sessions.first { $0.sessionID == "proj-1" })
        XCTAssertEqual(leader.role, .orchestrator)
        XCTAssertEqual(leader.projectName, "AgentPet")
        XCTAssertEqual(leader.orchestration?.teamID, "proj")
        XCTAssertEqual(leader.orchestration?.role, .lead)
        XCTAssertNil(leader.orchestration?.orchestratorSessionID)
        let worker = try XCTUnwrap(parsed.sessions.first { $0.sessionID == "proj-2" })
        XCTAssertEqual(worker.role, .worker)
        XCTAssertEqual(worker.activity, .waitingInput)
        XCTAssertTrue(worker.isWaiting)
        XCTAssertEqual(worker.orchestration?.teamID, "proj")
        XCTAssertEqual(worker.orchestration?.role, .teammate)
        XCTAssertNil(worker.orchestration?.orchestratorSessionID)
        let standalone = try XCTUnwrap(parsed.sessions.first { $0.sessionID == "solo-1" })
        XCTAssertEqual(standalone.projectID, AOHostMapping.standaloneProjectID)
        XCTAssertEqual(standalone.projectName, "Standalone")
        XCTAssertEqual(standalone.role, .worker)
        XCTAssertNil(standalone.orchestration)
    }

    func testSSEParserKeepsOnlyEventNamesAndIDs() {
        var parser = AOSSEParser()
        XCTAssertNil(parser.consume(line: "event: session_updated"))
        XCTAssertNil(parser.consume(line: "id: 42"))
        XCTAssertNil(parser.consume(line: "data: {\"private\":\"secret\"}"))
        XCTAssertEqual(parser.consume(line: ""), .init(type: "session_updated", id: "42"))
        XCTAssertTrue(AOSSEParser.invalidates("session_updated"))
        XCTAssertTrue(AOSSEParser.invalidates("pr_updated"))
        XCTAssertFalse(AOSSEParser.invalidates("heartbeat"))

        XCTAssertNil(parser.consume(line: "event: Session Updated"))
        XCTAssertNil(parser.consume(line: "data: {}"))
        XCTAssertNil(parser.consume(line: ""))
    }

    // MARK: - Reducer projection

    func testPlaceholderIsReplacedByExactHookBindingWithoutCopyingLocalReceipt() throws {
        let store = SessionStore()
        let waiting = observation(status: "needs_input", activity: .waitingInput)
        _ = store.applyAOSnapshot(snapshot([waiting]), now: at)
        let placeholder = try XCTUnwrap(store.session(id: "ao:proj-1"))
        XCTAssertTrue(placeholder.isAOPlaceholder)
        XCTAssertEqual(placeholder.state, .waiting)
        XCTAssertEqual(placeholder.notificationVersion, 1)
        store.markRead(id: placeholder.id, through: 1)
        let read = try XCTUnwrap(store.session(id: placeholder.id))
        XCTAssertEqual(read.readThroughVersion, 1)

        let native = try XCTUnwrap(store.apply(hook("ses_native", at: at.addingTimeInterval(1)),
                                               now: at.addingTimeInterval(1)))
        XCTAssertEqual(native.aoBinding?.sessionID, "proj-1")
        XCTAssertEqual(native.aoBinding?.projectID, "proj")
        XCTAssertEqual(native.aoBinding?.origin, .hookEnvironment)
        XCTAssertNil(store.session(id: "ao:proj-1"))
        XCTAssertEqual(store.session(id: "ses_native")?.readThroughVersion, 0)
        XCTAssertEqual(native.state, .working, "native Hook state must win over AO waiting")
    }

    func testNativeBindingIdentityIsBoundedButNotAnAOObjectID() throws {
        let store = SessionStore()
        let binding = AOBinding(sessionID: "proj-1", projectID: "proj", agentKind: .pi,
            origin: .hookEnvironment, boundAt: at)
        for id in ["", "pi:/tmp/bad\n.jsonl", "pi:" + String(repeating: "a", count: 318)] {
            XCTAssertFalse(store.renewAOHostBinding(nativeSessionID: id, createdAt: nil,
                binding: binding, now: at))
        }
        let id = "pi:/Users/test/.pi/agent/sessions/a session.jsonl"
        _ = store.renewAOHostBinding(nativeSessionID: id, createdAt: nil, binding: binding, now: at)
        _ = store.apply(hook(id, kind: .pi, ao: nil), now: at)
        XCTAssertEqual(store.session(id: id)?.aoBinding?.sessionID, "proj-1")
        let invalidAO = AOBinding(sessionID: "../proj-1", projectID: "proj", agentKind: .pi,
            origin: .hookEnvironment, boundAt: at)
        XCTAssertFalse(store.renewAOHostBinding(nativeSessionID: id, createdAt: nil,
            binding: invalidAO, now: at), "AO coordinates still require strict AO IDs")
        _ = store.apply(hook("pi:/tmp/other.jsonl", kind: .pi), now: at)
        XCTAssertNotNil(store.session(id: id)?.aoBinding?.conflictedAt,
                        "different Pi session files must retain conflicting exact claims")
        XCTAssertNotNil(store.session(id: "pi:/tmp/other.jsonl")?.aoBinding?.conflictedAt)
    }

    func testHostFactsNeverRewriteNativeStateOrResult() throws {
        let store = SessionStore()
        var done = hook("ses_native", name: "done", at: at.addingTimeInterval(1))
        done.turnResult = .completed
        _ = try XCTUnwrap(store.apply(hook("ses_native", at: at), now: at))
        _ = try XCTUnwrap(store.apply(done, now: at.addingTimeInterval(1)))
        let terminated = observation(status: "terminated", activity: .exited, terminated: true,
                                     updatedAt: at.addingTimeInterval(2))
        _ = store.applyAOSnapshot(snapshot([terminated], at: at.addingTimeInterval(2)), now: at.addingTimeInterval(2))
        let session = try XCTUnwrap(store.session(id: "ses_native"))
        XCTAssertEqual(session.state, .done)
        XCTAssertEqual(session.taskResult, .completed)
        XCTAssertTrue(session.aoObservation?.isTerminated == true)
    }

    func testOutOfOrderSnapshotCannotReviveAnOlderState() throws {
        let store = SessionStore()
        let newer = observation(status: "working", activity: .active, updatedAt: at.addingTimeInterval(20))
        _ = store.applyAOSnapshot(snapshot([newer], at: at.addingTimeInterval(20)), now: at.addingTimeInterval(20))
        XCTAssertEqual(store.session(id: "ao:proj-1")?.state, .working)

        let older = observation(status: "terminated", activity: .exited, terminated: true,
                                updatedAt: at.addingTimeInterval(10))
        _ = store.applyAOSnapshot(snapshot([older], at: at.addingTimeInterval(21)), now: at.addingTimeInterval(21))
        XCTAssertEqual(store.session(id: "ao:proj-1")?.state, .working)
        XCTAssertNotEqual(store.session(id: "ao:proj-1")?.message, "AO 会话已退出")

        let newest = observation(status: "terminated", activity: .exited, terminated: true,
                                 updatedAt: at.addingTimeInterval(30))
        _ = store.applyAOSnapshot(snapshot([newest], at: at.addingTimeInterval(30)), now: at.addingTimeInterval(30))
        XCTAssertEqual(store.session(id: "ao:proj-1")?.state, .idle)
        XCTAssertEqual(store.session(id: "ao:proj-1")?.message, "AO 会话已退出")
    }

    func testSnapshotRemovalDropsBoundObservationWithoutLosingBinding() throws {
        let store = SessionStore()
        _ = try XCTUnwrap(store.apply(hook("ses_native", at: at), now: at))
        _ = store.applyAOSnapshot(snapshot([observation()]), now: at)
        XCTAssertNotNil(store.session(id: "ses_native")?.aoObservation)
        _ = store.applyAOSnapshot(snapshot([]), now: at.addingTimeInterval(1))
        let session = try XCTUnwrap(store.session(id: "ses_native"))
        XCTAssertNil(session.aoObservation)
        XCTAssertEqual(session.aoBinding?.sessionID, "proj-1")
        XCTAssertNil(session.hostTeamScope)
    }

    func testDaemonInstanceChangeDropsOldClaimsWhileKeepingNativeRow() throws {
        let store = SessionStore()
        _ = try XCTUnwrap(store.apply(hook("ses_native", at: at), now: at))
        let team = AOOrchestration(teamID: "orch-1", teamName: "AO Team", role: .teammate,
                                   orchestratorSessionID: "proj-0")
        let withTeam = observation(orchestration: team)
        _ = store.applyAOSnapshot(snapshot([withTeam]), now: at)
        XCTAssertEqual(store.session(id: "ses_native")?.hostTeamScope?.host, .agentOrchestrator)
        XCTAssertEqual(store.session(id: "ses_native")?.hostTeamScope?.role, .teammate)

        let nextInstance = "apprun-22222222-2222-2222-2222-222222222222"
        _ = store.applyAOSnapshot(snapshot([], instanceID: nextInstance, at: at.addingTimeInterval(1)),
                                  now: at.addingTimeInterval(1))
        let native = try XCTUnwrap(store.session(id: "ses_native"))
        XCTAssertNil(native.aoBinding)
        XCTAssertNil(native.aoObservation)
        XCTAssertNil(native.hostTeamScope)
        XCTAssertNil(store.session(id: "ao:proj-1"))
    }

    func testStandaloneAOSessionBindsWithoutFabricatingAProject() throws {
        let standalone = observation("solo-1", project: AOHostMapping.standaloneProjectID,
                                     projectName: "Standalone")
        XCTAssertTrue(standalone.valid)
        let store = SessionStore()
        _ = try XCTUnwrap(store.apply(hook("ses_solo", ao: "solo-1", project: nil, at: at), now: at))
        _ = store.applyAOSnapshot(snapshot([standalone]), now: at)
        let native = try XCTUnwrap(store.session(id: "ses_solo"))
        XCTAssertNil(native.aoBinding?.projectID)
        XCTAssertEqual(native.aoObservation?.projectID, AOHostMapping.standaloneProjectID)
        XCTAssertEqual(native.aoObservation?.projectName, "Standalone")
        XCTAssertNil(store.session(id: "ao:solo-1"))
        XCTAssertNil(native.hostTeamScope)
    }

    func testIdleAndTerminatedHistoryDoesNotCreateAOOnlyRows() {
        let store = SessionStore()
        let idle = observation("proj-idle", status: "idle", activity: .idle)
        let terminated = observation("proj-ended", status: "terminated", activity: .exited, terminated: true)
        let pr = observation("proj-pr", status: "merged", activity: .idle)
        _ = store.applyAOSnapshot(snapshot([idle, terminated, pr]), now: at)
        XCTAssertNil(store.session(id: "ao:proj-idle"))
        XCTAssertNil(store.session(id: "ao:proj-ended"))
        XCTAssertNil(store.session(id: "ao:proj-pr"))
    }

    func testUnavailableProjectionIsUnknownAndNotSuccess() throws {
        let store = SessionStore()
        _ = store.applyAOSnapshot(snapshot([observation(status: "needs_input", activity: .waitingInput)]), now: at)
        _ = store.markAOUnavailable(now: at.addingTimeInterval(1))
        let placeholder = try XCTUnwrap(store.session(id: "ao:proj-1"))
        XCTAssertEqual(placeholder.state, .idle)
        XCTAssertEqual(placeholder.message, "AO 不可达，状态未知")
        XCTAssertNil(placeholder.taskResult)
        XCTAssertNil(placeholder.hostTeamScope)
    }

    func testWorkersAndProjectsStayIndependentWithoutOrchestrationEvidence() throws {
        let store = SessionStore()
        let one = observation("proj-1", project: "proj-a")
        let two = observation("proj-2", project: "proj-b")
        _ = store.applyAOSnapshot(snapshot([one, two]), now: at)
        XCTAssertNotNil(store.session(id: "ao:proj-1"))
        XCTAssertNotNil(store.session(id: "ao:proj-2"))
        XCTAssertNil(store.session(id: "ao:proj-1")?.hostTeamScope)
        XCTAssertNil(store.session(id: "ao:proj-2")?.hostTeamScope)

        _ = try XCTUnwrap(store.apply(hook("ses_one", ao: "proj-1", project: "proj-a", at: at), now: at))
        XCTAssertNil(store.session(id: "ao:proj-1"))
        XCTAssertNotNil(store.session(id: "ao:proj-2"),
                        "binding one worker must not remove another project's row")
    }

    func testSecondNativeClaimMarksConflictWithoutHidingEitherNativeRow() throws {
        let store = SessionStore()
        _ = try XCTUnwrap(store.apply(hook("ses_parent", launch: "launch-1", at: at), now: at))
        var done = hook("ses_parent", name: "done", launch: "launch-1", at: at.addingTimeInterval(1))
        done.turnResult = .completed
        _ = try XCTUnwrap(store.apply(done, now: at.addingTimeInterval(1)))
        let completed = try XCTUnwrap(store.session(id: "ses_parent"))
        XCTAssertEqual(completed.state, .done)
        XCTAssertEqual(completed.taskResult, .completed)
        XCTAssertTrue(completed.hasUnread)

        // Same AO identity and same launch: a nested same-harness CLI can
        // inherit the exact environment. Its later createdAt is not identity.
        _ = try XCTUnwrap(store.apply(hook("ses_nested", launch: "launch-1",
                                           at: at.addingTimeInterval(2)),
                                      now: at.addingTimeInterval(2)))
        let parent = try XCTUnwrap(store.session(id: "ses_parent"))
        let nested = try XCTUnwrap(store.session(id: "ses_nested"))
        XCTAssertEqual(parent.aoBinding?.isCurrent, false)
        XCTAssertEqual(nested.aoBinding?.isCurrent, false)
        XCTAssertEqual(parent.aoBinding?.launchID, "launch-1")
        XCTAssertEqual(nested.aoBinding?.launchID, "launch-1")
        XCTAssertNil(parent.aoObservation)
        XCTAssertNil(nested.aoObservation)
        XCTAssertNil(store.session(id: "ao:proj-1"))
        // The unread native result and the nested native row remain visible;
        // neither claim is allowed to become the current AO role.
        XCTAssertTrue(parent.hasUnread)
        XCTAssertNotNil(store.session(id: "ses_parent"))
        XCTAssertNotNil(store.session(id: "ses_nested"))

        _ = store.apply(hook("ses_parent", at: at.addingTimeInterval(3)), now: at.addingTimeInterval(3))
        let late = try XCTUnwrap(store.session(id: "ses_parent"))
        XCTAssertEqual(late.aoBinding?.isCurrent, false)
        XCTAssertNil(late.aoObservation)
        XCTAssertEqual(store.session(id: "ses_nested")?.aoBinding?.isCurrent, false)

        // User acknowledgement remains local to the old native row and is not
        // recreated by another AO snapshot.
        _ = store.markOpened(late, at: at.addingTimeInterval(4))
        let acknowledged = try XCTUnwrap(store.session(id: "ses_parent"))
        XCTAssertFalse(acknowledged.hasUnread)
        let version = acknowledged.notificationVersion
        _ = store.applyAOSnapshot(snapshot([observation()]), now: at.addingTimeInterval(5))
        let afterSnapshot = try XCTUnwrap(store.session(id: "ses_parent"))
        XCTAssertEqual(afterSnapshot.notificationVersion, version)
        XCTAssertFalse(afterSnapshot.hasUnread)
    }

    func testDifferentLaunchAlsoRequiresExplicitReconfirmation() throws {
        let store = SessionStore()
        _ = try XCTUnwrap(store.apply(hook("ses_a", launch: "launch-a", at: at), now: at))
        _ = try XCTUnwrap(store.apply(hook("ses_b", launch: "launch-b",
                                           at: at.addingTimeInterval(1)),
                                      now: at.addingTimeInterval(1)))
        XCTAssertEqual(store.session(id: "ses_a")?.aoBinding?.isCurrent, false)
        XCTAssertEqual(store.session(id: "ses_b")?.aoBinding?.isCurrent, false)
        XCTAssertNil(store.session(id: "ses_a")?.aoObservation)
        XCTAssertNil(store.session(id: "ses_b")?.aoObservation)
        XCTAssertNil(store.session(id: "ao:proj-1"))
    }

    func testPendingClaimsUseTheSameConflictBoundary() throws {
        let store = SessionStore()
        let first = AOBinding(sessionID: "proj-1", projectID: "proj", agentKind: .opencode,
                              origin: .hookEnvironment, boundAt: at)
        let second = AOBinding(sessionID: "proj-1", projectID: "proj", agentKind: .opencode,
                               origin: .hookEnvironment, boundAt: at)
        _ = store.renewAOHostBinding(nativeSessionID: "ses_pending_a", createdAt: nil,
                                     binding: first, now: at)
        _ = store.renewAOHostBinding(nativeSessionID: "ses_pending_b", createdAt: nil,
                                     binding: second, now: at)
        _ = try XCTUnwrap(store.apply(hook("ses_pending_a", ao: nil, project: nil, at: at), now: at))
        _ = try XCTUnwrap(store.apply(hook("ses_pending_b", ao: nil, project: nil, at: at), now: at))
        XCTAssertEqual(store.session(id: "ses_pending_a")?.aoBinding?.isCurrent, false)
        XCTAssertEqual(store.session(id: "ses_pending_b")?.aoBinding?.isCurrent, false)
        XCTAssertNil(store.session(id: "ses_pending_a")?.aoObservation)
        XCTAssertNil(store.session(id: "ses_pending_b")?.aoObservation)
        XCTAssertNil(store.session(id: "ao:proj-1"))
        // Both native rows remain as ordinary tasks; App presentation tests
        // verify they are visible with their own state.
        XCTAssertNotNil(store.session(id: "ses_pending_a"))
        XCTAssertNotNil(store.session(id: "ses_pending_b"))
    }

    func testIndependentAOTasksStillBindIndependently() throws {
        let store = SessionStore()
        _ = try XCTUnwrap(store.apply(hook("ses_one", ao: "proj-1", project: "proj-a", at: at), now: at))
        _ = try XCTUnwrap(store.apply(hook("ses_two", ao: "proj-2", project: "proj-b",
                                           at: at.addingTimeInterval(1)),
                                      now: at.addingTimeInterval(1)))
        XCTAssertEqual(store.session(id: "ses_one")?.aoBinding?.isCurrent, true)
        XCTAssertEqual(store.session(id: "ses_two")?.aoBinding?.isCurrent, true)
    }

    func testLaunchGenerationIsPersistedOnTheExactBinding() throws {
        let store = SessionStore()
        let session = try XCTUnwrap(store.apply(
            hook("ses_launch", ao: "solo-1", project: nil, launch: "launch-1", at: at), now: at))
        XCTAssertEqual(session.aoBinding?.sessionID, "solo-1")
        XCTAssertEqual(session.aoBinding?.launchID, "launch-1")
        XCTAssertNil(session.aoBinding?.projectID)
    }

    func testSubagentAndMismatchedProjectNeverBind() throws {
        let store = SessionStore()
        var child = hook("ses_child", at: at)
        child.opencodeParentSessionID = "ses_parent"
        XCTAssertNil(store.apply(child, now: at))
        XCTAssertNil(store.session(id: "ses_child")?.aoBinding)

        _ = try XCTUnwrap(store.apply(hook("ses_native", at: at), now: at))
        let otherProject = observation("proj-1", project: "other")
        _ = store.applyAOSnapshot(snapshot([otherProject]), now: at)
        XCTAssertNil(store.session(id: "ses_native")?.aoObservation,
                     "a project mismatch must not attach host context")
    }

    func testExplicitOrchestrationDrivesHostNeutralTeamScope() throws {
        let store = SessionStore()
        _ = try XCTUnwrap(store.apply(hook("ses_native", at: at), now: at))
        let teammate = AOOrchestration(teamID: "orch-1", teamName: "AO Team", role: .teammate,
                                       orchestratorSessionID: "orch-1")
        _ = store.applyAOSnapshot(snapshot([observation(orchestration: teammate)]), now: at)
        let session = try XCTUnwrap(store.session(id: "ses_native"))
        let scope = try XCTUnwrap(session.hostTeamScope)
        XCTAssertEqual(scope.host, .agentOrchestrator)
        XCTAssertEqual(scope.teamID, "orch-1")
        XCTAssertEqual(scope.teamName, "AO Team")
        XCTAssertEqual(scope.role, .teammate)
        XCTAssertNotNil(scope.verifiedAt)

        let lead = AOOrchestration(teamID: "orch-1", teamName: "AO Team", role: .lead,
                                   orchestratorSessionID: "orch-1")
        let leadObservation = observation("orch-1", role: .orchestrator, orchestration: lead)
        _ = store.applyAOSnapshot(snapshot([leadObservation]), now: at)
        XCTAssertEqual(store.session(id: "ao:orch-1")?.hostTeamScope?.role, .lead)
    }

    func testClearAOHostClaimsKeepsNativeStateAndUnread() throws {
        let store = SessionStore()
        _ = try XCTUnwrap(store.apply(hook("ses_native", at: at), now: at))
        var done = hook("ses_native", name: "done", at: at.addingTimeInterval(1))
        done.turnResult = .completed
        _ = try XCTUnwrap(store.apply(done, now: at.addingTimeInterval(1)))
        XCTAssertNotNil(store.session(id: "ses_native")?.aoBinding)
        XCTAssertTrue(store.clearAOHostClaims())
        let native = try XCTUnwrap(store.session(id: "ses_native"))
        XCTAssertNil(native.aoBinding)
        XCTAssertNil(native.aoObservation)
        XCTAssertEqual(native.state, .done)
        XCTAssertEqual(native.taskResult, .completed)
        XCTAssertTrue(native.hasUnread)
    }

    func testRestoreDropsOldAOClaimsWhileKeepingNativeRowAndReceipt() throws {        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")

        let store = SessionStore()
        store.persistenceURL = url
        _ = try XCTUnwrap(store.apply(hook("ses_native", at: at), now: at))
        _ = store.applyAOSnapshot(snapshot([observation(orchestration: AOOrchestration(
            teamID: "orch-1", teamName: "AO Team", role: .teammate))]), now: at)
        var done = hook("ses_native", name: "done", at: at.addingTimeInterval(1))
        done.turnResult = .completed
        _ = try XCTUnwrap(store.apply(done, now: at.addingTimeInterval(1)))
        XCTAssertTrue(try XCTUnwrap(store.session(id: "ses_native")).hasUnread)
        store.persistCodexSessions()
        XCTAssertEqual(store.flushSnapshots().error, nil)

        let restored = SessionStore()
        restored.persistenceURL = url
        restored.restoreCodexSessions()
        let native = try XCTUnwrap(restored.session(id: "ses_native"))
        XCTAssertNil(native.aoBinding)
        XCTAssertNil(native.aoObservation)
        XCTAssertNil(native.hostTeamScope)
        XCTAssertEqual(native.state, .done)
        XCTAssertEqual(native.taskResult, .completed)
        XCTAssertTrue(native.hasUnread, "restart must preserve the native unread result")
        XCTAssertNil(native.aoBinding?.sessionID)
        XCTAssertNil(restored.session(id: "ao:proj-1"))
    }

    func testConflictedClaimsKeepExactHostWaitingAndNativeUnread() throws {
        let store = SessionStore()
        for id in ["ses_a", "ses_b"] {
            _ = store.apply(hook(id), now: at)
            var done = hook(id, name: "done", at: at.addingTimeInterval(1))
            done.turnResult = .completed
            _ = store.apply(done, now: at.addingTimeInterval(1))
        }
        let nativeBefore = ["ses_a", "ses_b"].compactMap { store.session(id: $0) }
        let waiting = observation(status: "needs_input", activity: .waitingInput)
        _ = store.applyAOSnapshot(snapshot([waiting]), now: at)
        let host = try XCTUnwrap(store.session(id: "ao:proj-1"))
        XCTAssertEqual(host.aoObservation?.sessionID, "proj-1")
        XCTAssertEqual(host.state, .waiting)
        XCTAssertTrue(host.hasUnread)
        XCTAssertNil(host.taskResult)
        for before in nativeBefore {
            let native = try XCTUnwrap(store.session(id: before.id))
            XCTAssertEqual(native.notificationVersion, before.notificationVersion)
            XCTAssertEqual(native.readThroughVersion, before.readThroughVersion)
            XCTAssertEqual(native.readAt, before.readAt)
            XCTAssertTrue(native.hasUnread)
            XCTAssertNil(native.aoObservation)
            XCTAssertNil(native.hostTeamScope)
            XCTAssertFalse(try XCTUnwrap(native.aoBinding).isCurrent)
        }
    }

    func testPendingClaimCannotSuppressWaitingBeforeNativeMaterializes() throws {
        let store = SessionStore()
        let binding = AOBinding(sessionID: "proj-1", projectID: "proj", agentKind: .opencode,
                                origin: .hookEnvironment, boundAt: at)
        _ = store.renewAOHostBinding(nativeSessionID: "ses_pending", createdAt: nil,
                                     binding: binding, now: at)
        _ = store.applyAOSnapshot(snapshot([observation(status: "needs_input", activity: .waitingInput)]), now: at)
        XCTAssertEqual(try XCTUnwrap(store.session(id: "ao:proj-1")).state, .waiting)
        _ = store.apply(hook("ses_pending", ao: nil, project: nil), now: at)
        XCTAssertNil(store.session(id: "ao:proj-1"))
        XCTAssertEqual(store.session(id: "ses_pending")?.aoObservation?.isWaiting, true)
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testFirstMismatchedSnapshotStillDisplaysExactHostWaiting() throws {
        for mismatch in [observation(project: "other", status: "needs_input", activity: .waitingInput),
                         observation(harness: "pi", status: "needs_input", activity: .waitingInput)] {
            let store = SessionStore()
            _ = store.apply(hook("ses_native"), now: at)
            _ = store.applyAOSnapshot(snapshot([mismatch]), now: at)
            XCTAssertNil(store.session(id: "ses_native")?.aoBinding)
            XCTAssertNil(store.session(id: "ses_native")?.aoObservation)
            XCTAssertEqual(try XCTUnwrap(store.session(id: "ao:proj-1")).state, .waiting)
        }
    }

    func testUniqueBindingAfterSnapshotDeduplicatesWithoutCopyingReceipts() throws {
        let store = SessionStore()
        _ = store.applyAOSnapshot(snapshot([observation(status: "needs_input", activity: .waitingInput)]), now: at)
        store.markRead(id: "ao:proj-1", through: 1)
        _ = store.apply(hook("ses_native"), now: at)
        let native = try XCTUnwrap(store.session(id: "ses_native"))
        XCTAssertNil(store.session(id: "ao:proj-1"))
        XCTAssertTrue(try XCTUnwrap(native.aoObservation).isWaiting)
        XCTAssertEqual(native.notificationVersion, 0)
        XCTAssertEqual(native.readThroughVersion, 0)
        XCTAssertNil(native.readAt)
        _ = store.applyAOSnapshot(snapshot([observation(status: "needs_input", activity: .waitingInput)]), now: at)
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testConflictFormationPreservesHostTransitionAndRejectsOlderWaiting() throws {
        let store = SessionStore()
        _ = store.apply(hook("ses_a"), now: at)
        _ = store.applyAOSnapshot(snapshot([observation()]), now: at)
        _ = store.apply(hook("ses_b", at: at.addingTimeInterval(1)), now: at.addingTimeInterval(1))
        let waiting = observation(status: "needs_input", activity: .waitingInput,
                                  updatedAt: at.addingTimeInterval(2))
        let transitions = store.applyAOSnapshot(snapshot([waiting], at: at.addingTimeInterval(2)), now: at.addingTimeInterval(2))
        let transition = try XCTUnwrap(transitions.first)
        XCTAssertEqual(transition.before?.state, .working, "a known live host transition is not startup history")
        XCTAssertEqual(transition.after.state, .waiting)
        let version = transition.after.notificationVersion
        XCTAssertTrue(store.applyAOSnapshot(snapshot([waiting], at: at.addingTimeInterval(3)), now: at.addingTimeInterval(3)).isEmpty)
        _ = store.applyAOSnapshot(snapshot([observation()], at: at.addingTimeInterval(4)), now: at.addingTimeInterval(4))
        XCTAssertEqual(store.session(id: "ao:proj-1")?.state, .waiting)
        XCTAssertEqual(store.session(id: "ao:proj-1")?.notificationVersion, version)
        // Clearing the native claims needs fresh Hook evidence; it must not
        // silently promote either old native row or copy host acknowledgements.
        XCTAssertTrue(store.clearAOHostClaims())
        _ = store.applyAOSnapshot(snapshot([waiting], at: at.addingTimeInterval(5)), now: at.addingTimeInterval(5))
        XCTAssertEqual(store.session(id: "ao:proj-1")?.state, .waiting)
        _ = store.apply(hook("ses_a", at: at.addingTimeInterval(6)), now: at.addingTimeInterval(6))
        XCTAssertNil(store.session(id: "ao:proj-1"))
        XCTAssertEqual(store.session(id: "ses_a")?.aoObservation?.isWaiting, true)
        XCTAssertNil(store.session(id: "ses_b")?.aoObservation)
    }

    func testMismatchInvalidatesOnlyDisprovedPendingClaimBeforeBinding() throws {
        let store = SessionStore()
        for (id, project) in [("ses_bad", "wrong"), ("ses_good", "proj")] {
            _ = store.renewAOHostBinding(nativeSessionID: id, createdAt: nil,
                binding: AOBinding(sessionID: "proj-1", projectID: project, agentKind: .opencode,
                                   origin: .hookEnvironment, boundAt: at), now: at)
        }
        _ = store.applyAOSnapshot(snapshot([observation(status: "needs_input", activity: .waitingInput)]), now: at)
        XCTAssertEqual(store.session(id: "ao:proj-1")?.state, .waiting)
        _ = store.apply(hook("ses_bad", ao: nil, project: nil), now: at)
        XCTAssertNil(store.session(id: "ses_bad")?.aoBinding)
        _ = store.apply(hook("ses_good", ao: nil, project: nil), now: at)
        XCTAssertEqual(store.session(id: "ses_good")?.aoBinding?.isCurrent, false,
                       "disproving another claim does not promote an old conflict")
        XCTAssertNotNil(store.session(id: "ao:proj-1"))
    }

    func testHistoricalClaimKeepsNoSignalAndObservedExitIndependent() throws {
        let reducer = SessionReducer()
        _ = reducer.apply(hook("ses_old"), now: at)
        reducer.byID["ses_old"]?.aoBinding?.supersededAt = at
        let noSignal = observation(status: "no_signal", activity: .unknown)
        _ = reducer.applyAOSnapshot(snapshot([noSignal]), now: at)
        XCTAssertEqual(reducer.byID["ao:proj-1"]?.message, "AO 无信号，结果未知")
        XCTAssertNil(reducer.byID["ses_old"]?.aoObservation)

        let store = SessionStore()
        _ = store.apply(hook("ses_a"), now: at)
        _ = store.applyAOSnapshot(snapshot([observation()]), now: at)
        _ = store.apply(hook("ses_b"), now: at)
        let exited = observation(status: "terminated", activity: .exited, terminated: true,
                                 updatedAt: at.addingTimeInterval(1))
        _ = store.applyAOSnapshot(snapshot([exited], at: at.addingTimeInterval(1)), now: at.addingTimeInterval(1))
        let host = try XCTUnwrap(store.session(id: "ao:proj-1"))
        XCTAssertEqual(host.message, "AO 会话已退出")
        XCTAssertNil(host.taskResult)
        XCTAssertEqual(store.session(id: "ses_a")?.state, .working)
        XCTAssertEqual(store.session(id: "ses_b")?.state, .working)
    }

    func testDisconnectedCacheCannotEraseHostEvidenceWhenHookArrives() throws {
        let store = SessionStore()
        _ = store.applyAOSnapshot(snapshot([observation(status: "needs_input", activity: .waitingInput)]), now: at)
        _ = store.markAOUnavailable(now: at.addingTimeInterval(1))
        _ = store.apply(hook("ses_native", at: at.addingTimeInterval(2)), now: at.addingTimeInterval(2))
        XCTAssertNil(store.session(id: "ses_native")?.aoObservation)
        let unknown = try XCTUnwrap(store.session(id: "ao:proj-1"))
        XCTAssertFalse(try XCTUnwrap(unknown.aoObservation).available)
        XCTAssertTrue(unknown.hasUnread)
        // Only a fresh snapshot can deduplicate it, preserving the native round.
        _ = store.applyAOSnapshot(snapshot([observation(status: "needs_input", activity: .waitingInput)],
                                         at: at.addingTimeInterval(3)), now: at.addingTimeInterval(3))
        XCTAssertNil(store.session(id: "ao:proj-1"))
        XCTAssertEqual(store.session(id: "ses_native")?.aoObservation?.isWaiting, true)
        XCTAssertEqual(store.session(id: "ses_native")?.readThroughVersion, 0)
    }

    func testDaemonGenerationReobservesSameAOFactWithoutCopyingNativeReceipt() throws {
        let store = SessionStore()
        _ = store.apply(hook("ses_a"), now: at)
        _ = store.apply(hook("ses_b"), now: at)
        let waiting = observation(status: "needs_input", activity: .waitingInput)
        _ = store.applyAOSnapshot(snapshot([waiting]), now: at)
        store.markRead(id: "ao:proj-1", through: 1)
        let nextInstance = "apprun-22222222-2222-2222-2222-222222222222"
        var nextWait = waiting
        nextWait.instanceID = nextInstance
        let transitions = store.applyAOSnapshot(snapshot([nextWait], instanceID: nextInstance,
                                                        at: at.addingTimeInterval(1)), now: at.addingTimeInterval(1))
        XCTAssertNil(transitions.first?.before, "another daemon is fresh history, not a live transition")
        let host = try XCTUnwrap(store.session(id: "ao:proj-1"))
        XCTAssertEqual(host.state, .waiting)
        XCTAssertEqual(host.readThroughVersion, 0)
        XCTAssertFalse(host.hasUnread, "the same acknowledged AO source fact stays read across daemon generations")
        XCTAssertNil(store.session(id: "ses_a")?.aoBinding)
        XCTAssertNil(store.session(id: "ses_b")?.aoBinding)
        _ = store.apply(hook("ses_a", at: at.addingTimeInterval(2)), now: at.addingTimeInterval(2))
        XCTAssertNil(store.session(id: "ao:proj-1"))
        XCTAssertEqual(store.session(id: "ses_a")?.aoObservation?.instanceID, nextInstance)
        XCTAssertEqual(store.session(id: "ses_a")?.readThroughVersion, 0)
        XCTAssertNil(store.session(id: "ses_b")?.aoObservation)
    }

    func testRestoreConflictPreservesNativeUnreadAndReobservesHostWait() throws {
        let store = SessionStore()
        for id in ["ses_a", "ses_b"] {
            _ = store.apply(hook(id), now: at)
            var done = hook(id, name: "done", at: at.addingTimeInterval(1))
            done.turnResult = .completed
            _ = store.apply(done, now: at.addingTimeInterval(1))
        }
        _ = store.applyAOSnapshot(snapshot([observation(status: "needs_input", activity: .waitingInput)]), now: at)
        let restored = SessionReducer()
        restored.restore(SessionSnapshotDTO(sessions: store.sessions))
        XCTAssertNil(restored.byID["ao:proj-1"])
        for id in ["ses_a", "ses_b"] {
            XCTAssertTrue(try XCTUnwrap(restored.byID[id]).hasUnread)
            XCTAssertNil(restored.byID[id]?.aoBinding)
        }
        let transitions = restored.applyAOSnapshot(snapshot([observation(status: "needs_input", activity: .waitingInput)]), now: at)
        XCTAssertEqual(restored.byID["ao:proj-1"]?.state, .waiting)
        XCTAssertNil(transitions.first?.before)
    }

    func testBindingRetainsHostUnreadWithoutCreatingNativeNotification() throws {
        let store = SessionStore()
        _ = store.applyAOSnapshot(snapshot([observation(status: "needs_input", activity: .waitingInput)]), now: at)
        XCTAssertTrue(try XCTUnwrap(store.session(id: "ao:proj-1")).hasUnread)
        _ = store.apply(hook("ses_native"), now: at)
        let native = try XCTUnwrap(store.session(id: "ses_native"))
        XCTAssertNil(store.session(id: "ao:proj-1"))
        XCTAssertEqual(native.notificationVersion, 0)
        XCTAssertEqual(native.readThroughVersion, 0)
        XCTAssertNil(native.readAt)
        XCTAssertTrue(native.hasUnread, "deduplication must keep the independent AO unread responsibility")
    }

    func testAOReadNeverSuppressesLaterNativeUnreadAndActionsRemainSourceSpecific() throws {
        let store = SessionStore()
        for tick in 0..<8 {
            let work = observation(updatedAt: at.addingTimeInterval(Double(tick * 2)))
            _ = store.applyAOSnapshot(snapshot([work]), now: at)
            let wait = observation(status: "needs_input", activity: .waitingInput,
                                   updatedAt: at.addingTimeInterval(Double(tick * 2 + 1)))
            _ = store.applyAOSnapshot(snapshot([wait]), now: at)
        }
        let host = try XCTUnwrap(store.session(id: "ao:proj-1"))
        let receipt = try XCTUnwrap(host.aoAttentionReceipts?.first)
        XCTAssertEqual(receipt.version, 8)
        XCTAssertTrue(store.acknowledgeAO(receipt, at: at))
        _ = store.apply(hook("ses_native", at: at.addingTimeInterval(20)), now: at.addingTimeInterval(20))
        var done = hook("ses_native", name: "done", at: at.addingTimeInterval(21))
        done.turnResult = .completed
        _ = store.apply(done, now: at.addingTimeInterval(21))
        var native = try XCTUnwrap(store.session(id: "ses_native"))
        XCTAssertTrue(native.hasUnread)
        XCTAssertFalse(native.hasAOUnread)
        XCTAssertEqual(native.notificationVersion, 1)
        XCTAssertEqual(native.readThroughVersion, 0)
        let next = observation(status: "needs_input", activity: .waitingInput,
                               updatedAt: at.addingTimeInterval(30))
        _ = store.applyAOSnapshot(snapshot([next]), now: at)
        native = try XCTUnwrap(store.session(id: "ses_native"))
        XCTAssertTrue(native.hasAOUnread)
        let unreadAO = try XCTUnwrap(native.aoAttentionReceipts?.first)
        XCTAssertTrue(store.acknowledgeAO(unreadAO, at: at.addingTimeInterval(30)))
        XCTAssertFalse(try XCTUnwrap(store.session(id: native.id)).hasAOUnread)
        XCTAssertTrue(try XCTUnwrap(store.session(id: native.id)).hasUnread,
                      "acknowledging AO must not acknowledge the native completion")
        let nextWait = observation(status: "needs_input", activity: .waitingInput,
                                  updatedAt: at.addingTimeInterval(31))
        _ = store.applyAOSnapshot(snapshot([nextWait]), now: at)
        native = try XCTUnwrap(store.session(id: native.id))
        let openedAO = try XCTUnwrap(native.aoAttentionReceipts?.first)
        _ = store.markOpened(native, at: at.addingTimeInterval(31))
        XCTAssertEqual(store.session(id: native.id)?.readThroughVersion, 1)
        XCTAssertEqual(store.session(id: native.id)?.hasAOUnread, true,
                       "opening a native page proves nothing about AO's fact")
        XCTAssertTrue(store.acknowledgeAO(openedAO, at: at.addingTimeInterval(32)))
        XCTAssertFalse(try XCTUnwrap(store.session(id: native.id)).hasUnread)
        // A stale explicit AO click consumes only the older source revision.
        let later = observation(status: "needs_input", activity: .waitingInput,
                                updatedAt: at.addingTimeInterval(40))
        _ = store.applyAOSnapshot(snapshot([later]), now: at)
        XCTAssertFalse(store.acknowledgeAO(unreadAO, at: at.addingTimeInterval(41)))
        XCTAssertTrue(try XCTUnwrap(store.session(id: native.id)).hasAOUnread)
    }

    func testHostUnreadHasOneCarrierAcrossConflictReconnectAndRebinding() throws {
        let store = SessionStore()
        let waiting = observation(status: "needs_input", activity: .waitingInput)
        _ = store.applyAOSnapshot(snapshot([waiting]), now: at)
        _ = store.apply(hook("ses_a"), now: at)
        let original = try XCTUnwrap(store.session(id: "ses_a")?.aoAttentionReceipts?.first)
        XCTAssertEqual(store.sessions.filter(\.hasAOUnread).map(\.id), ["ses_a"])
        _ = store.apply(hook("ses_b"), now: at)
        XCTAssertEqual(store.sessions.filter(\.hasAOUnread).map(\.id), ["ao:proj-1"])
        _ = store.markAOUnavailable(now: at)
        _ = store.applyAOSnapshot(snapshot([waiting]), now: at)
        XCTAssertEqual(store.sessions.filter(\.hasAOUnread).count, 1)
        XCTAssertEqual(store.sessions.flatMap { $0.aoAttentionReceipts ?? [] }.filter(\.hasUnread), [original])
        _ = store.clearAOHostClaims()
        _ = store.apply(hook("ses_a"), now: at)
        XCTAssertEqual(store.sessions.filter(\.hasAOUnread).map(\.id), ["ses_a"])
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.acknowledgeAO(original, at: at))
        XCTAssertTrue(store.sessions.filter(\.hasAOUnread).isEmpty)
        XCTAssertEqual(store.session(id: "ses_a")?.readThroughVersion, 0)
    }

    func testAOReceiptsPersistOnceAndRestoreAsUnconfirmedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let store = SessionStore()
        store.persistenceURL = url
        let waiting = observation(status: "needs_input", activity: .waitingInput)
        _ = store.applyAOSnapshot(snapshot([waiting]), now: at)
        _ = store.apply(hook("ses_native"), now: at)
        store.persistCodexSessions()
        XCTAssertNil(store.flushSnapshots().error)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((object["aoAttentionRecords"] as? [Any])?.count, 1)
        XCTAssertTrue((object["sessions"] as? [[String: Any]])?.allSatisfy { $0["aoAttentionReceipts"] == nil } == true)
        let restored = SessionStore()
        restored.persistenceURL = url
        restored.restoreCodexSessions()
        XCTAssertNil(restored.session(id: "ses_native")?.aoBinding)
        XCTAssertNil(restored.session(id: "ses_native")?.aoObservation)
        let history = try XCTUnwrap(restored.sessions.first(where: \.hasAOUnread))
        XCTAssertTrue(history.isAOPlaceholder)
        XCTAssertNil(history.hostTeamScope?.role, "historical project grouping grants no live role")
        XCTAssertEqual(history.aoObservation?.available, false)
        let receipt = try XCTUnwrap(history.aoAttentionReceipts?.first)
        _ = restored.applyAOSnapshot(snapshot([waiting]), now: at)
        _ = restored.apply(hook("ses_native"), now: at)
        XCTAssertEqual(restored.sessions.filter(\.hasAOUnread).map(\.id), ["ses_native"])
        XCTAssertEqual(restored.session(id: "ses_native")?.aoAttentionReceipts?.first?.version, receipt.version)
        XCTAssertTrue(restored.acknowledgeAO(receipt, at: at))
        let again = SessionStore()
        again.persistenceURL = url
        again.restoreCodexSessions()
        _ = again.applyAOSnapshot(snapshot([waiting]), now: at)
        XCTAssertTrue(again.sessions.filter(\.hasAOUnread).isEmpty, "own acknowledged fact survives restart")
        // Old v1 snapshots without the optional extension still decode.
        var legacy = object
        legacy.removeValue(forKey: "aoAttentionRecords")
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(SessionSnapshotDTO.self, from: data)
        XCTAssertNil(decoded.aoAttentionRecords)
    }

    func testNeverWaitingAOHistoryDoesNotAccumulateAndLiveCacheRejectsOlderWaits() throws {
        let reducer = SessionReducer()
        for batch in 0..<20 {
            let rows = (0..<200).map { index in
                observation("proj-\(batch * 200 + index)", status: "idle", activity: .idle,
                            updatedAt: at.addingTimeInterval(20))
            }
            _ = reducer.applyAOSnapshot(snapshot(rows), now: at)
            XCTAssertTrue(reducer.aoAttentionRecords.isEmpty,
                          "never-waiting sessions must not become permanent receipt history")
            XCTAssertEqual(reducer.aoSessions.count, 200)
        }
        let latest = observation("proj-live", updatedAt: at.addingTimeInterval(20))
        _ = reducer.applyAOSnapshot(snapshot([latest]), now: at)
        let staleWait = observation("proj-live", status: "needs_input", activity: .waitingInput,
                                    updatedAt: at.addingTimeInterval(10))
        _ = reducer.applyAOSnapshot(snapshot([staleWait]), now: at)
        XCTAssertTrue(reducer.aoAttentionRecords.isEmpty)
        XCTAssertEqual(reducer.aoSessions["proj-live"]?.updatedAt, latest.updatedAt)
        reducer.persistCodexSessions()
        guard case .saveSnapshot(let saved) = reducer.effects.last else { return XCTFail("missing snapshot") }
        XCTAssertTrue(saved.aoAttentionRecords?.isEmpty == true)
        let freshWait = observation("proj-live", status: "needs_input", activity: .waitingInput,
                                   updatedAt: at.addingTimeInterval(30))
        _ = reducer.applyAOSnapshot(snapshot([freshWait]), now: at)
        XCTAssertEqual(reducer.aoAttentionRecords.values.first?.version, 1)
        XCTAssertEqual(reducer.aoAttentionRecords.values.first?.hasUnread, true)
    }

    func testLegacyVersionZeroCompactionPreservesUnreadAndAcknowledgedWatermarks() throws {
        let reducer = SessionReducer()
        let waiting = [observation("proj-unread", status: "needs_input", activity: .waitingInput),
                       observation("proj-read", status: "needs_input", activity: .waitingInput)]
        _ = reducer.applyAOSnapshot(snapshot(waiting), now: at)
        let readID = AOAttentionReceipt.sourceID(for: waiting[1])
        let clicked = try XCTUnwrap(reducer.aoAttentionRecords[readID])
        XCTAssertTrue(reducer.acknowledgeAO(clicked, at: at.addingTimeInterval(1)))
        let receipts = reducer.aoAttentionRecords
        let zeroHistory = (0..<200).map { index in
            let fact = observation("proj-never-\(index)", status: "idle", activity: .idle)
            return AOAttentionReceipt(observation: fact, version: 0, readThroughVersion: 0,
                readAt: nil, waitingAt: nil, instanceID: instance, lastWasWaiting: false,
                latestUpdatedAt: at)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        let repository = SessionRepository(); repository.url = file
        repository.save(SessionSnapshotDTO(sessions: [], aoAttentionRecords: Array(receipts.values) + zeroHistory))
        XCTAssertTrue(repository.flush().isFlushed)
        let restored = SessionStore(); restored.persistenceURL = file
        restored.restoreCodexSessions()
        XCTAssertTrue(restored.flushSnapshots().isFlushed)
        let compacted = try JSONDecoder().decode(SessionSnapshotDTO.self, from: Data(contentsOf: file))
        XCTAssertEqual(compacted.aoAttentionRecords?.count, 2)
        XCTAssertEqual(compacted.aoAttentionRecords?.first(where: { $0.id == readID })?.readThroughVersion, 1)
        XCTAssertEqual(restored.sessions.filter(\.hasAOUnread).count, 1)
        let again = SessionStore(); again.persistenceURL = file; again.restoreCodexSessions()
        _ = again.applyAOSnapshot(snapshot(waiting), now: at)
        XCTAssertEqual(again.sessions.filter(\.hasAOUnread).map(\.id), ["ao:proj-unread"])
        XCTAssertEqual(again.session(id: "ao:proj-read")?.aoAttentionReceipts?.first?.version, 1)
        XCTAssertEqual(again.session(id: "ao:proj-read")?.aoAttentionReceipts?.first?.readThroughVersion, 1)
        let newerWork = waiting.map { fact -> AOHostObservation in
            var value = fact; value.activity = .active; value.status = "working"
            value.updatedAt = at.addingTimeInterval(20); value.activityAt = value.updatedAt
            return value
        }
        _ = again.applyAOSnapshot(snapshot(newerWork), now: at)
        _ = again.applyAOSnapshot(snapshot([]), now: at)
        _ = again.applyAOSnapshot(snapshot(waiting), now: at)
        XCTAssertEqual(again.sessions.filter(\.hasAOUnread).count, 1)
        XCTAssertEqual(again.session(id: "ao:proj-read")?.aoAttentionReceipts?.first?.version, 1,
                       "old snapshots cannot recreate an acknowledged wait after compaction")
        XCTAssertFalse(again.acknowledgeAO(clicked, at: at.addingTimeInterval(30)))
    }

    func testHostUnreadSurvivesMissingSnapshotAndDaemonChangeWithoutRoleRevival() throws {
        let store = SessionStore()
        let waiting = observation(status: "needs_input", activity: .waitingInput)
        _ = store.applyAOSnapshot(snapshot([waiting]), now: at)
        let original = try XCTUnwrap(store.session(id: "ao:proj-1")?.aoAttentionReceipts?.first)
        _ = store.applyAOSnapshot(snapshot([]), now: at)
        let history = try XCTUnwrap(store.sessions.first(where: \.hasAOUnread))
        XCTAssertEqual(history.aoObservation?.available, false)
        XCTAssertNil(history.hostTeamScope?.role, "historical project grouping grants no live role")
        var next = waiting
        next.instanceID = "apprun-22222222-2222-2222-2222-222222222222"
        _ = store.applyAOSnapshot(snapshot([next], instanceID: next.instanceID), now: at)
        XCTAssertEqual(store.sessions.filter(\.hasAOUnread).count, 1)
        XCTAssertEqual(store.sessions.first(where: \.hasAOUnread)?.aoAttentionReceipts?.first?.version, original.version,
                       "same durable AO fact is not a second unread obligation")
        XCTAssertTrue(store.acknowledgeAO(original, at: at))
        var newTask = next
        newTask.createdAt = at.addingTimeInterval(1)
        newTask.updatedAt = at.addingTimeInterval(1)
        _ = store.applyAOSnapshot(snapshot([newTask], instanceID: next.instanceID), now: at)
        XCTAssertTrue(try XCTUnwrap(store.sessions.first(where: \.hasAOUnread)).hasAOUnread,
                      "reused session ID with a different creation identity cannot inherit a receipt")
    }

    func testAOUnreadKeepsOriginalFactWhenHostResumesAndOldSnapshotsRepeat() throws {
        let store = SessionStore()
        let waiting = observation(status: "needs_input", activity: .waitingInput)
        _ = store.applyAOSnapshot(snapshot([waiting]), now: at)
        let original = try XCTUnwrap(store.session(id: "ao:proj-1")?.aoAttentionReceipts?.first)
        let work = observation(updatedAt: at.addingTimeInterval(1))
        _ = store.applyAOSnapshot(snapshot([work]), now: at)
        let current = try XCTUnwrap(store.session(id: "ao:proj-1"))
        XCTAssertEqual(current.state, .working)
        XCTAssertTrue(current.hasAOUnread)
        XCTAssertEqual(current.aoAttentionReceipts?.first?.observation.isWaiting, true)
        XCTAssertEqual(current.aoAttentionReceipts?.first?.version, original.version)
        _ = store.applyAOSnapshot(snapshot([waiting]), now: at)
        XCTAssertEqual(store.session(id: current.id)?.aoAttentionReceipts?.first?.version, original.version)
    }

    func testAutomaticallyHiddenNativeRowCannotOwnVisibleAOUnread() throws {
        for hidden in ["internal", "unidentified", "nested"] {
            let kind: AgentKind = hidden == "nested" ? .opencode : .codex
            let reducer = SessionReducer()
            _ = reducer.apply(hook("native", kind: kind), now: at)
            let waiting = observation(harness: kind == .codex ? "codex" : "opencode-v2",
                                      status: "needs_input", activity: .waitingInput)
            _ = reducer.applyAOSnapshot(snapshot([waiting]), now: at)
            reducer.projectAOAttention()
            XCTAssertTrue(try XCTUnwrap(reducer.byID["native"]).hasAOUnread)
            if hidden == "internal" {
                reducer.byID["native"]?.codexInternalTaskKind = "aionUiTitle"
                reducer.byID["native"]?.codexInternalTaskObservedAt = at.addingTimeInterval(1)
            } else if hidden == "unidentified" {
                reducer.byID["native"]?.state = .done
            } else {
                reducer.byID["native"]?.opencodeParentSessionID = "ses_parent"
            }
            let native = try XCTUnwrap(reducer.byID["native"])
            XCTAssertTrue(native.isCodexInternalTask || native.isUnidentifiedCodexCompletion || native.isOpencodeSubagent)
            reducer.projectAOAttention()
            XCTAssertFalse(try XCTUnwrap(reducer.byID["native"]).hasAOUnread)
            let carrier = try XCTUnwrap(reducer.sessions.first(where: \.hasAOUnread))
            XCTAssertTrue(carrier.isAOPlaceholder)
            XCTAssertEqual(reducer.sessions.filter(\.hasAOUnread).count, 1)
        }
    }

    /// Opt-in, read-only observation of the normally running AO session. This
    /// never starts a model task, writes AO state, or touches its database.
    func testLiveAOReadOnlySnapshotWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPET_AO_LIVE_TEST"] == "1" else {
            throw XCTSkip("set AGENTPET_AO_LIVE_TEST=1 to inspect the local AO daemon")
        }
        guard let run = AORunFile.read() else { throw XCTSkip("AO is not running") }
        let loaded = await AOAPIClient().load(run, now: Date())
        let snapshot = try XCTUnwrap(loaded)
        XCTAssertEqual(snapshot.instanceID, run.appRunID)
        XCTAssertFalse(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.sessions.allSatisfy { AOHostObservation.validID($0.sessionID) })
        XCTAssertTrue(snapshot.sessions.contains { $0.sessionID == "agentpet-lite-8" })
        XCTAssertTrue(snapshot.sessions.allSatisfy { $0.orchestration?.orchestratorSessionID == nil })
        for row in snapshot.sessions where row.projectID != AOHostMapping.standaloneProjectID {
            XCTAssertEqual(row.orchestration?.teamID, row.projectID)
        }
    }

}
