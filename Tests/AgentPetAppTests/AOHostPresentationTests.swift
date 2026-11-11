import XCTest
import AgentPetCore
@testable import agentpet

final class AOHostPresentationTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 100)
    private let instance = "apprun-33333333-3333-3333-3333-333333333333"

    private func aoSession(
        _ id: String, state: AgentState, role: AOHostTeamRole?,
        hostRole: AOHostRole? = nil, nativeID: String? = nil,
        kind: AgentKind = .codex, title: String? = nil,
        status: String = "working", activity: AOHostActivity = .active,
        result: CodexTurnResult? = nil, terminated: Bool = false,
        updatedAt: Date? = nil, observedAt: Date? = nil,
        available: Bool = true, teamID: String = "orch-1",
        teamName: String = "AgentPet Team"
    ) -> AgentSession {
        let resolvedHostRole: AOHostRole = hostRole ?? (role == .lead ? .orchestrator : .worker)
        let orchestration = role.map {
            AOOrchestration(teamID: teamID, teamName: teamName, role: $0,
                            orchestratorSessionID: teamID)
        }
        let timestamp = updatedAt ?? at
        let observation = AOHostObservation(
            sessionID: id, projectID: "proj", projectName: "AgentPet", role: resolvedHostRole,
            harness: kind == .opencode ? "opencode-v2" : kind == .pi ? "pi" : "codex",
            displayName: title ?? (role == .lead ? "Leader" : "Worker"),
            branch: "ao/test", status: status, displayStatus: nil,
            activity: activity, activityAt: timestamp, isTerminated: terminated,
            createdAt: at, updatedAt: timestamp, lastEventAt: timestamp,
            observedAt: observedAt ?? at, instanceID: instance, available: available,
            orchestration: orchestration)
        var session = AgentSession(id: nativeID ?? ("native-" + id), agentKind: kind,
                                   title: title ?? (role == .lead ? "Leader" : "Worker"),
                                   state: state, message: "native message",
                                   model: "deepseek-v4.1-flash", source: .hook,
                                   updatedAt: timestamp, stateSince: timestamp, createdAt: at)
        session.aoBinding = AOBinding(sessionID: id, projectID: "proj", agentKind: kind,
                                      origin: .hookEnvironment, boundAt: at)
        session.aoObservation = observation
        session.codexTurnResult = result
        if state == .waiting || result != nil { session.notificationVersion = 1 }
        return session
    }

    private func plain(_ id: String, state: AgentState = .working) -> AgentSession {
        AgentSession(id: id, agentKind: .claude, state: state, source: .hook, updatedAt: at)
    }

    private func projectSnapshot(_ rows: [(String, String?, String, String, String, String)]) throws -> AOSnapshot {
        let sessions: [[String: Any]] = rows.map { id, project, role, harness, status, activity in
            var row: [String: Any] = ["id": id, "kind": role, "harness": harness,
                "status": status, "isTerminated": false,
                "createdAt": "1970-01-01T00:01:40Z", "updatedAt": "1970-01-01T00:01:40Z",
                "activity": ["state": activity, "lastActivityAt": "1970-01-01T00:01:40Z"]]
            if let project { row["projectId"] = project }
            return row
        }
        let projects = ["projects": [["id": "proj", "name": "AgentPet"],
                                      ["id": "other", "name": "Other project"]]]
        return try XCTUnwrap(AOSnapshotParser.parse(
            sessionsData: JSONSerialization.data(withJSONObject: ["sessions": sessions]),
            projectsData: JSONSerialization.data(withJSONObject: projects),
            run: AORunFile(port: 1, pid: 42, appRunID: instance), observedAt: at))
    }

    func testProductionProjectsCollapseAcrossHarnessesWhileStandaloneStaysSeparate() throws {
        let snapshot = try projectSnapshot([
            ("lead", "proj", "orchestrator", "codex", "idle", "idle"),
            ("second-lead", "proj", "orchestrator", "codex", "idle", "idle"),
            ("worker-code", "proj", "worker", "opencode-v2", "working", "active"),
            ("worker-pi", "proj", "worker", "pi", "working", "active"),
            ("other-worker", "other", "worker", "codex", "working", "active"),
            ("standalone", nil, "worker", "pi", "working", "active")])
        let store = SessionStore()
        _ = store.applyAOSnapshot(snapshot, now: at)
        let groups = BubblePresentation.groups(store.sessions + [plain("native")], settings: .init(now: at))
        XCTAssertEqual(groups.count, 4, "one row per project, plus standalone AO and ordinary native")
        let project = try XCTUnwrap(groups.first { $0.team?.id == "proj" })
        XCTAssertEqual(groups.filter { $0.team?.id == "proj" }.count, 1)
        XCTAssertEqual(project.team?.name, "AgentPet")
        XCTAssertEqual(project.session.aoObservation?.role, .orchestrator, "retain an idle project representative")
        XCTAssertEqual(project.team?.membersWorking, true)
        XCTAssertEqual(BubblePresentation.Row(session: project.session, team: project.team).lamp, .running)
        XCTAssertEqual(groups.filter { $0.team?.id == "other" }.count, 1)
        XCTAssertTrue(groups.contains { $0.session.aoObservation?.sessionID == "standalone" && $0.team == nil })
        XCTAssertEqual(BubblePresentation.groups(store.sessions, settings: .init(now: at), expanded: true)
            .filter { $0.team?.id == "proj" }.count, 1, "expanding keeps the existing one-project summary contract")
        let reversed = BubblePresentation.groups(Array(store.sessions.reversed()), settings: .init(now: at))
        XCTAssertEqual(reversed.first { $0.team?.id == "proj" }?.session.id, project.session.id,
                       "multiple project orchestrators must have a deterministic display representative")
    }

    func testProjectPrimaryOpensLeaderAndUnreadControlTargetsOneMember() throws {
        var lead = aoSession("leader", state: .idle, role: .lead, status: "idle", activity: .idle, result: .completed, teamID: "proj")
        lead.readThroughVersion = lead.notificationVersion; lead.readAt = at
        var older = aoSession("older", state: .done, role: .teammate, kind: .opencode, result: .completed, teamID: "proj")
        older.opencodeTurnResult = .completed; older.turnEndedAt = at.addingTimeInterval(-1)
        var newer = aoSession("newer", state: .done, role: .teammate, result: .completed, teamID: "proj")
        newer.turnEndedAt = at
        let configuration = BubblePresentation.Configuration(now: at)
        let group = try XCTUnwrap(BubblePresentation.groups([older, newer, lead], settings: configuration).first)
        XCTAssertEqual(group.session.id, lead.id, "keep the leader's status/model/timer carrier")
        XCTAssertEqual(group.team?.unreadNavigationSession?.id, newer.id)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.navigationSessionID, lead.id)
        XCTAssertTrue(row.isAOProjectEntry)
        XCTAssertEqual(row.unreadNavigationSessionID, newer.id)
        XCTAssertEqual(row.unreadNativeCount, 2)
        newer.readThroughVersion = newer.notificationVersion; newer.readAt = at
        let next = try XCTUnwrap(BubblePresentation.groups([newer, lead, older], settings: configuration).first)
        XCTAssertEqual(next.team?.unreadNavigationSession?.id, older.id)
        XCTAssertEqual(next.team?.unreadNativeCount, 1)
        XCTAssertEqual(BubblePresentation.Row(session: next.session, team: next.team).navigationSessionID, lead.id)
        older.readThroughVersion = older.notificationVersion; older.readAt = at
        let read = try XCTUnwrap(BubblePresentation.groups([older, newer, lead], settings: configuration).first)
        XCTAssertNil(read.team?.unreadNavigationSession)
        XCTAssertEqual(read.team?.unreadNativeCount, 0)
        XCTAssertEqual(BubblePresentation.Row(session: read.session, team: read.team).navigationSessionID, lead.id)
        newer.readThroughVersion = 0; newer.aoObservation?.observedAt = at.addingTimeInterval(-61)
        let stale = try XCTUnwrap(BubblePresentation.groups([newer, lead], settings: configuration).first)
        XCTAssertNil(stale.team?.unreadNavigationSession, "stale member identity cannot become a precise click target")
        XCTAssertEqual(stale.team?.unreadNativeCount, 1, "unconfirmed results remain visible but the precise unread control is disabled")
    }

    func testUnreadProjectControlRemainsClickableWithClickThroughEnabled() throws {
        var lead = aoSession("leader", state: .idle, role: .lead, status: "idle", activity: .idle, result: .completed, teamID: "proj")
        lead.readThroughVersion = lead.notificationVersion; lead.readAt = at
        var worker = aoSession("worker", state: .done, role: .teammate, result: .completed, teamID: "proj")
        let configuration = BubblePresentation.Configuration(now: at)
        let unread = try XCTUnwrap(BubblePresentation.groups([lead, worker], settings: configuration).first)
        let row = BubblePresentation.Row(session: unread.session, team: unread.team)
        XCTAssertEqual(row.unreadNativeCount, 1)
        XCTAssertTrue(row.requiresManualHandling, "an explicit unread control must not pass its clicks to another application")
        XCTAssertEqual(TaskBubbleClickThroughPolicy.status(preferenceEnabled: true, bubbleVisible: true,
            requiresManualHandling: row.requiresManualHandling), .suspended)
        worker.readThroughVersion = worker.notificationVersion; worker.readAt = at
        let read = try XCTUnwrap(BubblePresentation.groups([lead, worker], settings: configuration).first)
        XCTAssertEqual(read.team?.unreadNativeCount, 0)
        XCTAssertFalse(BubblePresentation.Row(session: read.session, team: read.team).requiresManualHandling)
    }

    func testPiSessionFileHooksCollapseIntoProjectWithoutHidingStandalonePi() throws {
        let store = SessionStore()
        _ = store.applyAOSnapshot(try projectSnapshot([
            ("lead", "proj", "orchestrator", "codex", "idle", "idle"),
            ("worker-pi-1", "proj", "worker", "pi", "idle", "idle"),
            ("worker-pi-2", "proj", "worker", "pi", "idle", "idle")]), now: at)
        let base = "pi:/Users/test/.pi/agent/sessions/--Users-test-project-agentpet-lite--/"
        for (index, worker) in ["worker-pi-1", "worker-pi-2"].enumerated() {
            // Same shape as the installed Pi extension, including a session ID
            // longer than AO's 160-character object ID limit.
            let id = base + String(repeating: "a", count: 80) + "-\(index).jsonl"
            let body: [String: Any] = ["session_id": id, "cwd": "/Users/test/project",
                "hook_event_name": "working"]
            var event = try XCTUnwrap(HookPayload.event(forAgent: .pi,
                stdin: JSONSerialization.data(withJSONObject: body), now: at))
            let identity = try XCTUnwrap(AOHostEnvironment.capture([
                "AO_SESSION_ID": worker, "AO_PROJECT_ID": "proj"]))
            event.aoSessionID = identity.sessionID; event.aoProjectID = identity.projectID
            _ = try XCTUnwrap(store.apply(event, now: at))
            event.eventName = "done"; event.turnResult = .completed
            event.timestamp = at.addingTimeInterval(1)
            _ = try XCTUnwrap(store.apply(event, now: event.timestamp))
            let native = try XCTUnwrap(store.session(id: id))
            XCTAssertEqual(native.aoBinding?.sessionID, worker)
            XCTAssertEqual(native.hostTeamScope?.teamID, "proj")
            XCTAssertEqual(native.taskResult, .completed)
            XCTAssertEqual(native.readThroughVersion, 0)
            XCTAssertNil(store.session(id: "ao:" + worker))
        }
        let standaloneID = base + "standalone.jsonl"
        _ = store.apply(AgentEvent(sessionId: standaloneID, agentKind: .pi,
            eventName: "working", timestamp: at), now: at)
        let groups = BubblePresentation.groups(store.sessions, settings: .init(now: at))
        XCTAssertEqual(groups.count, 2, "one AO project bubble and the independent Pi session")
        XCTAssertEqual(groups.filter { $0.team?.id == "proj" }.count, 1)
        XCTAssertEqual(groups.filter { $0.team == nil }.map { $0.session.id }, [standaloneID])
    }

    func testIdleAOProjectRetainsUnreadThenExpiresAfterReadingAndPollingCannotReviveIt() throws {
        var lead = aoSession("lead", state: .done, role: .lead,
            status: "idle", activity: .idle, result: .completed)
        var worker = aoSession("pi-worker", state: .done, role: .teammate,
            kind: .pi, status: "idle", activity: .idle, result: .completed)
        lead.turnEndedAt = at; worker.turnEndedAt = at; worker.piTurnResult = .completed
        XCTAssertEqual(BubblePresentation.groups([lead, worker], settings: .init(now: at.addingTimeInterval(10))).count, 1,
                       "Course's completed unread replies must not disappear after three seconds")
        XCTAssertNil(BubblePresentation.nextReadResultDeadline([lead, worker], retention: .forever, now: at))
        lead.readThroughVersion = lead.notificationVersion; worker.readThroughVersion = worker.notificationVersion
        lead.readAt = at.addingTimeInterval(10); worker.readAt = lead.readAt
        XCTAssertEqual(BubblePresentation.groups([lead, worker], settings: .init(now: at.addingTimeInterval(12.999), readResultRetention: .threeSeconds)).count, 1)
        XCTAssertTrue(BubblePresentation.groups([lead, worker], settings: .init(now: at.addingTimeInterval(13), readResultRetention: .threeSeconds)).isEmpty)
        XCTAssertNil(BubblePresentation.nextReadResultDeadline([lead, worker], retention: .forever, now: at.addingTimeInterval(10)))
        XCTAssertEqual(BubblePresentation.groups([lead, worker], settings: .init(now: at.addingTimeInterval(20), readResultRetention: .forever)).count, 1)
        lead.aoObservation?.observedAt = at.addingTimeInterval(20)
        worker.aoObservation?.observedAt = at.addingTimeInterval(20)
        XCTAssertTrue(BubblePresentation.groups([lead, worker], settings: .init(now: at.addingTimeInterval(20), readResultRetention: .threeSeconds)).isEmpty)
        worker.notificationVersion += 1
        XCTAssertEqual(BubblePresentation.groups([lead, worker], settings: .init(now: at.addingTimeInterval(20), readResultRetention: .threeSeconds)).count, 1,
                       "a second completed reply creates a new unread obligation even after the first was read")
    }

    func testCourseUnreadCompletionStaysLitUntilItsExactResultIsRead() throws {
        var lead = aoSession("course-1", state: .done, role: .lead,
            status: "idle", activity: .idle, result: .completed)
        lead.notificationVersion = 3; lead.readThroughVersion = 2
        func row(_ sessions: [AgentSession]) throws -> BubblePresentation.Row {
            let group = try XCTUnwrap(BubblePresentation.groups(sessions,
                settings: .init(now: at.addingTimeInterval(30), readResultRetention: .forever)).first)
            return .init(session: group.session, team: group.team)
        }
        let unread = try row([lead])
        XCTAssertEqual(unread.stateLabel, "回合已完成，未读")
        XCTAssertEqual(unread.lamp, .success)
        XCTAssertTrue(unread.dotIsLit)
        XCTAssertEqual(lead.readThroughVersion, 2, "displaying idle host metadata never acknowledges the result")
        lead.readThroughVersion = 3; lead.readAt = at
        XCTAssertEqual(try row([lead]).lamp, .off)
        XCTAssertEqual(try row([lead]).stateLabel, "空闲")

        var worker = aoSession("worker", state: .done, role: .teammate,
            status: "idle", activity: .idle, result: .completed)
        XCTAssertEqual(try row([lead, worker]).lamp, .success,
                       "reading the lead cannot dim another member's completed unread reply")
        XCTAssertEqual(try row([worker]).stateLabel, "回合已完成，未读",
                       "a missing leader does not erase an exact member completion")
        worker.codexTurnResult = nil
        XCTAssertEqual(try row([worker]).lamp, .unknown, "unknown completion must never be green or grey")
        worker.state = .working; worker.aoObservation?.activity = .active
        XCTAssertEqual(try row([lead, worker]).lamp, .running, "current execution retains priority")
        worker.state = .waiting; worker.aoObservation?.activity = .waitingInput
        XCTAssertEqual(try row([lead, worker]).lamp, .attention, "waiting retains priority")
    }

    func testRecoveredNativeIdentityUsesProjectIdleExpiryWithoutLosingUnread() throws {
        let store = SessionStore()
        let nativeID = "11111111-1111-4111-8111-111111111111"
        var event = AgentEvent(sessionId: nativeID, agentKind: .codex, eventName: "Stop", timestamp: at)
        event.turnResult = .completed
        _ = store.apply(event, now: at)
        let original = try XCTUnwrap(store.session(id: nativeID))
        var fresh = try projectSnapshot([("lead", "proj", "orchestrator", "codex", "idle", "idle")])
        fresh.nativeIdentities = [.init(sessionID: "lead", nativeSessionID: nativeID, agentKind: .codex)]
        _ = store.applyAOSnapshot(fresh, now: at)
        let recovered = try XCTUnwrap(store.session(id: nativeID))
        let groups = BubblePresentation.groups(store.sessions, settings: .init(now: at.addingTimeInterval(2)))
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.team?.id, "proj")
        XCTAssertTrue(BubblePresentation.Row(session: group.session, team: group.team).canFocusTerminal,
                      "recovered project must navigate even without a native terminal target")
        XCTAssertEqual(BubblePresentation.groups(store.sessions, settings: .init(now: at.addingTimeInterval(10))).count, 1)
        XCTAssertEqual(recovered.notificationVersion, original.notificationVersion)
        XCTAssertEqual(recovered.readThroughVersion, original.readThroughVersion)
        XCTAssertEqual(recovered.taskResult, original.taskResult)
        XCTAssertTrue(recovered.hasUnread)
    }

    func testExitedProjectKeepsNativeFailureAndManualHandlingWithoutLiveRoles() throws {
        let completed = aoSession("completed", state: .done, role: .teammate,
            status: "terminated", activity: .exited, result: .completed, terminated: true)
        let failed = aoSession("failed", state: .done, role: .teammate,
            status: "terminated", activity: .exited, result: .failed, terminated: true)
        XCTAssertNil(failed.hostTeamScope?.role)
        let group = try XCTUnwrap(BubblePresentation.groups([completed, failed], settings: .init(now: at.addingTimeInterval(10))).first)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.stateLabel, "失败")
        XCTAssertEqual(row.lamp, .failure)
        XCTAssertTrue(row.requiresManualHandling)
        XCTAssertTrue(failed.hasUnread)
        XCTAssertEqual(failed.readThroughVersion, 0)
    }

    func testExitedCompletedProjectExpiresButUnknownAndHumanObligationsRemain() throws {
        var completed = aoSession("completed", state: .done, role: .teammate,
            status: "terminated", activity: .exited, result: .completed, terminated: true)
        completed.turnEndedAt = at
        XCTAssertEqual(BubblePresentation.groups([completed], settings: .init(now: at.addingTimeInterval(10))).count, 1)
        XCTAssertTrue(completed.hasUnread)
        let unreadCompleted = completed
        completed.readThroughVersion = completed.notificationVersion; completed.readAt = at
        XCTAssertTrue(BubblePresentation.groups([completed], settings: .init(now: at.addingTimeInterval(3), readResultRetention: .threeSeconds)).isEmpty)
        var unknown = unreadCompleted; unknown.codexTurnResult = nil
        XCTAssertEqual(BubblePresentation.groups([unknown], settings: .init(now: at.addingTimeInterval(10))).count, 1)
        var human = unreadCompleted; human.humanRequests = [.init(id: "question", kind: .reply, createdAt: at)]
        let group = try XCTUnwrap(BubblePresentation.groups([human], settings: .init(now: at.addingTimeInterval(10))).first)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.stateLabel, "等待中")
        XCTAssertTrue(row.requiresManualHandling)
        var unavailable = unreadCompleted; unavailable.aoObservation?.available = false
        XCTAssertEqual(BubblePresentation.groups([unavailable], settings: .init(now: at.addingTimeInterval(10))).count, 1)
    }

    func testIdleAOExpiryProtectsWaitingHumanRequestsAndUnconfirmedActivity() throws {
        var lead = aoSession("lead", state: .done, role: .lead,
            status: "idle", activity: .idle, result: .completed)
        lead.readThroughVersion = lead.notificationVersion; lead.readAt = at
        let now = at.addingTimeInterval(10)
        var idle = aoSession("worker", state: .idle, role: .teammate,
            kind: .pi, status: "idle", activity: .idle)
        idle.readThroughVersion = idle.notificationVersion; idle.readAt = at
        XCTAssertTrue(BubblePresentation.groups([lead, idle], settings: .init(now: now)).isEmpty)
        var waiting = idle; waiting.state = .waiting
        var human = idle; human.humanRequests = [.init(id: "question", kind: .reply, createdAt: at)]
        var hostWait = idle; hostWait.aoObservation?.activity = .waitingInput
        var unknown = idle; unknown.aoObservation?.activity = .unknown; unknown.aoObservation?.status = "no_signal"
        var unavailable = idle; unavailable.aoObservation?.available = false
        var failed = idle; failed.state = .done; failed.piTurnResult = .failed
        var approval = idle; approval.pendingApproval = .init(requestId: "approval", toolName: "test", summary: "fixture")
        for var protected in [waiting, human, hostWait, unknown, unavailable, failed, approval] {
            protected.readThroughVersion = 0 // retain the original unread-obligation fixture
            XCTAssertEqual(BubblePresentation.groups([lead, protected], settings: .init(now: now)).count, 1)
            XCTAssertNil(BubblePresentation.nextReadResultDeadline([lead, protected], retention: .forever, now: at))
        }
        let standalone = AgentSession(id: "plain-pi", agentKind: .pi, state: .idle, source: .hook, updatedAt: at)
        XCTAssertEqual(BubblePresentation.groups([standalone], settings: .init(now: now)).count, 1,
                       "ordinary Pi visibility is unchanged")
    }

    func testCompletedWorkerRetainsKnownIdleOrchestratorAndHidesTitleHelper() throws {
        let store = SessionStore()
        var native = AgentEvent(sessionId: "native-worker", agentKind: .opencode,
            eventName: "working", timestamp: at)
        native.aoSessionID = "worker"; native.aoProjectID = "proj"
        _ = store.apply(native, now: at)
        native.eventName = "done"; native.turnResult = .completed
        native.timestamp = at.addingTimeInterval(1)
        _ = store.apply(native, now: at)
        _ = store.applyAOSnapshot(try projectSnapshot([
            ("lead", "proj", "orchestrator", "codex", "idle", "idle"),
            ("worker", "proj", "worker", "opencode-v2", "idle", "idle")]), now: at)
        let helper = AgentSession(id: "title-helper", agentKind: .opencode,
            project: NSHomeDirectory() + "/.ao/data/background-tasks/title-123",
            title: "R5 jump testing", state: .done, source: .hook, updatedAt: at)
        let groups = BubblePresentation.groups(store.sessions + [helper], settings: .init(now: at))
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first { $0.team?.id == "proj" })
        XCTAssertEqual(group.session.aoObservation?.role, .orchestrator)
        XCTAssertEqual(group.team?.leaderMissing, false)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.stateLabel, "回合已完成，未读")
        XCTAssertEqual(row.messageText, "回合已完成，未读")
        XCTAssertEqual(row.lamp, .success)
        XCTAssertEqual(store.session(id: "native-worker")?.taskResult, .completed)
        XCTAssertEqual(store.session(id: "native-worker")?.readThroughVersion, 0)
        _ = store.applyAOSnapshot(try projectSnapshot([
            ("worker", "proj", "worker", "opencode-v2", "idle", "idle")]), now: at)
        let workerOnly = try XCTUnwrap(BubblePresentation.groups(store.sessions, settings: .init(now: at)).first)
        XCTAssertEqual(workerOnly.team?.leaderMissing, true)
        XCTAssertEqual(BubblePresentation.Row(session: workerOnly.session, team: workerOnly.team).stateLabel, "回合已完成，未读",
                       "an exact unread native completion does not need a leader hook or a current orchestrator")
    }

    func testProjectWithWorkingMemberUsesProjectActivityWithoutUnknownLeaderCopy() throws {
        let store = SessionStore()
        _ = store.applyAOSnapshot(try projectSnapshot([
            ("worker", "proj", "worker", "pi", "working", "active")]), now: at)
        let group = try XCTUnwrap(BubblePresentation.groups(store.sessions, settings: .init(now: at)).first)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.stateLabel, "工作中")
        XCTAssertEqual(row.messageText, "工作中")
        XCTAssertEqual(row.lamp, .running)
        _ = store.markAOUnavailable(now: at.addingTimeInterval(1))
        let unavailable = try XCTUnwrap(BubblePresentation.groups(store.sessions,
            settings: .init(now: at.addingTimeInterval(1))).first)
        let missing = BubblePresentation.Row(session: unavailable.session, team: unavailable.team)
        XCTAssertEqual(missing.stateLabel, "等待状态更新")
        XCTAssertNotEqual(missing.lamp, .success)
    }

    func testProductionProjectWaitSurvivesNativeCompletionAndAcknowledgement() throws {
        let store = SessionStore()
        var native = AgentEvent(sessionId: "native-worker", agentKind: .opencode,
                                eventName: "working", timestamp: at)
        native.aoSessionID = "worker"; native.aoProjectID = "proj"
        _ = store.apply(native, now: at)
        native.eventName = "done"; native.turnResult = .completed
        native.timestamp = at.addingTimeInterval(1)
        _ = store.apply(native, now: native.timestamp)
        XCTAssertEqual(store.session(id: "native-worker")?.taskResult, .completed)
        let snapshot = try projectSnapshot([
            ("lead", "proj", "orchestrator", "codex", "idle", "idle"),
            ("worker", "proj", "worker", "opencode-v2", "needs_input", "waiting_input")])
        _ = store.applyAOSnapshot(snapshot, now: at)
        let groups = BubblePresentation.groups(store.sessions, settings: .init(now: at))
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first { $0.team?.id == "proj" })
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.lamp, .attention)
        XCTAssertTrue(row.isWaitingDisplay)
        XCTAssertTrue(row.requiresManualHandling)
        let worker = try XCTUnwrap(store.session(id: "native-worker"))
        XCTAssertEqual(row.aoAttentionReceipts.filter(\.hasUnread).count, 1)
        XCTAssertTrue(group.session.aoAttentionReceipts?.isEmpty != false,
                      "project receipts are projected separately from the representative's native row")
        XCTAssertEqual(worker.taskResult, .completed, "host projection must not rewrite the native outcome")
        let receipt = try XCTUnwrap(worker.aoAttentionReceipts?.first)
        XCTAssertTrue(store.acknowledgeAO(receipt, at: at))
        let after = try XCTUnwrap(BubblePresentation.groups(store.sessions, settings: .init(now: at)).first)
        XCTAssertTrue(BubblePresentation.Row(session: after.session, team: after.team).isWaitingDisplay,
                      "acknowledging the fact cannot resolve a live member wait")
        XCTAssertFalse(store.session(id: "native-worker")!.hasAOUnread)
    }

    func testProductionProjectDisconnectRetainsUnreadWithoutCurrentRoles() throws {
        let store = SessionStore()
        _ = store.applyAOSnapshot(try projectSnapshot([
            ("lead", "proj", "orchestrator", "codex", "idle", "idle"),
            ("one", "proj", "worker", "pi", "needs_input", "waiting_input"),
            ("two", "proj", "worker", "codex", "needs_input", "waiting_input")]), now: at)
        _ = store.markAOUnavailable(now: at.addingTimeInterval(1))
        let groups = BubblePresentation.groups(store.sessions, settings: .init(now: at.addingTimeInterval(1)))
        XCTAssertEqual(groups.count, 1)
        let project = try XCTUnwrap(groups.first { $0.team?.id == "proj" })
        XCTAssertEqual(project.team?.leaderMissing, true)
        XCTAssertNotEqual(BubblePresentation.Row(session: project.session, team: project.team).lamp, .success)
        XCTAssertTrue(BubblePresentation.Row(session: project.session, team: project.team).requiresManualHandling)
        XCTAssertEqual(BubblePresentation.Row(session: project.session, team: project.team)
            .aoAttentionReceipts.filter(\.hasUnread).count, 2)
        XCTAssertEqual(store.sessions.flatMap { $0.aoAttentionReceipts ?? [] }.filter(\.hasUnread).count, 2)
    }

    func testProjectSummaryAcknowledgesOnlyClickedSourceAndRestoresOneHistoryRow() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(); store.persistenceURL = file
        let facts = try projectSnapshot([
            ("lead", "proj", "orchestrator", "codex", "working", "active"),
            ("one", "proj", "worker", "pi", "needs_input", "waiting_input"),
            ("two", "proj", "worker", "codex", "needs_input", "waiting_input")])
        _ = store.applyAOSnapshot(facts, now: at)
        let group = try XCTUnwrap(BubblePresentation.groups(store.sessions, settings: .init(now: at)).first)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        let receipts = row.aoAttentionReceipts.filter(\.hasUnread)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertTrue(store.acknowledgeAO(try XCTUnwrap(receipts.first), at: at))
        let after = try XCTUnwrap(BubblePresentation.groups(store.sessions, settings: .init(now: at)).first)
        let afterRow = BubblePresentation.Row(session: after.session, team: after.team)
        XCTAssertEqual(afterRow.aoAttentionReceipts.filter(\.hasUnread).count, 1)
        XCTAssertTrue(afterRow.requiresManualHandling, "a working representative cannot disable a member's current wait")
        XCTAssertTrue(store.flushSnapshots().isFlushed)
        let restored = SessionStore(); restored.persistenceURL = file; restored.restoreCodexSessions()
        let history = BubblePresentation.groups(restored.sessions, settings: .init(now: at))
        XCTAssertEqual(history.count, 1, "unread history for one project remains one summary after restart")
        let restoredGroup = try XCTUnwrap(history.first)
        XCTAssertEqual(restoredGroup.team?.id, "proj")
        XCTAssertEqual(restoredGroup.team?.leaderMissing, true)
        XCTAssertEqual(BubblePresentation.Row(session: restoredGroup.session, team: restoredGroup.team)
            .aoAttentionReceipts.filter(\.hasUnread).map(\.id), [receipts[1].id])
        XCTAssertTrue(restored.sessions.allSatisfy { $0.hostTeamScope?.role == nil })
        _ = restored.applyAOSnapshot(facts, now: at)
        let live = try XCTUnwrap(BubblePresentation.groups(restored.sessions, settings: .init(now: at)).first)
        XCTAssertEqual(BubblePresentation.Row(session: live.session, team: live.team)
            .aoAttentionReceipts.filter(\.hasUnread).map(\.id), [receipts[1].id],
                       "reobserving the same waiting fact cannot revive an acknowledged source")
    }

    func testProductionProjectDropsExitedRepresentativeAndKeepsWorkingMembers() throws {
        let store = SessionStore()
        _ = store.applyAOSnapshot(try projectSnapshot([
            ("lead", "proj", "orchestrator", "codex", "working", "active"),
            ("worker", "proj", "worker", "pi", "working", "active")]), now: at)
        var exited = try projectSnapshot([
            ("lead", "proj", "orchestrator", "codex", "exited", "exited"),
            ("worker", "proj", "worker", "pi", "working", "active")])
        exited.observedAt = at.addingTimeInterval(1)
        for index in exited.sessions.indices { exited.sessions[index].updatedAt = at.addingTimeInterval(1) }
        _ = store.applyAOSnapshot(exited, now: at.addingTimeInterval(1))
        let groups = BubblePresentation.groups(store.sessions, settings: .init(now: at.addingTimeInterval(1)))
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.team?.leaderMissing, true)
        XCTAssertTrue(group.team?.membersWorking == true)
        XCTAssertNil(store.session(id: "ao:lead")?.hostTeamScope?.role)
        XCTAssertEqual(BubblePresentation.Row(session: group.session, team: group.team).lamp, .running)
    }

    func testAOWithoutEvidenceStaysIndependentAndUsesHostContext() throws {
        let leader = aoSession("proj-1", state: .working, role: nil,
                               hostRole: .orchestrator, status: "working", activity: .active)
        var worker = aoSession("proj-2", state: .waiting, role: nil, kind: .opencode,
                               status: "needs_input", activity: .waitingInput)
        worker.notificationVersion = 1
        let rows = BubblePresentation.groups([leader, worker, plain("plain")], settings: .init(now: at))
        XCTAssertEqual(Set(rows.map(\.session.id)), ["native-proj-1", "native-proj-2", "plain"])
        XCTAssertTrue(rows.allSatisfy { $0.team == nil })
        let leaderRow = BubblePresentation.Row(session: leader)
        XCTAssertTrue(leaderRow.titleText.contains("AO Leader"))
        XCTAssertTrue(leaderRow.titleText.contains("Leader"))
        XCTAssertEqual(leaderRow.projectName, "AgentPet")
        XCTAssertEqual(leaderRow.lamp, .running)
        let workerRow = BubblePresentation.Row(session: worker)
        XCTAssertTrue(workerRow.titleText.contains("AO Worker"))
        XCTAssertEqual(workerRow.lamp, .attention)
        XCTAssertTrue(workerRow.isWaitingDisplay)
        XCTAssertTrue(workerRow.requiresManualHandling)
    }

    func testBoundAOWaitingOutranksStaleNativeWorkingWithoutRewritingIt() {
        let waiting = aoSession("worker-1", state: .working, role: nil,
                                status: "needs_input", activity: .waitingInput)
        let row = BubblePresentation.Row(session: waiting)
        XCTAssertEqual(row.stateLabel, "等待用户输入")
        XCTAssertEqual(row.lamp, .attention)
        XCTAssertTrue(row.isWaitingDisplay)
        XCTAssertTrue(row.requiresManualHandling)
        XCTAssertEqual(waiting.state, .working, "display override must not mutate native state")
    }

    func testAOIdlePRAndExitNeverUseSuccessLamp() {
        let idle = aoSession("proj-1", state: .idle, role: nil, status: "idle", activity: .idle)
        XCTAssertEqual(BubblePresentation.Row(session: idle).lamp, .unknown)
        XCTAssertNotEqual(BubblePresentation.Row(session: idle).lamp, .success)

        let merged = aoSession("proj-2", state: .idle, role: nil, status: "merged",
                               activity: .idle)
        XCTAssertEqual(BubblePresentation.Row(session: merged).lamp, .unknown)
        XCTAssertNil(merged.taskResult)

        var exited = aoSession("proj-3", state: .working, role: nil, status: "terminated",
                               activity: .exited, terminated: true)
        exited.codexTurnResult = nil
        let row = BubblePresentation.Row(session: exited)
        XCTAssertEqual(row.lamp, .unknown)
        XCTAssertEqual(row.stateLabel, "AO 会话已退出")
        XCTAssertEqual(row.messageText, "AO 会话已退出")
    }

    func testAOTeamLeaderIdleDoesNotHideMemberAttention() throws {
        let lead = aoSession("orch-1", state: .idle, role: .lead, status: "idle", activity: .idle)
        let working = aoSession("worker-1", state: .working, role: .teammate)
        let workingGroup = try XCTUnwrap(BubblePresentation.groups([lead, working], settings: .init(now: at)).first)
        XCTAssertEqual(workingGroup.id, "ao-team-orch-1")
        XCTAssertEqual(workingGroup.team?.host, .agentOrchestrator)
        XCTAssertEqual(workingGroup.team?.name, "AgentPet Team")
        XCTAssertEqual(workingGroup.session.id, lead.id)
        let workingRow = BubblePresentation.Row(session: workingGroup.session, team: workingGroup.team)
        XCTAssertEqual(workingRow.stateLabel, "工作中")
        XCTAssertEqual(workingRow.lamp, .running)

        let waiting = aoSession("worker-2", state: .waiting, role: .teammate,
                                status: "needs_input", activity: .waitingInput)
        let waitingGroup = try XCTUnwrap(BubblePresentation.groups([lead, waiting], settings: .init(now: at)).first)
        let waitingRow = BubblePresentation.Row(session: waitingGroup.session, team: waitingGroup.team)
        XCTAssertEqual(waitingRow.stateLabel, "等待中")
        XCTAssertEqual(waitingRow.lamp, .attention)
        XCTAssertTrue(waitingRow.isWaitingDisplay)
        XCTAssertTrue(waitingRow.requiresManualHandling)

        let failed = aoSession("worker-3", state: .done, role: .teammate,
                               status: "failed", activity: .idle, result: .failed)
        let failedGroup = try XCTUnwrap(BubblePresentation.groups([lead, failed], settings: .init(now: at)).first)
        let failedRow = BubblePresentation.Row(session: failedGroup.session, team: failedGroup.team)
        XCTAssertEqual(failedRow.stateLabel, "失败")
        XCTAssertEqual(failedRow.lamp, .failure)
        XCTAssertTrue(failedRow.requiresManualHandling)

        let cancelled = aoSession("worker-4", state: .done, role: .teammate,
                                  status: "cancelled", activity: .idle, result: .cancelled)
        let cancelledGroup = try XCTUnwrap(BubblePresentation.groups([lead, cancelled], settings: .init(now: at)).first)
        let cancelledRow = BubblePresentation.Row(session: cancelledGroup.session, team: cancelledGroup.team)
        XCTAssertEqual(cancelledRow.stateLabel, "已停止")
        XCTAssertEqual(cancelledRow.lamp, .off)

        let unknown = aoSession("worker-5", state: .idle, role: .teammate,
                                status: "no_signal", activity: .idle)
        let unknownGroup = try XCTUnwrap(BubblePresentation.groups([lead, unknown], settings: .init(now: at)).first)
        let unknownRow = BubblePresentation.Row(session: unknownGroup.session, team: unknownGroup.team)
        XCTAssertEqual(unknownRow.stateLabel, "等待状态更新")
        XCTAssertEqual(unknownRow.lamp, .unknown)
    }

    func testAOLeadStateOutranksMemberAttentionWhileWorking() throws {
        let lead = aoSession("orch-1", state: .working, role: .lead)
        let waiting = aoSession("worker-1", state: .waiting, role: .teammate,
                                status: "needs_input", activity: .waitingInput)
        let group = try XCTUnwrap(BubblePresentation.groups([lead, waiting], settings: .init(now: at)).first)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.stateLabel, "工作中")
        XCTAssertEqual(row.lamp, .running)
    }

    @MainActor
    func testAOTeamPetEligibilityAndSwitches() {
        let before = BubbleSettings.shared.aoExperimentEnabled
        BubbleSettings.shared.aoExperimentEnabled = true
        defer { BubbleSettings.shared.aoExperimentEnabled = before }
        let lead = aoSession("orch-1", state: .working, role: .lead)
        let mate = aoSession("worker-1", state: .working, role: .teammate)
        XCTAssertTrue(BubbleSettings.shared.allowsAgentActivity(lead))
        XCTAssertFalse(BubbleSettings.shared.allowsAgentActivity(mate))
        XCTAssertEqual(PetController.teamEligible([lead, mate, plain("plain")], teamsShown: false).map(\.id),
                       [lead.id, "plain"])

        var off = BubblePresentation.Configuration()
        off.showAgentOrchestratorTeams = false
        XCTAssertTrue(BubblePresentation.groups([lead, mate], settings: off).isEmpty)
        var aionOff = BubblePresentation.Configuration()
        aionOff.showAionUiTeams = false
        XCTAssertEqual(BubblePresentation.groups([lead, mate], settings: aionOff).count, 1)
    }


    @MainActor
    func testExperimentOffHidesProjectsStandaloneAndUnverifiedBindingsWithoutReading() throws {
        let lead = aoSession("orch-1", state: .working, role: .lead)
        let member = aoSession("worker-1", state: .waiting, role: .teammate)
        let standalone = aoSession("solo", state: .working, role: nil)
        var bindingOnly = standalone; bindingOnly.aoObservation = nil
        let inputs = [lead, member, standalone, bindingOnly]
        let preference = BubbleSettings.shared.aoExperimentEnabled
        defer { BubbleSettings.shared.aoExperimentEnabled = preference }
        BubbleSettings.shared.aoExperimentEnabled = false
        var config = BubbleSettings.shared.presentationConfiguration; config.now = at
        XCTAssertFalse(config.showAgentOrchestratorTeams)
        XCTAssertEqual(BubblePresentation.groups(inputs + [plain("native")], settings: config).map { $0.session.id }, ["native"])
        XCTAssertTrue(inputs.allSatisfy { !BubbleSettings.shared.allowsAgentActivity($0) })
        XCTAssertEqual(PetController.teamEligible(inputs + [plain("native")], aoShown: false).map(\.id), ["native"])
        XCTAssertEqual(member.readThroughVersion, 0)
        BubbleSettings.shared.aoExperimentEnabled = true
        config = BubbleSettings.shared.presentationConfiguration; config.now = at
        XCTAssertTrue(config.showAgentOrchestratorTeams)
        XCTAssertFalse(BubblePresentation.groups([lead, member], settings: config).isEmpty)
        XCTAssertTrue(BubbleSettings.shared.allowsAgentActivity(lead))
        XCTAssertFalse(BubbleSettings.shared.allowsAgentActivity(member))
        XCTAssertEqual(member.readThroughVersion, 0)
    }

    func testStaleAOObservationCannotClaimCurrentTeamRole() throws {
        let stale = aoSession("orch-1", state: .idle, role: .lead, status: "idle",
                              activity: .idle, observedAt: at)
        let now = at.addingTimeInterval(120)
        let worker = aoSession("worker-1", state: .working, role: .teammate,
                               observedAt: now)
        let group = try XCTUnwrap(BubblePresentation.groups([stale, worker], settings: .init(now: now)).first)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(group.team?.identityUnconfirmed, true)
        XCTAssertEqual(row.stateLabel, "工作中", "fresh member activity remains known when the leader check expires")
        XCTAssertNotEqual(row.lamp, BubblePresentation.Row.Lamp.success)
    }

    func testConflictedNativeRowsRemainVisibleAndPreserveUnread() {
        var old = aoSession("proj-1", state: .done, role: nil, hostRole: .worker,
                            nativeID: "native-old", title: "Old native task",
                            result: .completed)
        old.aoBinding?.conflictedAt = at
        old.aoObservation = nil
        old.notificationVersion = 1
        var current = aoSession("proj-1", state: .working, role: nil, hostRole: .worker,
                                nativeID: "native-current", title: "Current native task")
        current.aoBinding?.conflictedAt = at
        current.aoObservation = nil

        let rows = BubblePresentation.groups([old, current], settings: .init(now: at))
        XCTAssertEqual(Set(rows.map(\.session.id)), ["native-old", "native-current"])
        let oldRow = BubblePresentation.Row(session: old)
        XCTAssertTrue(old.hasUnread)
        XCTAssertEqual(oldRow.lamp, .success)
        XCTAssertEqual(oldRow.stateLabel, "已完成")
        XCTAssertEqual(BubblePresentation.Row(session: current).lamp, .running)
    }

    func testConflictedOldWaitingNativeRowStillRequiresManualHandling() {
        var old = aoSession("proj-1", state: .waiting, role: nil, hostRole: .worker,
                            nativeID: "native-wait", status: "needs_input",
                            activity: .waitingInput)
        old.aoBinding?.conflictedAt = at
        old.aoObservation = nil
        old.notificationVersion = 1
        let groups = BubblePresentation.groups([old], settings: .init(now: at))
        XCTAssertEqual(groups.map(\.session.id), ["native-wait"])
        let row = BubblePresentation.Row(session: groups[0].session)
        XCTAssertTrue(row.isWaitingDisplay)
        XCTAssertTrue(row.requiresManualHandling)
        XCTAssertEqual(row.lamp, .attention)
    }

    func testConflictedNativeAndIndependentHostWaitRemainDistinctVisibleRows() throws {
        let store = SessionStore()
        for id in ["native-a", "native-b"] {
            var event = AgentEvent(sessionId: id, agentKind: .opencode, eventName: "working", timestamp: at)
            event.aoSessionID = "worker-1"
            event.aoProjectID = "proj"
            _ = store.apply(event, now: at)
        }
        let observed = try XCTUnwrap(aoSession("worker-1", state: .waiting, role: nil,
            kind: .opencode, status: "needs_input", activity: .waitingInput).aoObservation)
        _ = store.applyAOSnapshot(AOSnapshot(instanceID: instance, observedAt: at,
            projectNames: [:], sessions: [observed]), now: at)
        let rows = BubblePresentation.groups(store.sessions, settings: .init(now: at))
        XCTAssertEqual(Set(rows.map(\.session.id)), ["native-a", "native-b", "ao:worker-1"])
        XCTAssertTrue(rows.allSatisfy { $0.team == nil })
        let host = try XCTUnwrap(rows.first { $0.session.isAOPlaceholder })
        let presentation = BubblePresentation.Row(session: host.session)
        XCTAssertEqual(presentation.associationNotice, "关联未确认")
        var noTitle = BubbleLayout.standard
        noTitle.tokens = noTitle.tokens.map { item in
            var copy = item
            if copy.token == .title { copy.isVisible = false }
            return copy
        }
        XCTAssertFalse(presentation.visibleTokens(noTitle).contains { $0.token == .title })
        XCTAssertEqual(presentation.associationNotice, "关联未确认", "notice is independent of hidden/truncated title tokens")
        XCTAssertTrue(presentation.titleText.hasPrefix("关联未确认"), "identity qualification precedes a long task title")
        XCTAssertTrue(presentation.titleText.contains("worker-1"))
        XCTAssertTrue(presentation.requiresManualHandling)
        XCTAssertTrue(presentation.isWaitingDisplay)
        XCTAssertEqual(presentation.lamp, .attention)
        for native in rows where !native.session.isAOPlaceholder {
            XCTAssertFalse(BubblePresentation.Row(session: native.session).requiresManualHandling)
            XCTAssertFalse(BubblePresentation.Row(session: native.session).titleText.contains("AO Worker"))
        }
    }

    func testAcknowledgedAOCurrentWaitStaysVisibleAfterNativeTurnEnded() throws {
        for result in [CodexTurnResult.completed, .cancelled] {
            let store = SessionStore()
            var event = AgentEvent(sessionId: "native", agentKind: .opencode,
                                   eventName: "working", timestamp: at)
            event.aoSessionID = "worker-1"
            event.aoProjectID = "proj"
            _ = store.apply(event, now: at)
            event.eventName = "done"
            event.turnResult = result
            event.timestamp = at.addingTimeInterval(1)
            _ = store.apply(event, now: event.timestamp)
            let fact = try XCTUnwrap(aoSession("worker-1", state: .waiting, role: nil,
                kind: .opencode, status: "needs_input", activity: .waitingInput,
                updatedAt: at.addingTimeInterval(2)).aoObservation)
            _ = store.applyAOSnapshot(AOSnapshot(instanceID: instance, observedAt: at,
                projectNames: [:], sessions: [fact]), now: at)
            let receipt = try XCTUnwrap(store.session(id: "native")?.aoAttentionReceipts?.first)
            XCTAssertTrue(store.acknowledgeAO(receipt, at: at))
            let native = try XCTUnwrap(store.session(id: "native"))
            XCTAssertFalse(native.hasAOUnread)
            XCTAssertEqual(native.state, .done)
            XCTAssertEqual(native.taskResult, result)
            let row = BubblePresentation.Row(session: native)
            XCTAssertTrue(row.isWaitingDisplay)
            XCTAssertTrue(row.requiresManualHandling)
            XCTAssertEqual(row.lamp, .attention)
        }
    }

    func testGroupedPiCannotHideHistoricalAOUnreadBehindWorkingNative() throws {
        let store = SessionStore()
        let fact = try XCTUnwrap(aoSession("worker-1", state: .waiting, role: nil,
            kind: .pi, status: "needs_input", activity: .waitingInput).aoObservation)
        _ = store.applyAOSnapshot(AOSnapshot(instanceID: instance, observedAt: at,
            projectNames: [:], sessions: [fact]), now: at)
        _ = store.markAOUnavailable(now: at)
        let history = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(history.state, .idle)
        XCTAssertTrue(history.hasAOUnread)
        let ordinary = AgentSession(id: "ordinary-pi", agentKind: .pi, state: .working,
                                    source: .hook, updatedAt: at)
        var settings = BubblePresentation.Configuration(now: at)
        settings.sessionGrouping = .byKind
        let groups = BubblePresentation.groups([ordinary, history], settings: settings)
        XCTAssertEqual(Set(groups.map(\.session.id)), [ordinary.id, history.id])
        XCTAssertTrue(groups.allSatisfy { $0.count == 1 })
    }

    func testAONavigationHintMatchesAvailableRoute() {
        var bound = aoSession("worker-1", state: .working, role: nil, kind: .opencode)
        bound.terminalProgram = nil
        bound.opencodeNavigationSocket = nil
        XCTAssertFalse(BubblePresentation.Row(session: bound).canFocusTerminal)
        XCTAssertEqual(BubblePresentation.Row(session: bound).navigationHint, "无可用的精确会话跳转")

        var placeholder = bound
        placeholder.aoBinding = AOBinding(sessionID: "worker-1", projectID: "proj",
                                          agentKind: .opencode, origin: .hostObservation, boundAt: at)
        XCTAssertTrue(BubblePresentation.Row(session: placeholder).canFocusTerminal)
        XCTAssertTrue(BubblePresentation.Row(session: placeholder).navigationHint.contains("项目编排器"))
    }

    func testAOProjectAndModelKeepNativeSourceIdentity() {
        var opencode = aoSession("worker-1", state: .working, role: nil, kind: .opencode,
                                 title: "R5 implementation")
        opencode.model = "deepseek-v4.1-flash"
        opencode.opencodeNavigationSocket = "/tmp/agentpet-test-nav.sock"
        let row = BubblePresentation.Row(session: opencode)
        XCTAssertTrue(row.titleText.contains("AO Worker"))
        XCTAssertTrue(row.titleText.contains("R5 implementation"))
        XCTAssertEqual(row.projectName, "AgentPet")
        XCTAssertTrue(row.usesTaskDetails)
        XCTAssertTrue(row.canFocusTerminal)
        XCTAssertTrue(row.navigationHint.contains("点击打开对应原生会话"))
    }
}

