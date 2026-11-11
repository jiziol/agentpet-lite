import XCTest
@testable import AgentPetCore
@testable import agentpet

final class EndedTaskDismissalTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1000)
    private func ended(_ id: String, kind: AgentKind = .codex, result: CodexTurnResult = .completed) -> AgentSession {
        var s = AgentSession(id: id, agentKind: kind, state: .done, source: .hook, updatedAt: at)
        s.notificationVersion = 1; s.turnStartedAt = at.addingTimeInterval(-10)
        s.codexTurnID = "turn1"; s.codexTurnResult = result
        s.opencodeTurnID = "turn1"; s.opencodeTurnResult = result
        s.antigravityTurnResult = result
        return s
    }

    func testSuccessFailureCancellationAndUnreadClearWithoutTouchingActiveOrReceipts() {
        let a = ended("a"), b = ended("b", result: .failed), c = ended("c", result: .cancelled)
        var working = ended("work"); working.state = .working
        var waiting = ended("wait"); waiting.state = .waiting
        let sessions = [a,b,c,working,waiting]
        var state = EndedTaskDismissalState(); state.dismiss(sessions, now: at)
        XCTAssertEqual(state.visible(sessions, now: at).map(\.id), ["work","wait"])
        XCTAssertTrue(a.hasUnread); XCTAssertNil(a.readAt)
        XCTAssertFalse(EndedTaskDismissalState.canClear(working))
        XCTAssertFalse(EndedTaskDismissalState.canClear(waiting))
    }

    func testMetadataHeartbeatAndReloadDoNotResurrectButNewTurnDoes() throws {
        var s = ended("same"); s.message = "private body never stored"
        var state = EndedTaskDismissalState(); state.dismiss([s], now: at)
        let data = try XCTUnwrap(state.encoded())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(s.message!))
        state = EndedTaskDismissalState(data: data)
        s.updatedAt = at.addingTimeInterval(30); s.model = "new metadata"; s.notificationVersion = 0
        XCTAssertTrue(state.visible([s], now: at.addingTimeInterval(30)).isEmpty)
        s.codexTurnID = "turn2"
        XCTAssertEqual(state.visible([s], now: at.addingTimeInterval(31)).map(\.id), ["same"])
        XCTAssertEqual(state.count, 0)
    }

    func testActiveTransitionAndFallbackVersionReappear() {
        var native = ended("native"), legacy = ended("legacy", kind: .pi)
        var state = EndedTaskDismissalState(); state.dismiss([native,legacy], now: at)
        native.state = .working
        legacy.notificationVersion += 1
        XCTAssertEqual(state.visible([native,legacy], now: at).count, 2)
        XCTAssertEqual(state.count, 0)
    }

    func testDSHSameNativeTurnAcrossHostRestartIsHiddenAndPendingIsProtected() {
        var s = ended("dsh", kind: .dsh)
        s.dsh = DSHObservation(schema: 1, profileID: String(repeating: "a", count: 24), hostID: UUID().uuidString,
            hostStartedAt: at.addingTimeInterval(-100), nativeSessionID: "dsh", revision: 1,
            nativeSeq: 2, turn: 1, phase: .done, result: .completed, pending: [],
            startedAt: s.turnStartedAt, endedAt: at, baseline: false, heartbeat: false, gap: false, navigationSocket: nil)
        var state = EndedTaskDismissalState(); state.dismiss([s], now: at)
        s.dsh?.hostID = UUID().uuidString; s.dsh?.heartbeat = true; s.notificationVersion = 0
        XCTAssertTrue(state.visible([s], now: at).isEmpty)
        s.dsh?.pending = [.init(id: "approval", kind: .permission)]
        XCTAssertFalse(EndedTaskDismissalState.canClear(s))
        XCTAssertEqual(state.visible([s], now: at).count, 1)
        s.dsh?.pending = []; s.dsh?.result = .unknown
        XCTAssertTrue(EndedTaskDismissalState.canClear(s))
        s.dshDisconnectedAt = at
        XCTAssertTrue(EndedTaskDismissalState.canClear(s))
    }

    private func unknownDSH() -> AgentSession {
        var s = ended("archived-dsh", kind: .dsh)
        s.codexTurnResult = nil
        s.dsh = DSHObservation(schema: 1, profileID: String(repeating: "a", count: 24), hostID: UUID().uuidString,
            hostStartedAt: at.addingTimeInterval(-100), nativeSessionID: "archived-dsh", revision: 1,
            nativeSeq: 2, turn: 1, phase: .done, result: .unknown, pending: [],
            startedAt: s.turnStartedAt, endedAt: at, baseline: false, heartbeat: false, gap: false, navigationSocket: nil)
        s.turnEndedAt = at
        return s
    }

    func testArchivedUnknownResultClearsWithoutNavigationOrReadAndSurvivesHeartbeatAndReload() throws {
        let original = unknownDSH()
        XCTAssertNil(original.taskResult)
        XCTAssertTrue(original.hasUnread)
        XCTAssertNil(original.readAt)
        XCTAssertNil(original.dsh?.navigationSocket)
        XCTAssertTrue(EndedTaskDismissalState.canClear(original))
        var dismissal = EndedTaskDismissalState()
        dismissal.dismiss([original], now: at)
        XCTAssertEqual(dismissal.count, 1)
        XCTAssertTrue(dismissal.visible([original], now: at).isEmpty)
        dismissal = EndedTaskDismissalState(data: try XCTUnwrap(dismissal.encoded()))
        var heartbeat = original
        heartbeat.updatedAt = at.addingTimeInterval(30)
        heartbeat.dsh?.hostID = UUID().uuidString
        heartbeat.dsh?.revision = 9
        heartbeat.dsh?.heartbeat = true
        XCTAssertTrue(dismissal.visible([heartbeat], now: at.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(original.state, .done)
        XCTAssertNil(original.taskResult)
        XCTAssertNil(original.readAt)
        XCTAssertEqual(original.readThroughVersion, 0)
    }

    func testEndedDisconnectedDSHCanClearButActivePendingAndUnprovedEndCannot() {
        var s = unknownDSH()
        s.dsh?.phase = .working; s.dsh?.result = nil; s.dsh?.endedAt = nil
        XCTAssertFalse(EndedTaskDismissalState.canClear(s), "A done UI label alone is not native end evidence")
        s.dshDisconnectedAt = at
        XCTAssertTrue(EndedTaskDismissalState.canClear(s))
        var dismissal = EndedTaskDismissalState(); dismissal.dismiss([s], now: at)
        XCTAssertTrue(dismissal.visible([s], now: at).isEmpty)
        s.state = .working
        XCTAssertFalse(EndedTaskDismissalState.canClear(s))
        XCTAssertEqual(dismissal.visible([s], now: at).map(\.id), [s.id])
        s.state = .waiting
        XCTAssertFalse(EndedTaskDismissalState.canClear(s))
        s = unknownDSH(); s.humanRequests = [.init(id: "approval", kind: .permission, createdAt: at)]
        XCTAssertFalse(EndedTaskDismissalState.canClear(s))
        s = unknownDSH(); s.dsh?.pending = [.init(id: "reply", kind: .reply)]
        XCTAssertFalse(EndedTaskDismissalState.canClear(s))
        s = unknownDSH(); s.dsh?.endedAt = nil
        XCTAssertFalse(EndedTaskDismissalState.canClear(s))
    }

    func testUnknownDismissalReleasesForNewTurnOrConfirmedOutcome() {
        let s = unknownDSH()
        for change in ["turn", "outcome"] {
            var dismissal = EndedTaskDismissalState(); dismissal.dismiss([s], now: at)
            var latest = s
            if change == "turn" { latest.dsh?.turn = 2 }
            else { latest.dsh?.result = .completed }
            XCTAssertEqual(dismissal.visible([latest], now: at).map(\.id), [s.id])
            XCTAssertEqual(dismissal.count, 0)
        }
    }

    func testBoundedRecordsInvalidDataAndExpiry() throws {
        var state = EndedTaskDismissalState()
        state.dismiss((0..<(EndedTaskDismissalState.maxRecords + 100)).map { ended("s\($0)") }, now: at)
        XCTAssertEqual(state.count, EndedTaskDismissalState.maxRecords)
        let data = try XCTUnwrap(state.encoded())
        XCTAssertLessThan(data.count, EndedTaskDismissalState.maxDataBytes)
        XCTAssertEqual(EndedTaskDismissalState(data: data).count, EndedTaskDismissalState.maxRecords)
        XCTAssertEqual(EndedTaskDismissalState(data: Data(repeating: 1, count: 100_000)).count, 0)
        XCTAssertEqual(EndedTaskDismissalState(data: Data(repeating: 1, count: EndedTaskDismissalState.maxDataBytes + 1)).count, 0)
        _ = state.visible([], now: at.addingTimeInterval(7 * 86400))
        XCTAssertEqual(state.count, 0)
    }

    func testLargeBacklogClearsEveryEndedTaskAndSurvivesReload() throws {
        let backlog = (0..<600).map { ended("remote-\($0)") }
        var active = ended("still-working"); active.state = .working
        var waiting = ended("needs-input"); waiting.state = .waiting
        let sessions = backlog + [active, waiting]
        var state = EndedTaskDismissalState()
        state.dismiss(sessions, now: at)
        XCTAssertEqual(state.visible(sessions, now: at).map(\.id), [active.id, waiting.id])
        state = EndedTaskDismissalState(data: try XCTUnwrap(state.encoded()))
        XCTAssertEqual(state.visible(sessions, now: at.addingTimeInterval(30)).map(\.id), [active.id, waiting.id])
        var newTurn = backlog[0]; newTurn.codexTurnID = "new-turn"
        XCTAssertEqual(state.visible([newTurn], now: at.addingTimeInterval(31)).map(\.id), [newTurn.id])
        XCTAssertTrue(backlog.allSatisfy { $0.hasUnread && $0.readAt == nil })
    }
}
