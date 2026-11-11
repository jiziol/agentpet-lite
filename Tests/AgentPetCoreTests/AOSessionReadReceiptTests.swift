import XCTest
@testable import AgentPetCore

final class AOSessionReadReceiptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1010)
    private let runID = "apprun-11111111-1111-4111-8111-111111111111"
    private func native() -> AgentSession {
        let at = Date(timeIntervalSince1970: 1000)
        var value = AgentSession(id: "native-worker", agentKind: .opencode, state: .done, source: .hook, updatedAt: at, createdAt: at)
        value.notificationVersion = 2; value.readThroughVersion = 1
        value.turnStartedAt = at.addingTimeInterval(0.25); value.turnEndedAt = at.addingTimeInterval(2.721)
        value.opencodeTurnResult = .completed
        value.aoBinding = AOBinding(sessionID: "worker-1", projectID: "proj", agentKind: .opencode, origin: .hookEnvironment, boundAt: at)
        value.aoObservation = AOHostObservation(sessionID: "worker-1", projectID: "proj", role: .worker, harness: "opencode-v2",
            status: "idle", activity: .idle, isTerminated: false, createdAt: at, updatedAt: at, observedAt: now, instanceID: runID)
        return value
    }
    private func receipt() -> AOSessionReadFrame.Receipt {
        .init(sessionId: "worker-1", projectId: "proj", sessionCreatedAt: "1970-01-01T00:16:40Z", conversationId: "conversation-1", branchId: "",
            viewedAt: 1_005_000, readCursor: .init(sequence: 9, revision: 1),
            turns: [.init(id: "turn-1", providerTurnId: "provider-turn", requestedAt: 1_000_000, completedBefore: 1_003_000)])
    }
    func testWholeSecondWirePrecisionCoversActualMillisecondNativeEnd() {
        XCTAssertTrue(receipt().covers(native(), now: now))
    }
    func testAnotherMemberProjectOrIncarnationCannotBeRead() {
        for change in [0, 1, 2] {
            var value = native()
            if change == 0 { value.aoBinding?.sessionID = "other" }
            if change == 1 { value.aoBinding?.projectID = "other" }
            if change == 2 { value.aoObservation?.createdAt = now }
            XCTAssertFalse(receipt().covers(value, now: now))
        }
    }
    func testOldViewedRangeCannotConsumeANewReplyOrRunningAttention() {
        var value = native(); value.notificationVersion = 3
        value.turnStartedAt = Date(timeIntervalSince1970: 1003)
        value.turnEndedAt = Date(timeIntervalSince1970: 1004)
        XCTAssertFalse(receipt().covers(value, now: now))
        for state in [AgentState.working, .waiting] { var active = native(); active.state = state; XCTAssertFalse(receipt().covers(active, now: now)) }
        var read = native(); read.readThroughVersion = read.notificationVersion
        XCTAssertFalse(receipt().covers(read, now: now))
    }
    func testCodexNativeTurnIDMustMatchTheStructuredAOProviderTurn() {
        var value = native(); value.agentKind = .codex; value.codexTurnID = "root-b"
        value.aoBinding?.agentKind = .codex
        value.aoObservation?.harness = "codex"
        XCTAssertFalse(receipt().covers(value, now: now))
        let base = receipt()
        let matching = AOSessionReadFrame.Receipt(sessionId: base.sessionId, projectId: base.projectId,
            sessionCreatedAt: base.sessionCreatedAt, conversationId: base.conversationId, branchId: base.branchId,
            viewedAt: base.viewedAt, readCursor: base.readCursor,
            turns: [.init(id: "turn-1", providerTurnId: "codex:1:conversation:rootroot-b", requestedAt: 1_000_000, completedBefore: 1_003_000)])
        XCTAssertTrue(matching.covers(value, now: now))
    }
    func testAmbiguousIntervalsDoNotProveTheNativeTurnWasViewed() {
        let base = receipt()
        let ambiguous = AOSessionReadFrame.Receipt(sessionId: base.sessionId, projectId: base.projectId, sessionCreatedAt: base.sessionCreatedAt,
            conversationId: base.conversationId, branchId: base.branchId, viewedAt: base.viewedAt, readCursor: base.readCursor, turns: base.turns + base.turns)
        XCTAssertFalse(ambiguous.covers(native(), now: now))
    }
    func testAFrontPageReadDoesNotAcknowledgeAnApproval() {
        var value = native(); value.pendingApproval = .init(requestId: "request-1", toolName: "Bash", summary: "approval")
        XCTAssertFalse(receipt().covers(value, now: now))
    }
    func testPreviouslyConsumedViewingFactCannotClearALaterNotificationVersion() {
        var value = native(); value.notificationVersion = 3
        value.readAt = Date(timeIntervalSince1970: receipt().viewedAt / 1000)
        XCTAssertFalse(receipt().covers(value, now: now), "the persisted native read date fences replay even across Pet restarts")
    }
    func testCapabilityRequiresItsOwnVersionGenerationAndFreshPublisher() {
        let run = AORunFile(port: 43123, pid: 77, appRunID: runID)
        let frame = AOSessionReadFrame(version: 1, capabilities: ["session-read.v1"], instanceId: "22222222-2222-4222-8222-222222222222",
            appRunId: runID, appPath: "/Applications/AO.app", pid: 123, updatedAt: now.timeIntervalSince1970 * 1000, receipts: [receipt()])
        XCTAssertTrue(frame.isCurrent(run: run, now: now))
        XCTAssertFalse(frame.isCurrent(run: .init(port: 43123, pid: 77, appRunID: "other-run"), now: now))
        XCTAssertFalse(frame.isCurrent(run: run, now: now.addingTimeInterval(16)))
    }
}