@MainActor
final class AONavigationTests: XCTestCase {
    private final class Backend: SessionNavigationBackend {
        var calls: [String] = []
        var aoTarget: AOProjectNavigation.Target?
        var aoOutcome: AOProjectNavigation.Outcome = .failed("AO 项目导航不可用；未标记已读")
        var onAO: (() -> Void)?
        func openAOProject(_ target: AOProjectNavigation.Target, validate: @escaping @MainActor () -> Bool) async -> AOProjectNavigation.Outcome {
            aoTarget = target; onAO?()
            return validate() ? aoOutcome : .superseded
        }
        var focusResult: TerminalFocus.Result = .openedTarget
        func association(_ session: AgentSession) async -> AionUiMetadata.Lookup { calls.append("association"); return .notFound }
        func selectOpencode(_ session: AgentSession) async -> OpencodeTUINavigation.Result {
            calls.append("select")
            return .selected(.init(program: session.terminalProgram, tty: session.terminalTTY, focusURL: session.terminalFocusURL))
        }
        func focusTerminal(_ session: AgentSession) async -> TerminalFocus.Result { calls.append("focus"); return focusResult }
        func open(_ url: URL, bundleID: String) async -> Bool { calls.append("open"); return true }
        func isFrontmost(bundleID: String) -> Bool { true }
        func selectDSH(_ target: DSHObservation, verifyOnly: Bool) async -> DSHNavigation.Receipt? { nil }
        func dshDesktop(peerPID: pid_t) async -> pid_t? { nil }
        func activateDSH(_ pid: pid_t, validate: @escaping @MainActor () -> Bool) async -> DSHActivationOutcome { .appMissing }
        func isFrontmostDSH(_ pid: pid_t) -> Bool { false }
    }

