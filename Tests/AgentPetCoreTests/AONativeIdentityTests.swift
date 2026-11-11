import Foundation
import XCTest
import CSQLite
@testable import AgentPetCore

final class AONativeIdentityTests: XCTestCase {
    private let nativeID = "11111111-1111-4111-8111-111111111111"
    private let now = Date(timeIntervalSince1970: 2_000)
    private func dshCompletion(profile: String = String(repeating: "a", count: 24), native: String? = nil) -> AgentEvent {
        let observation = DSHObservation(schema: 1, profileID: profile,
            hostID: "22222222-2222-4222-8222-222222222222", hostStartedAt: now.addingTimeInterval(-10),
            nativeSessionID: native ?? nativeID, revision: 1, nativeSeq: 3, turn: 1, phase: .done,
            result: .completed, pending: [], startedAt: now.addingTimeInterval(-2), endedAt: now,
            baseline: false, heartbeat: false, gap: false)
        var event = AgentEvent(sessionId: observation.sessionKey, agentKind: .dsh, eventName: "dsh/observation", timestamp: now)
        event.dsh = observation
        return event
    }
    private func host(_ id: String = "project-1", harness: String = "codex", project: String = "project") -> AOHostObservation {
        var h = AOHostObservation(sessionID: id, projectID: project, role: .orchestrator,
            harness: harness, status: "idle", activity: .idle, activityAt: now,
            isTerminated: false, createdAt: now, updatedAt: now, observedAt: now,
            instanceID: "apprun-11111111-1111-4111-8111-111111111111")
        h.orchestration = AOHostMapping.projectGroup(for: h)
        return h
    }
    private func snapshot(_ hosts: [AOHostObservation]) -> AOSnapshot {
        .init(instanceID: hosts.first!.instanceID, observedAt: now, projectNames: [:], sessions: hosts)
    }
    private func fixture(_ rows: String, body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ao.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let schema = """
            CREATE TABLE sessions(id TEXT PRIMARY KEY, project_id TEXT, harness TEXT, session_mode TEXT,
            agent_session_id TEXT, provider_conversation_id TEXT, runtime_launch_id TEXT, agent_session_id_launch_id TEXT);
            """
        XCTAssertEqual(sqlite3_exec(db, schema + rows, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        try body(path)
    }
    func testExactChatIdentityRecoversRestoredUnreadWithoutRestoringCachedRole() throws {
        try fixture("INSERT INTO sessions VALUES('project-1','project','codex','chat','','\(nativeID)','','');") { path in
            var fresh = snapshot([host()])
            fresh.nativeIdentities = AONativeIdentityReader.read(snapshot: fresh, path: path)
            XCTAssertEqual(fresh.nativeIdentities.count, 1)
            let original = SessionStore()
            var done = AgentEvent(sessionId: nativeID, agentKind: .codex, eventName: "Stop", timestamp: now)
            done.turnResult = .completed
            _ = original.apply(done, now: now)
            let reducer = SessionReducer()
            reducer.restore(SessionSnapshotDTO(sessions: original.sessions))
            XCTAssertNil(reducer.byID[nativeID]?.aoBinding)
            _ = reducer.applyAOSnapshot(fresh, now: now)
            let recovered = try XCTUnwrap(reducer.byID[nativeID])
            XCTAssertEqual(recovered.aoBinding?.origin, .nativeIdentity)
            XCTAssertEqual(recovered.aoObservation?.sessionID, "project-1")
            XCTAssertEqual(recovered.hostTeamScope?.teamID, "project")
            XCTAssertTrue(recovered.aoObservationIsCurrent(at: now))
            XCTAssertEqual(recovered.state, original.sessions.first?.state)
            XCTAssertEqual(recovered.notificationVersion, original.sessions.first?.notificationVersion)
            XCTAssertEqual(recovered.readThroughVersion, original.sessions.first?.readThroughVersion)
            XCTAssertEqual(recovered.taskResult, original.sessions.first?.taskResult)
            reducer.effects.removeAll()
            _ = reducer.applyAOSnapshot(fresh, now: now.addingTimeInterval(1))
            XCTAssertTrue(reducer.effects.isEmpty, "polling identical identity must not continuously save a snapshot")
        }
    }
    func testTUIRequiresExactRuntimeGeneration() throws {
        for (launch, claim, expected) in [("run-1","run-1",1),("run-2","run-1",0),("","",0)] {
            try fixture("INSERT INTO sessions VALUES('project-1','project','codex','tui','\(nativeID)','','\(launch)','\(claim)');") { path in
                XCTAssertEqual(AONativeIdentityReader.read(snapshot: snapshot([host()]), path: path).count, expected)
            }
        }
    }

    func testDSHChatIdentityResolvesTheObservedProfileKeyAndPreservesUnread() throws {
        try fixture("INSERT INTO sessions VALUES('project-1','project','deepseek-harness','chat','','\(nativeID)','','');") { path in
            var fresh = snapshot([host(harness: "deepseek-harness")])
            fresh.nativeIdentities = AONativeIdentityReader.read(snapshot: fresh, path: path)
            XCTAssertEqual(fresh.nativeIdentities.first?.nativeSessionID, nativeID)
            let reducer = SessionReducer()
            let event = dshCompletion()
            _ = reducer.apply(event, now: now)
            let before = try XCTUnwrap(reducer.byID[event.sessionId])
            XCTAssertTrue(before.hasUnread)
            _ = reducer.applyAOSnapshot(fresh, now: now)
            let bound = try XCTUnwrap(reducer.byID[event.sessionId])
            XCTAssertEqual(bound.aoBinding?.origin, .nativeIdentity)
            XCTAssertEqual(bound.aoObservation?.sessionID, "project-1")
            XCTAssertNil(reducer.byID[AOHostMapping.placeholderID("project-1")])
            XCTAssertEqual(bound.dsh, before.dsh)
            XCTAssertEqual(bound.notificationVersion, before.notificationVersion)
            XCTAssertEqual(bound.readThroughVersion, before.readThroughVersion)
            XCTAssertTrue(bound.hasUnread)
            _ = reducer.applyAOSnapshot(fresh, now: now.addingTimeInterval(1))
            XCTAssertTrue(try XCTUnwrap(reducer.byID[event.sessionId]?.aoBinding).isCurrent,
                          "the raw DSH UUID must not retire a namespaced AgentPet key on the next poll")
        }
    }

    func testDSHNativeIdentityDoesNotGuessOrCreateAProfileRow() throws {
        let reducer = SessionReducer()
        var fresh = snapshot([host(harness: "deepseek-harness")])
        fresh.nativeIdentities = [.init(sessionID: "project-1", nativeSessionID: nativeID, agentKind: .dsh)]
        _ = reducer.applyAOSnapshot(fresh, now: now)
        XCTAssertFalse(reducer.byID.values.contains { !$0.isAOPlaceholder && $0.agentKind == .dsh })
        let unrelated = dshCompletion(native: "33333333-3333-4333-8333-333333333333")
        _ = reducer.apply(unrelated, now: now)
        _ = reducer.applyAOSnapshot(fresh, now: now)
        XCTAssertNil(reducer.byID[unrelated.sessionId]?.aoBinding)
        XCTAssertTrue(try XCTUnwrap(reducer.byID[unrelated.sessionId]).hasUnread)
    }

    func testDSHDuplicateProfilesWithdrawIdentityWithoutTransferringReadReceipts() throws {
        let reducer = SessionReducer()
        var fresh = snapshot([host(harness: "deepseek-harness")])
        fresh.nativeIdentities = [.init(sessionID: "project-1", nativeSessionID: nativeID, agentKind: .dsh)]
        let first = dshCompletion()
        _ = reducer.apply(first, now: now)
        _ = reducer.applyAOSnapshot(fresh, now: now)
        XCTAssertEqual(reducer.byID[first.sessionId]?.aoObservation?.sessionID, "project-1")
        let duplicate = dshCompletion(profile: String(repeating: "b", count: 24))
        _ = reducer.apply(duplicate, now: now)
        _ = reducer.applyAOSnapshot(fresh, now: now.addingTimeInterval(1))
        XCTAssertNotNil(reducer.byID[first.sessionId]?.aoBinding?.supersededAt)
        XCTAssertNil(reducer.byID[first.sessionId]?.aoObservation)
        XCTAssertNil(reducer.byID[duplicate.sessionId]?.aoBinding)
        XCTAssertTrue(try XCTUnwrap(reducer.byID[first.sessionId]).hasUnread)
        XCTAssertTrue(try XCTUnwrap(reducer.byID[duplicate.sessionId]).hasUnread)
    }

    func testDSHReaderRejectsUnprovenTerminalAndInvalidProviderHandles() throws {
        for (mode, raw) in [("tui", nativeID), ("chat", "not-a-uuid"), ("chat", "ao-harness:deepseek-harness:\(nativeID)")] {
            try fixture("INSERT INTO sessions VALUES('project-1','project','deepseek-harness','\(mode)','\(raw)','\(raw)','run','run');") { path in
                XCTAssertTrue(AONativeIdentityReader.read(snapshot: snapshot([host(harness: "deepseek-harness")]), path: path).isEmpty)
            }
        }
    }

    func testDSHStandaloneBindingAndIdleSnapshotKeepTheNativeCompletionUnread() throws {
        try fixture("INSERT INTO sessions VALUES('standalone-5','','deepseek-harness','chat','','\(nativeID)','','');") { path in
            var observation = host("standalone-5", harness: "deepseek-harness", project: AOHostMapping.standaloneProjectID)
            observation.role = .worker; observation.orchestration = nil
            observation.activity = .idle; observation.status = "idle"
            var fresh = snapshot([observation]); fresh.nativeIdentities = AONativeIdentityReader.read(snapshot: fresh, path: path)
            let reducer = SessionReducer(); let event = dshCompletion()
            _ = reducer.apply(event, now: now); _ = reducer.applyAOSnapshot(fresh, now: now)
            fresh.observedAt = now.addingTimeInterval(10)
            _ = reducer.applyAOSnapshot(fresh, now: fresh.observedAt)
            let bound = try XCTUnwrap(reducer.byID[event.sessionId])
            XCTAssertEqual(bound.aoObservation?.sessionID, "standalone-5")
            XCTAssertEqual(bound.taskResult, .completed)
            XCTAssertTrue(bound.hasUnread)
            XCTAssertEqual(bound.state, .done)
            XCTAssertNil(bound.hostTeamScope)
        }
    }
    func testOpenCodeVersionTaggedHandlesAreDecodedOnlyForTheirHarness() throws {
        for (stored, count) in [("ao-harness:opencode-v2:ses_exact",1),("ao-harness:opencode:ses_exact",0),("ses_exact",0)] {
            try fixture("INSERT INTO sessions VALUES('project-1','project','opencode-v2','chat','','\(stored)','','');") { path in
                let result = AONativeIdentityReader.read(snapshot: snapshot([host(harness: "opencode-v2")]), path: path)
                XCTAssertEqual(result.count, count)
                if count == 1 { XCTAssertEqual(result.first?.nativeSessionID, "ses_exact") }
            }
        }
    }
    func testDuplicateNativeOwnersProjectMismatchAndMissingSchemaFailClosed() throws {
        try fixture("""
            INSERT INTO sessions VALUES('project-1','project','codex','chat','','\(nativeID)','','');
            INSERT INTO sessions VALUES('project-2','project','codex','chat','','\(nativeID)','','');
            """) { path in
            XCTAssertTrue(AONativeIdentityReader.read(snapshot: snapshot([host(), host("project-2")]), path: path).isEmpty)
            XCTAssertTrue(AONativeIdentityReader.read(snapshot: snapshot([host(project: "different")]), path: path).isEmpty)
            XCTAssertTrue(AONativeIdentityReader.read(snapshot: snapshot([host(harness: "pi")]), path: path).isEmpty)
            XCTAssertTrue(AONativeIdentityReader.read(snapshot: snapshot([host()]), path: path + "-missing").isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-missing"))
        }
    }
    func testPiRequiresExactIndexAndDoesNotGuessSessionFileFromUUID() throws {
        try fixture("INSERT INTO sessions VALUES('project-1','project','pi','tui','\(nativeID)','','run-1','run-1');") { path in
            let map = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("map.json")
            let fresh = snapshot([host(harness: "pi")])
            XCTAssertTrue(AONativeIdentityReader.read(snapshot: fresh, path: path, piMap: map.path).isEmpty)
            try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [nativeID: ["sessionId": nativeID, "sessionFile": "/synthetic/exact.jsonl"]]]).write(to: map)
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            let result = AONativeIdentityReader.read(snapshot: fresh, path: path, piMap: map.path)
            XCTAssertEqual(result.first?.nativeSessionID, "pi:/synthetic/exact.jsonl")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        }
    }
    func testHostIdentityNeverCreatesNativeRowsOrRevivesAConflict() throws {
        var fresh = snapshot([host()])
        fresh.nativeIdentities = [.init(sessionID: "project-1", nativeSessionID: nativeID, agentKind: .codex)]
        let reducer = SessionReducer()
        _ = reducer.applyAOSnapshot(fresh, now: now)
        XCTAssertNil(reducer.byID[nativeID])
        var event = AgentEvent(sessionId: nativeID, agentKind: .codex, eventName: "SessionStart", timestamp: now)
        event.aoSessionID = "project-1"; event.aoProjectID = "project"
        _ = reducer.apply(event, now: now)
        event.sessionId = "22222222-2222-4222-8222-222222222222"
        _ = reducer.apply(event, now: now)
        _ = reducer.applyAOSnapshot(fresh, now: now)
        XCTAssertNotNil(reducer.byID[nativeID]?.aoBinding?.conflictedAt)
        XCTAssertNil(reducer.byID[nativeID]?.aoObservation)
    }

    func testPiNativeRowAndUnreadSurviveSnapshotBeforeHostReconfirmation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("sessions.json")
        let store = SessionStore(); store.persistenceURL = path
        var event = AgentEvent(sessionId: "pi:/synthetic/exact.jsonl", agentKind: .pi, eventName: "working", timestamp: now)
        _ = store.apply(event, now: now)
        event.eventName = "done"; event.turnResult = .completed; event.timestamp = now.addingTimeInterval(1)
        _ = store.apply(event, now: event.timestamp)
        store.persistCodexSessions(); XCTAssertNil(store.flushSnapshots().error)
        let restored = SessionStore(); restored.persistenceURL = path; restored.restoreCodexSessions()
        let pi = try XCTUnwrap(restored.session(id: event.sessionId))
        XCTAssertEqual(pi.taskResult, .completed)
        XCTAssertTrue(pi.hasUnread)
        XCTAssertNil(pi.aoBinding, "a persisted Pi result alone cannot assign an AO role")
    }

