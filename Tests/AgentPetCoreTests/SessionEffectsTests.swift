import XCTest
@testable import AgentPetCore

final class SessionEffectsTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testDelayedArchiveReceiptCannotDeleteNewTurnOrRecreatedInstance() throws {
        let reducer = SessionReducer(); reducer.archivingEnabled = true
        reducer.apply(AgentEvent(sessionId: "synthetic", agentKind: .claude, eventName: "working", timestamp: at), now: at)
        reducer.effects.removeAll()
        reducer.apply(AgentEvent(sessionId: "synthetic", agentKind: .claude, eventName: "SessionEnd", timestamp: at), now: at)
        guard case .archive(let request) = try XCTUnwrap(reducer.effects.first) else { return XCTFail("archive request") }
        reducer.finishArchive(ArchiveEffectReceipt(request: request, result: .failed))
        XCTAssertNotNil(reducer.session(id: "synthetic"))
        let nextAt = at.addingTimeInterval(10)
        let new = reducer.apply(AgentEvent(sessionId: "synthetic", agentKind: .claude, eventName: "UserPromptSubmit", timestamp: nextAt), now: nextAt)
        reducer.finishArchive(ArchiveEffectReceipt(request: request, result: .archived))
        XCTAssertEqual(reducer.session(id: "synthetic"), new)
        reducer.remove(id: "synthetic")
        let recreated = reducer.apply(AgentEvent(sessionId: "synthetic", agentKind: .claude, eventName: "working", timestamp: nextAt), now: nextAt)
        reducer.finishArchive(ArchiveEffectReceipt(request: request, result: .pending))
        XCTAssertEqual(reducer.session(id: "synthetic"), recreated)
    }

    func testLivenessUnknownReusedPIDAndStaleReceiptStayDistinct() throws {
        let reducer = SessionReducer()
        var e = AgentEvent(sessionId: "synthetic", agentKind: .opencode, eventName: "working", timestamp: at)
        e.opencodeProcessID = 42; e.opencodeProcessStartedAt = at; e.opencodeTurnID = "one"; e.opencodeNewTurn = true
        let first = try XCTUnwrap(reducer.apply(e, now: at))
        XCTAssertTrue(reducer.reconcileOpencodeLiveness(now: at, receipts: [.init(expected: first, observation: .init(alive: nil, startedAt: nil))]).isEmpty)
        XCTAssertEqual(reducer.session(id: e.sessionId), first)
        e.timestamp = at.addingTimeInterval(1); e.opencodeTurnID = "two"
        let next = try XCTUnwrap(reducer.apply(e, now: e.timestamp))
        XCTAssertTrue(reducer.reconcileOpencodeLiveness(now: e.timestamp, receipts: [.init(expected: first, observation: .init(alive: false, startedAt: nil))]).isEmpty)
        let disconnected = reducer.reconcileOpencodeLiveness(now: e.timestamp, receipts: [.init(expected: next, observation: .init(alive: true, startedAt: at.addingTimeInterval(5)))])
        XCTAssertEqual(disconnected.count, 1)
        XCTAssertNil(disconnected.first?.taskResult)
        XCTAssertFalse(disconnected.first?.isStopped ?? true)
    }

    func testCompletionEffectsPreserveOrderAndNeverFeedCancelledFailedOrDisconnected() {
        var session = AgentSession(id: "synthetic", agentKind: .opencode, project: "/synthetic/project", state: .done, source: .hook, updatedAt: at)
        session.opencodeTurnResult = .completed
        XCTAssertEqual(SessionNotificationPolicy.effects(before: .working, session: session), [
            .notification(title: "project finished", body: "Agent completed its turn"), .completionSound, .completionMeal, .completedSessionUsage])
        for result: CodexTurnResult in [.cancelled, .failed] {
            session.opencodeTurnResult = result
            XCTAssertEqual(SessionNotificationPolicy.effects(before: .working, session: session).count, 1)
        }
        session.opencodeTurnResult = nil; session.opencodeDisconnectedAt = at
        XCTAssertEqual(SessionNotificationPolicy.effects(before: .working, session: session).count, 1)
        XCTAssertTrue(SessionNotificationPolicy.effects(before: .done, session: session).isEmpty)
        session.state = .waiting
        XCTAssertEqual(SessionNotificationPolicy.effects(before: .working, session: session), [.notification(title: "project needs input", body: "Waiting for you"), .waitingSound])
    }

    func testRecoveredDoubleFailureRemovesOnlyUnchangedSourceThroughPruneReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("effect-retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("history")
        try Data("synthetic-block".utf8).write(to: history)
        let store = SessionStore(); let archive = SessionArchiveStore(baseURL: history); store.archiveStore = archive
        store.apply(AgentEvent(sessionId: "synthetic", agentKind: .claude, eventName: "working", timestamp: at), now: at)
        store.apply(AgentEvent(sessionId: "synthetic", agentKind: .claude, eventName: "SessionEnd", timestamp: at), now: at)
        XCTAssertNotNil(store.session(id: "synthetic"))
        try FileManager.default.removeItem(at: history)
        store.prune(now: at.addingTimeInterval(1))
        XCTAssertNil(store.session(id: "synthetic"))
        XCTAssertEqual(try archive.recordsChecked(for: at).count, 1)
    }
}