    private let at = Date(timeIntervalSince1970: 100)
    private let instance = "apprun-44444444-4444-4444-4444-444444444444"

    private func aoSession(observedAt: Date? = nil, instanceID: String? = nil) -> AgentSession {
        let observation = AOHostObservation(
            sessionID: "proj-1", projectID: "proj", projectName: "AgentPet", role: .worker,
            harness: "opencode-v2", displayName: "Worker", status: "working",
            activity: .active, activityAt: at, isTerminated: false,
            createdAt: at, updatedAt: at, lastEventAt: at,
            observedAt: observedAt ?? at, instanceID: instanceID ?? instance)
        var session = AgentSession(id: "native-1", agentKind: .opencode, title: "Worker",
                                   state: .working, source: .hook, updatedAt: at, createdAt: at)
        session.aoBinding = AOBinding(sessionID: "proj-1", projectID: "proj",
                                      agentKind: .opencode, origin: .hookEnvironment, boundAt: at)
        session.aoObservation = observation
        return session
    }

    private func service(_ backend: Backend, session: @escaping (String) -> AgentSession?,
                         done: @escaping (AgentSession, SessionNavigationResult) -> Void) -> SessionNavigationService {
        SessionNavigationService(backend: backend, session: session, dshTarget: { $0.dsh },
                                 updateAssociation: { _, _ in }, completion: done)
    }

