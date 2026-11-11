import Foundation
import XCTest
@testable import AgentPetCore

final class DSHIntegrationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 10_000)
    private func event(_ revision: Int = 1, turn: Int = 1, phase: DSHObservation.Phase = .working,
                       result: DSHObservation.Result? = nil, baseline: Bool = false,
                       pending: [DSHObservation.Pending] = []) -> AgentEvent {
        let observation = DSHObservation(schema: 1, profileID: String(repeating: "a", count: 24),
            hostID: "11111111-1111-4111-8111-111111111111", hostStartedAt: base.addingTimeInterval(-10),
            nativeSessionID: "session-A", revision: revision, nativeSeq: revision,
            turn: turn, phase: phase, result: result, pending: pending,
            startedAt: base, endedAt: phase == .done ? base.addingTimeInterval(Double(revision)) : nil,
            baseline: baseline, heartbeat: false, gap: false,
            navigationSocket: "/tmp/agentpet-dsh-501/h-ABC123/nav.sock")
        var value = AgentEvent(sessionId: observation.sessionKey, agentKind: .dsh, eventName: "dsh/observation",
            project: "/tmp/fixture", message: "正在调用 bash", model: "deepseek-test",
            timestamp: base.addingTimeInterval(Double(revision)))
        value.dsh = observation; value.title = "Fixture A"
        return value
    }
    @discardableResult private func apply(_ value: AgentEvent, to store: SessionStore) -> AgentSession? {
        store.apply(value, now: value.timestamp)
    }
    func testWireRoundTrip() throws {
        let value = event(phase: .done, result: .cancelled)
        XCTAssertEqual(try EventCoding.decoder.decode(AgentEvent.self, from: EventCoding.encoder.encode(value)), value)
    }
    func testWorkingIsBlueWithDetails() {
        let session = apply(event(), to: SessionStore())!
        XCTAssertEqual(session.indicator, .running); XCTAssertEqual(session.title, "Fixture A")
        XCTAssertEqual(session.model, "deepseek-test"); XCTAssertEqual(session.message, "正在调用 bash")
    }
    func testClickWhileRunningStaysBlue() {
        let store = SessionStore(); let clicked = apply(event(), to: store)!
        XCTAssertTrue(store.markOpened(clicked, at: base.addingTimeInterval(2)))
        XCTAssertEqual(store.session(id: clicked.id)?.indicator, .running)
    }
    func testPendingOrangeClickGreenAnswerBlue() {
        let store = SessionStore(); apply(event(), to: store)
        let waiting = apply(event(2, pending: [.init(id: "question:1", kind: .choice)]), to: store)!
        XCTAssertEqual(waiting.indicator, .attention); XCTAssertEqual(waiting.message, "等待你的选择")
        XCTAssertTrue(store.markOpened(waiting, at: base.addingTimeInterval(3)))
        XCTAssertEqual(store.session(id: waiting.id)?.indicator, .read)
        let working = apply(event(3), to: store)!
        XCTAssertEqual(working.indicator, .running); XCTAssertEqual(working.humanRequests, [])
    }
    func testPermissionAndReplyLabels() {
        for (kind, message) in [(HumanRequest.Kind.permission, "等待批准"), (.reply, "等待你的回复")] {
            XCTAssertEqual(apply(event(pending: [.init(id: "request", kind: kind)]), to: SessionStore())?.message, message)
        }
    }
    func testOnlyExplicitPendingMakesOrange() {
        XCTAssertEqual(apply(event(), to: SessionStore())?.state, .working)
    }
    func testCompletionUnreadRetainedReadAndQuiet() {
        let store = SessionStore(); apply(event(), to: store)
        let done = apply(event(2, phase: .done, result: .completed), to: store)!
        XCTAssertEqual(done.indicator, .unread)
        store.prune(now: base.addingTimeInterval(2000)); XCTAssertEqual(store.sessions.count, 1)
        store.markOpened(done, at: base.addingTimeInterval(2001))
        XCTAssertEqual(store.sessions.first?.indicator, .read)
        store.prune(now: base.addingTimeInterval(2032)); XCTAssertEqual(store.sessions.first?.state, .idle)
    }
    func testUserStopGreenClearsPendingFreezesTimer() {
        let store = SessionStore(); apply(event(pending: [.init(id: "q", kind: .choice)]), to: store)
        let stopped = apply(event(2, phase: .done, result: .cancelled), to: store)!
        XCTAssertEqual(stopped.indicator, .read); XCTAssertEqual(stopped.message, "任务已停止")
        XCTAssertEqual(stopped.humanRequests, []); XCTAssertEqual(stopped.turnEndedAt, base.addingTimeInterval(2))
        XCTAssertNil(apply(event(3), to: store))
    }
    func testReadQuietCompletionStaysHiddenAcrossHeartbeatsAndHostRestart() {
        let store = SessionStore(); apply(event(), to: store)
        let done = apply(event(2, phase: .done, result: .completed), to: store)!
        XCTAssertTrue(store.markOpened(done, at: base.addingTimeInterval(3)))
        store.prune(now: base.addingTimeInterval(34))
        let hidden = store.session(id: done.id)!
        XCTAssertEqual(hidden.state, .idle)
        for revision in [35, 50] {
            var heartbeat = event(revision, phase: .done, result: .completed)
            heartbeat.dsh?.endedAt = done.dsh?.endedAt; heartbeat.dsh?.heartbeat = true
            let same = apply(heartbeat, to: store)!
            XCTAssertEqual(same.state, .idle); XCTAssertFalse(same.hasUnread)
            XCTAssertEqual(same.displayRevision, hidden.displayRevision)
            XCTAssertEqual(same.notificationVersion, hidden.notificationVersion)
        }
        var restarted = event(51, phase: .done, result: .completed, baseline: true)
        restarted.dsh?.hostID = "22222222-2222-4222-8222-222222222222"
        restarted.dsh?.hostStartedAt = base.addingTimeInterval(50); restarted.dsh?.revision = 1
        restarted.dsh?.endedAt = done.dsh?.endedAt
        let same = apply(restarted, to: store)!
        XCTAssertEqual(same.state, .idle); XCTAssertFalse(same.hasUnread)
        XCTAssertEqual(same.displayRevision, hidden.displayRevision)
        XCTAssertGreaterThan(same.interactionGeneration!, hidden.interactionGeneration!)
    }
    func testStoppedQuietCardStaysHiddenButNewTaskReappears() {
        let store = SessionStore()
        let stopped = apply(event(2, phase: .done, result: .cancelled), to: store)!
        store.prune(now: base.addingTimeInterval(34))
        var heartbeat = event(35, phase: .done, result: .cancelled)
        heartbeat.dsh?.endedAt = stopped.dsh?.endedAt; heartbeat.dsh?.heartbeat = true
        XCTAssertEqual(apply(heartbeat, to: store)?.state, .idle)
        XCTAssertEqual(apply(event(36, turn: 2), to: store)?.indicator, .running)
    }
    func testHiddenCompletedCardRestoresReadStateWithoutSuppressingMissedNewTurn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(); store.persistenceURL = dir.appendingPathComponent("snapshot.json")
        let done = apply(event(2, phase: .done, result: .completed), to: store)!
        store.markOpened(done, at: base.addingTimeInterval(3)); store.prune(now: base.addingTimeInterval(34))
        let restored = SessionStore(); restored.persistenceURL = store.persistenceURL; restored.restoreCodexSessions()
        var baseline = event(35, phase: .done, result: .completed, baseline: true)
        baseline.dsh?.endedAt = done.dsh?.endedAt
        XCTAssertEqual(apply(baseline, to: restored)?.state, .idle)
        XCTAssertEqual(apply(event(36, turn: 2, phase: .done, result: .completed, baseline: true), to: restored)?.indicator, .unread)
    }
    func testFailureAndUnknownAreNotGreenStop() {
        for result in [DSHObservation.Result.failed, .unknown] {
            let value = apply(event(phase: .done, result: result), to: SessionStore())!
            XCTAssertEqual(value.indicator, .unread); XCTAssertFalse(value.isStopped)
        }
    }
    func testColdCompletedHistoryDoesNotCreateUnread() {
        XCTAssertNil(apply(event(phase: .done, result: .completed, baseline: true), to: SessionStore()))
    }
    func testBaselineReconcilesMissedCompletion() {
        let store = SessionStore(); apply(event(), to: store)
        XCTAssertEqual(apply(event(2, phase: .done, result: .completed, baseline: true), to: store)?.indicator, .unread)
    }
    func testDuplicateAndOutOfOrderRejected() {
        let store = SessionStore(); apply(event(3), to: store)
        XCTAssertNil(apply(event(2, phase: .done, result: .completed), to: store))
        XCTAssertNil(apply(event(3), to: store))
    }
    func testOldTurnCannotClobberNewTask() {
        let store = SessionStore(); apply(event(turn: 2), to: store)
        XCTAssertNil(apply(event(2, turn: 1, phase: .done, result: .completed), to: store))
    }
    func testNewTurnInvalidatesEarlierNavigationReceipt() {
        let store = SessionStore(); let clicked = apply(event(phase: .done, result: .completed), to: store)!
        apply(event(2, turn: 2), to: store)
        XCTAssertFalse(store.markOpened(clicked, at: base.addingTimeInterval(3)))
    }
    func testHeartbeatPreservesReadRevisionAndTimer() {
        let store = SessionStore(); let clicked = apply(event(pending: [.init(id: "q", kind: .choice)]), to: store)!
        store.markOpened(clicked, at: base.addingTimeInterval(2))
        var heartbeat = event(2, pending: [.init(id: "q", kind: .choice)]); heartbeat.dsh?.heartbeat = true
        let value = apply(heartbeat, to: store)!
        XCTAssertEqual(value.indicator, .read); XCTAssertEqual(value.displayRevision, clicked.displayRevision)
        XCTAssertEqual(value.turnStartedAt, base)
    }
    func testBridgeLossUnknownAndSameTurnRecovery() {
        let store = SessionStore(); let first = apply(event(), to: store)!
        store.prune(now: base.addingTimeInterval(47))
        XCTAssertEqual(store.session(id: first.id)?.indicator, .unread)
        XCTAssertEqual(store.session(id: first.id)?.message, "会话连接已中断，任务结果未知")
        let recovering = event(48, baseline: true)
        XCTAssertEqual(apply(recovering, to: store)?.indicator, .running)
    }
    func testHeartbeatProtectsLongTask() {
        let store = SessionStore(); apply(event(), to: store)
        for revision in stride(from: 16, through: 601, by: 15) {
            var heartbeat = event(revision); heartbeat.dsh?.heartbeat = true
            apply(heartbeat, to: store); store.prune(now: heartbeat.timestamp)
            XCTAssertEqual(store.sessions.first?.state, .working)
        }
    }
    func testNewHostSupersedesOldConnection() {
        let store = SessionStore(); apply(event(10), to: store)
        var next = event(11); next.dsh?.revision = 1
        next.dsh?.hostID = "22222222-2222-4222-8222-222222222222"; next.dsh?.hostStartedAt = base
        XCTAssertNotNil(apply(next, to: store))
        XCTAssertNil(apply(event(12, phase: .done, result: .completed), to: store))
    }
    func testColdHostSnapshotRefreshesNavigationWithoutCreatingUnreadHistory() {
        let store = SessionStore(); let clicked = apply(event(2, phase: .done, result: .completed), to: store)!
        var other = event(20, phase: .done, result: .completed, baseline: true)
        other.dsh?.nativeSessionID = "session-B"; other.sessionId = other.dsh!.sessionKey
        other.dsh?.hostID = "22222222-2222-4222-8222-222222222222"
        other.dsh?.hostStartedAt = base.addingTimeInterval(10)
        other.dsh?.navigationSocket = "/tmp/agentpet-dsh-501/h-NEW123/nav.sock"
        XCTAssertNil(apply(other, to: store))
        let target = store.dshNavigationTarget(for: clicked, now: other.timestamp)!
        XCTAssertEqual(target.hostID, other.dsh?.hostID)
        XCTAssertEqual(target.nativeSessionID, clicked.dsh?.nativeSessionID)
        XCTAssertEqual(store.session(id: clicked.id), clicked)
        XCTAssertTrue(store.markDSHOpened(clicked, target: target, at: other.timestamp))
        var wrong = target; wrong.nativeSessionID = "other"
        XCTAssertFalse(store.markDSHOpened(clicked, target: wrong, at: other.timestamp))
        XCTAssertEqual(store.session(id: clicked.id)?.indicator, .read)
        XCTAssertNil(store.dshNavigationTarget(for: clicked, now: other.timestamp.addingTimeInterval(46)))
    }
    func testNavigationRegistryRejectsOlderHostAndDifferentProfile() {
        let store = SessionStore(); let clicked = apply(event(), to: store)!
        var next = event(10); next.dsh?.hostID = "22222222-2222-4222-8222-222222222222"
        next.dsh?.hostStartedAt = base; apply(next, to: store)
        XCTAssertNil(apply(event(11), to: store))
        var foreign = event(12); foreign.dsh?.profileID = String(repeating: "b", count: 24)
        foreign.sessionId = foreign.dsh!.sessionKey; foreign.dsh?.hostStartedAt = base.addingTimeInterval(1)
        apply(foreign, to: store)
        XCTAssertEqual(store.dshNavigationTarget(for: clicked, now: foreign.timestamp)?.hostID, next.dsh?.hostID)
        XCTAssertFalse(store.markDSHOpened(clicked, target: clicked.dsh!, at: foreign.timestamp))
    }
    func testNavigationAcknowledgesExpectedHostRebindingButNeverNewDisplayOrTurn() {
        let store = SessionStore(); let clicked = apply(event(2, phase: .done, result: .completed), to: store)!
        var next = event(10, phase: .done, result: .completed, baseline: true)
        next.dsh?.hostID = "22222222-2222-4222-8222-222222222222"; next.dsh?.hostStartedAt = base
        next.dsh?.endedAt = clicked.dsh?.endedAt; apply(next, to: store)
        let target = store.dshNavigationTarget(for: clicked, now: next.timestamp)!
        XCTAssertFalse(store.markOpened(clicked, at: next.timestamp))
        XCTAssertTrue(store.markDSHOpened(clicked, target: target, at: next.timestamp))
        var newTurn = next; newTurn.timestamp = base.addingTimeInterval(11); newTurn.dsh?.turn = 2
        newTurn.dsh?.revision = 11; newTurn.dsh?.endedAt = newTurn.timestamp; apply(newTurn, to: store)
        XCTAssertFalse(store.markDSHOpened(clicked, target: target, at: newTurn.timestamp))
        XCTAssertEqual(store.sessions.first?.indicator, .unread)
    }
    func testWrongProfileAndNativeIdentityRejected() {
        for alter in [0, 1] {
            var value = event()
            if alter == 0 { value.dsh?.profileID = String(repeating: "b", count: 24) }
            else { value.dsh?.nativeSessionID = "other" }
            XCTAssertNil(apply(value, to: SessionStore()))
        }
    }
    func testMalformedAndFutureInputsRejected() {
        var value = event(); value.dsh?.schema = 2; XCTAssertNil(apply(value, to: SessionStore()))
        value = event(); value.dsh?.navigationSocket = "/tmp/other.sock"; XCTAssertNil(apply(value, to: SessionStore()))
        value = event(); value.dsh?.pending = [.init(id: "bad\n", kind: .choice)]; XCTAssertNil(apply(value, to: SessionStore()))
        value = event(); value.dsh?.phase = .done; XCTAssertNil(apply(value, to: SessionStore()))
        value = event(); XCTAssertNil(SessionStore().apply(value, now: base.addingTimeInterval(-100)))
    }
    func testParallelProfilesDoNotMerge() {
        let store = SessionStore(); let first = event(); apply(first, to: store)
        var second = event(); second.dsh?.profileID = String(repeating: "b", count: 24); second.sessionId = second.dsh!.sessionKey
        apply(second, to: store); XCTAssertEqual(store.sessions.count, 2)
    }
    func testPersistenceKeepsUnreadAndDSHBinding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(); store.persistenceURL = directory.appendingPathComponent("snapshot.json")
        let done = apply(event(phase: .done, result: .completed), to: store)!
        let restored = SessionStore(); restored.persistenceURL = store.persistenceURL; restored.restoreCodexSessions()
        XCTAssertEqual(restored.session(id: done.id), done)
        var baseline = event(2, phase: .done, result: .completed, baseline: true)
        baseline.dsh?.endedAt = done.turnEndedAt
        XCTAssertEqual(apply(baseline, to: restored)?.notificationVersion, done.notificationVersion)
    }
    func testHeartbeatsCheckpointOncePerMinuteAndMetadataStillPersistsImmediately() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(); store.persistenceURL = dir.appendingPathComponent("snapshot.json")
        let first = apply(event(), to: store)!
        func diskRevision() -> Int? {
            let restored = SessionStore(); restored.persistenceURL = store.persistenceURL; restored.restoreCodexSessions()
            return restored.session(id: first.id)?.dsh?.revision
        }
        for (revision, at, expected) in [(2, 30.0, 1), (3, 61.0, 3), (4, 62.0, 3)] {
            var heartbeat = event(revision); heartbeat.dsh?.heartbeat = true; heartbeat.timestamp = base.addingTimeInterval(at)
            apply(heartbeat, to: store); XCTAssertEqual(diskRevision(), expected)
        }
        var renamed = event(5); renamed.timestamp = base.addingTimeInterval(63); renamed.title = "Renamed"
        apply(renamed, to: store); XCTAssertEqual(diskRevision(), 5)
    }

}