    func testExplicitNativeReplacementRetiresReaderClaimAndNeverTransfersUnread() throws {
        let reducer = SessionReducer()
        let otherID = "22222222-2222-4222-8222-222222222222"
        for id in [nativeID, otherID] {
            var done = AgentEvent(sessionId: id, agentKind: .codex, eventName: "Stop", timestamp: now)
            done.turnResult = .completed
            _ = reducer.apply(done, now: now)
        }
        var fresh = snapshot([host()])
        fresh.nativeIdentities = [.init(sessionID: "project-1", nativeSessionID: nativeID, agentKind: .codex)]
        _ = reducer.applyAOSnapshot(fresh, now: now)
        fresh.nativeIdentities = [.init(sessionID: "project-1", nativeSessionID: otherID, agentKind: .codex)]
        _ = reducer.applyAOSnapshot(fresh, now: now.addingTimeInterval(1))
        XCTAssertNotNil(reducer.byID[nativeID]?.aoBinding?.supersededAt)
        XCTAssertNil(reducer.byID[nativeID]?.aoObservation)
        XCTAssertEqual(reducer.byID[otherID]?.aoObservation?.sessionID, "project-1")
        XCTAssertTrue(try XCTUnwrap(reducer.byID[nativeID]).hasUnread)
        XCTAssertTrue(try XCTUnwrap(reducer.byID[otherID]).hasUnread)
    }
}