    func testProjectNavigationUsesCurrentFormalLeadersAndNeverAcknowledgesNative() async {
        var current = aoSession(observedAt: Date())
        current.aoBinding?.origin = .hostObservation
        var leader = current
        leader.aoObservation?.role = .orchestrator
        leader.aoObservation?.sessionID = "proj-leader"
        var other = leader; other.aoObservation?.projectID = "other"
        var dead = leader; dead.aoObservation?.isTerminated = true
        let backend = Backend(); backend.aoOutcome = .opened(.orchestrator("proj-leader"))
        let done = expectation(description: "verified project navigation")
        let navigation = SessionNavigationService(backend: backend, session: { _ in current },
            dshTarget: { _ in nil }, aoProjectObservations: { [leader, other, dead].compactMap(\.aoObservation) },
            updateAssociation: { _, _ in }, completion: { _, result in
                guard case .opened(let evidence) = result else { XCTFail("must open project"); done.fulfill(); return }
                XCTAssertFalse(evidence.acknowledgesNativeSession)
                done.fulfill()
            })
        navigation.navigate(current)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.aoTarget?.projectID, "proj")
        XCTAssertEqual(backend.aoTarget?.orchestratorIDs, ["proj-leader"])
        XCTAssertEqual(backend.aoTarget?.instanceID, current.aoObservation?.instanceID)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testStandaloneNativeResultUsesExactAOEntryWithoutTerminalAndAcknowledgesOnlyIt() async {
        var current = aoSession(observedAt: Date())
        current.state = .done; current.opencodeTurnResult = .completed
        current.notificationVersion = 2; current.readThroughVersion = 1
        current.aoObservation?.projectID = AOHostMapping.standaloneProjectID
        current.aoBinding?.projectID = AOHostMapping.standaloneProjectID
        XCTAssertTrue(BubblePresentation.Row(session: current).canFocusTerminal)
        let backend = Backend(); backend.aoOutcome = .opened(.session("proj-1"))
        let done = expectation(description: "standalone exact page")
        let service = service(backend, session: { _ in current }) { _, result in
            if case .opened(.aoExactSession("proj-1")) = result {} else { XCTFail("must confirm the exact native owner") }
            if case .opened(let evidence) = result { XCTAssertTrue(evidence.acknowledgesNativeSession) }
            done.fulfill()
        }
        service.navigate(current); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.aoTarget?.sessionID, "proj-1")
        XCTAssertEqual(backend.aoTarget?.projectID, AOHostMapping.standaloneProjectID)
        XCTAssertTrue(backend.calls.isEmpty, "must not fall through to AionUI or a missing terminal")
    }

    func testUnreadProjectWorkerUsesExactMemberInsteadOfDesktopOrLeader() async {
        var current = aoSession(observedAt: Date())
        current.state = .done; current.opencodeTurnResult = .completed
        current.notificationVersion = 2; current.readThroughVersion = 1
        current.aoObservation?.orchestration = .init(teamID: "proj", teamName: "Project", role: .teammate)
        for destination in [AOProjectNavigation.Destination.session("proj-1"), .orchestrator("other"), .board] {
            let backend = Backend(); backend.aoOutcome = .opened(destination)
            let done = expectation(description: "exact member")
            let navigation = service(backend, session: { _ in current }) { _, result in
                if destination == .session("proj-1") {
                    if case .opened(.aoExactSession("proj-1")) = result {} else { XCTFail("must open exact member") }
                } else {
                    if case .failed = result {} else { XCTFail("exact requests cannot accept a board or another leader") }
                }
                done.fulfill()
            }
            navigation.navigate(current); await fulfillment(of: [done], timeout: 1)
            XCTAssertEqual(backend.aoTarget?.sessionID, "proj-1")
            XCTAssertTrue(backend.calls.isEmpty)
        }
    }

    func testProjectPrimaryNeverReadsAnUnreadWorkerCarrier() async {
        var current = aoSession(observedAt: Date())
        current.state = .done; current.notificationVersion = 2; current.readThroughVersion = 1
        current.aoObservation?.orchestration = .init(teamID: "proj", teamName: "Project", role: .teammate)
        for destination in [AOProjectNavigation.Destination.orchestrator("proj-leader"), .board] {
            let backend = Backend(); backend.aoOutcome = .opened(destination)
            let done = expectation(description: "project entry from worker carrier")
            let navigation = service(backend, session: { _ in current }) { _, result in
                guard case .opened(.aoProject) = result else { done.fulfill(); return XCTFail("project entry cannot read its worker carrier") }
                if case .opened(let evidence) = result { XCTAssertFalse(evidence.acknowledgesNativeSession) }
                done.fulfill()
            }
            navigation.navigate(current, intent: .aoProject)
            await fulfillment(of: [done], timeout: 1)
            XCTAssertEqual(backend.aoTarget?.projectID, "proj")
            XCTAssertNil(backend.aoTarget?.sessionID, "primary entry must let AO resolve the leader/board")
            XCTAssertTrue(backend.calls.isEmpty)
            XCTAssertEqual(current.readThroughVersion, 1)
        }
    }

    func testProjectPrimaryAcknowledgesOnlyItsConfirmedNativeLeader() async {
        var current = aoSession(observedAt: Date())
        current.state = .done; current.notificationVersion = 2; current.readThroughVersion = 1
        current.aoObservation?.role = .orchestrator
        current.aoObservation?.orchestration = .init(teamID: "proj", teamName: "Project", role: .lead)
        for destination in [AOProjectNavigation.Destination.orchestrator("proj-1"), .orchestrator("other-leader"), .board] {
            let backend = Backend(); backend.aoOutcome = .opened(destination)
            let done = expectation(description: "project entry own leader receipt")
            let navigation = service(backend, session: { _ in current }) { _, result in
                guard case .opened(let evidence) = result else { done.fulfill(); return XCTFail("must open project") }
                XCTAssertEqual(evidence.acknowledgesNativeSession, destination == .orchestrator("proj-1"))
                done.fulfill()
            }
            navigation.navigate(current, intent: .aoProject)
            await fulfillment(of: [done], timeout: 1)
            XCTAssertNil(backend.aoTarget?.sessionID)
            XCTAssertTrue(backend.calls.isEmpty)
        }
    }

    func testProjectIntentDoesNotRerouteStandaloneOrOrdinaryNativeSessions() async {
        for standalone in [true, false] {
            var current = aoSession(observedAt: Date())
            if standalone {
                current.aoObservation?.projectID = AOHostMapping.standaloneProjectID
                current.aoBinding?.projectID = AOHostMapping.standaloneProjectID
            } else { current.aoObservation = nil; current.aoBinding = nil }
            let backend = Backend()
            let done = expectation(description: "invalid project entry")
            let navigation = service(backend, session: { _ in current }) { _, result in
                if case .failed = result {} else { XCTFail("must reject non-project target") }
                done.fulfill()
            }
            navigation.navigate(current, intent: .aoProject)
            await fulfillment(of: [done], timeout: 1)
            XCTAssertNil(backend.aoTarget)
            XCTAssertTrue(backend.calls.isEmpty)
        }
    }

    func testUnreadAOProjectDSHDoesNotRequireADSHDesktopClient() async {
        var current = aoSession(observedAt: Date())
        current.agentKind = .dsh; current.aoBinding?.agentKind = .dsh
        current.aoObservation?.harness = "deepseek-harness"
        current.aoObservation?.orchestration = .init(teamID: "proj", teamName: "Project", role: .teammate)
        current.state = .done; current.notificationVersion = 1
        let backend = Backend(); backend.aoOutcome = .opened(.session("proj-1"))
        let done = expectation(description: "AO owns ACP navigation")
        let navigation = service(backend, session: { _ in current }) { _, result in
            if case .opened(.aoExactSession("proj-1")) = result {} else { XCTFail("ACP member must use AO, even without a DSH desktop Client") }
            done.fulfill()
        }
        navigation.navigate(current); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.aoTarget?.sessionID, "proj-1")
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testProjectNavigationOnlyAcknowledgesClickedNativeWhenExactOwnerPageConfirms() async {
        for destination in [AOProjectNavigation.Destination.orchestrator("proj-1"), .orchestrator("other-leader"), .board] {
            var current = aoSession(observedAt: Date())
            current.aoObservation?.role = .orchestrator
            current.aoObservation?.orchestration = .init(teamID: "proj", teamName: "Project", role: .lead)
            let backend = Backend(); backend.aoOutcome = .opened(destination)
            let done = expectation(description: "project exact acknowledgement")
            let service = service(backend, session: { _ in current }) { _, result in
                guard case .opened(let evidence) = result else { done.fulfill(); return XCTFail("expected navigation") }
                XCTAssertEqual(evidence.acknowledgesNativeSession, destination == .orchestrator("proj-1"))
                done.fulfill()
            }
            service.navigate(current); await fulfillment(of: [done], timeout: 1)
        }
    }

    func testExactAOOpenCannotReadANewerReplyOrAnotherMember() async throws {
        let store = SessionStore(), now = Date()
        let id = "native-course"
        var event = AgentEvent(sessionId: id, agentKind: .codex, eventName: "Stop", timestamp: now)
        event.turnResult = .completed
        _ = store.apply(event, now: now)
        var sibling = event; sibling.sessionId = "other-native"
        _ = store.apply(sibling, now: now)
        var host = AOHostObservation(sessionID: "course-1", projectID: "course", role: .orchestrator,
            harness: "codex", status: "idle", activity: .idle, activityAt: now, isTerminated: false,
            createdAt: now, updatedAt: now, observedAt: now, instanceID: instance)
        host.orchestration = AOHostMapping.projectGroup(for: host)
        var fresh = AOSnapshot(instanceID: instance, observedAt: now, projectNames: [:], sessions: [host])
        fresh.nativeIdentities = [.init(sessionID: "course-1", nativeSessionID: id, agentKind: .codex)]
        _ = store.applyAOSnapshot(fresh, now: now)
        let clicked = try XCTUnwrap(store.session(id: id))
        let backend = Backend(); backend.aoOutcome = .opened(.orchestrator("course-1"))
        backend.onAO = {
            var next = AgentEvent(sessionId: id, agentKind: .codex, eventName: "UserPromptSubmit", timestamp: now.addingTimeInterval(1))
            _ = store.apply(next, now: next.timestamp)
            next.eventName = "Stop"; next.turnResult = .completed; next.timestamp = now.addingTimeInterval(2)
            _ = store.apply(next, now: next.timestamp)
        }
        let done = expectation(description: "read only the clicked watermark")
        let navigation = service(backend, session: { store.session(id: $0) }) { opened, result in
            if case .opened(let evidence) = result, evidence.acknowledgesNativeSession {
                _ = store.markOpened(opened, at: now.addingTimeInterval(3))
            } else { XCTFail("expected an exact owner receipt") }
            done.fulfill()
        }
        navigation.navigate(clicked); await fulfillment(of: [done], timeout: 1)
        let current = try XCTUnwrap(store.session(id: id))
        XCTAssertGreaterThan(current.notificationVersion, clicked.notificationVersion)
        XCTAssertTrue(current.hasUnread, "opening the previous reply cannot consume a reply that arrived in flight")
        XCTAssertEqual(store.session(id: "other-native")?.readThroughVersion, 0)
    }

    func testProjectNavigationRejectsHostChangeDuringBackendOperation() async {
        var current = aoSession(observedAt: Date())
        current.aoBinding?.origin = .hostObservation
        let clicked = current
        let backend = Backend(); backend.aoOutcome = .opened(.board)
        backend.onAO = { current.aoObservation?.instanceID = "apprun-55555555-5555-5555-5555-555555555555" }
        let done = expectation(description: "host replaced")
        let navigation = service(backend, session: { _ in current }) { _, result in
            if case .superseded = result {} else { XCTFail("changed host cannot succeed") }
            done.fulfill()
        }
        navigation.navigate(clicked)
        await fulfillment(of: [done], timeout: 1)
    }

    func testAOOnlyPlaceholderFailsClosedAndDoesNotOpenOrAcknowledge() async {
        var current = aoSession(observedAt: Date())
        current.aoBinding = AOBinding(sessionID: "proj-1", projectID: "proj",
                                      agentKind: .opencode, origin: .hostObservation, boundAt: at)
        let backend = Backend()
        let done = expectation(description: "AO unsupported")
        let service = service(backend, session: { _ in current }) { _, result in
            guard case .failed(let message) = result else { XCTFail("must fail closed"); done.fulfill(); return }
            XCTAssertTrue(message.contains("导航不可用"))
            XCTAssertTrue(message.contains("未标记已读"))
            done.fulfill()
        }
        service.navigate(current)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testStaleAOObservationFailsClosedWithExpiredMessage() async {
        var current = aoSession(observedAt: at)
        current.terminalProgram = "iTerm.app"
        let backend = Backend()
        let done = expectation(description: "AO expired")
        let service = service(backend, session: { _ in current }) { _, result in
            guard case .failed(let message) = result else { XCTFail("must fail"); done.fulfill(); return }
            XCTAssertTrue(message.contains("已过期"))
            done.fulfill()
        }
        service.navigate(current)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testChangedAOInstanceSupersedesAttempt() async {
        let clicked = aoSession(observedAt: Date())
        let replacement = aoSession(observedAt: Date(), instanceID: "apprun-55555555-5555-5555-5555-555555555555")
        let backend = Backend()
        let done = expectation(description: "AO instance changed")
        let service = service(backend, session: { _ in replacement }) { _, result in
            guard case .superseded = result else { XCTFail("changed instance must supersede"); done.fulfill(); return }
            done.fulfill()
        }
        service.navigate(clicked)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertTrue(backend.calls.isEmpty)
    }
    func testBoundNativeAORowKeepsPreciseTerminalRoute() async {
        var current = aoSession(observedAt: Date())
        current.agentKind = .codex
        current.terminalProgram = "iTerm.app"
        current.aoBinding?.agentKind = .codex
        let backend = Backend()
        let done = expectation(description: "native terminal")
        let service = service(backend, session: { _ in current }) { _, result in
            if case .opened(.terminalTarget) = result {} else { XCTFail("native exact terminal must open") }
            done.fulfill()
        }
        service.navigate(current)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association", "focus"])
    }

    func testBoundNativeAORowKeepsPreciseOpencodeRoute() async {
        var current = aoSession(observedAt: Date()); current.opencodeNavigationSocket = "/fixture/opencode.sock"
        let backend = Backend()
        let done = expectation(description: "native opencode")
        let service = service(backend, session: { _ in current }) { _, result in
            if case .opened(.terminalTarget) = result {} else { XCTFail("native opencode must open") }
            done.fulfill()
        }
        service.navigate(current)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association", "select", "focus"])
    }

    func testConflictedHistoricalNativeRowKeepsNativeOnlyRoute() async {
        var current = aoSession(observedAt: Date())
        current.agentKind = .codex
        current.terminalProgram = "iTerm.app"
        current.aoBinding?.conflictedAt = at
        let backend = Backend()
        let done = expectation(description: "historical native route")
        let service = service(backend, session: { _ in current }) { _, result in
            if case .opened(.terminalTarget) = result {} else { XCTFail("historical native target must open") }
            done.fulfill()
        }
        service.navigate(current)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association", "focus"])
    }

    func testAOTeamTargetFailsClosedEvenWithNativeRoute() async {
        var current = aoSession(observedAt: Date())
        current.terminalProgram = "iTerm.app"
        if var observation = current.aoObservation {
            observation.orchestration = AOOrchestration(teamID: "orch-1", teamName: "Team",
                                                        role: .teammate,
                                                        orchestratorSessionID: "orch-1")
            current.aoObservation = observation
        }
        let backend = Backend()
        let done = expectation(description: "AO team target")
        let service = service(backend, session: { _ in current }) { _, result in
            guard case .failed(let message) = result else { XCTFail("AO Team must fail closed"); done.fulfill(); return }
            XCTAssertTrue(message.contains("导航不可用"))
            done.fulfill()
        }
        service.navigate(current)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testNativeNavigationCannotAcknowledgeAnIndependentAOReceipt() async throws {
        for focused in [TerminalFocus.Result.activatedApplication, .openedTarget] {
            let store = SessionStore()
            var hook = AgentEvent(sessionId: "native-1", agentKind: .opencode,
                                  eventName: "working", timestamp: Date())
            hook.aoSessionID = "proj-1"
            hook.aoProjectID = "proj"
            hook.opencodeNavigationSocket = "/fixture/opencode.sock"
            _ = store.apply(hook, now: Date())
            var observation = try XCTUnwrap(aoSession(observedAt: Date()).aoObservation)
            observation.status = "needs_input"
            observation.activity = .waitingInput
            _ = store.applyAOSnapshot(AOSnapshot(instanceID: instance, observedAt: Date(),
                projectNames: [:], sessions: [observation]), now: Date())
            let clicked = try XCTUnwrap(store.session(id: "native-1"))
            XCTAssertTrue(clicked.hasAOUnread)
            let backend = Backend()
            backend.focusResult = focused
            let done = expectation(description: "source-specific receipt")
            let navigation = service(backend, session: { store.session(id: $0) }) { clicked, result in
                if case .opened = result { _ = store.markOpened(clicked, at: Date()) }
                done.fulfill()
            }
            navigation.navigate(clicked)
            await fulfillment(of: [done], timeout: 1)
            let current = try XCTUnwrap(store.session(id: clicked.id))
            XCTAssertTrue(current.hasAOUnread, "failed/activation-only/native-open callbacks cannot clear AO")
            if case .activatedApplication = focused { XCTAssertNil(current.readAt) }
            else { XCTAssertNotNil(current.readAt) }
        }
    }

    func testNativeRouteActivationAloneIsNotSuccess() async {
        var current = aoSession(observedAt: Date()); current.opencodeNavigationSocket = "/fixture/opencode.sock"
        let backend = Backend()
        backend.focusResult = .activatedApplication
        let done = expectation(description: "activation only")
        let service = service(backend, session: { _ in current }) { _, result in
            if case .failed = result {} else { XCTFail("activation alone must fail") }
            done.fulfill()
        }
        service.navigate(current)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association", "select", "focus"])
    }

}
