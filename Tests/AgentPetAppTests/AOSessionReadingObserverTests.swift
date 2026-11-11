import XCTest
@testable import AgentPetCore
@testable import agentpet

@MainActor
final class AOSessionReadingObserverTests: XCTestCase {
    private func fixture(duplicate: Bool = false) -> (AORunFile, AOSessionReadFrame, AgentSession) {
        let now = Date(), runID = "apprun-11111111-1111-4111-8111-111111111111"
        let created = Date(timeIntervalSince1970: 1000)
        var native = AgentSession(id: "native-worker", agentKind: .opencode, state: .done, source: .hook, updatedAt: now, createdAt: created)
        native.notificationVersion = 2; native.readThroughVersion = 1; native.opencodeTurnResult = .completed
        native.turnStartedAt = now.addingTimeInterval(-4); native.turnEndedAt = now.addingTimeInterval(-2)
        native.aoBinding = .init(sessionID: "worker-1", projectID: "proj", agentKind: .opencode, origin: .hookEnvironment, boundAt: now)
        native.aoObservation = .init(sessionID: "worker-1", projectID: "proj", role: .worker, harness: "opencode-v2", status: "idle",
            activity: .idle, isTerminated: false, createdAt: created, updatedAt: now, observedAt: now, instanceID: runID)
        let receipt = AOSessionReadFrame.Receipt(sessionId: "worker-1", projectId: "proj", sessionCreatedAt: "1970-01-01T00:16:40Z",
            conversationId: "conversation-1", branchId: "", viewedAt: now.addingTimeInterval(-0.5).timeIntervalSince1970 * 1000,
            readCursor: .init(sequence: 9, revision: 1), turns: [.init(id: "turn-1", providerTurnId: "provider-turn",
                requestedAt: now.addingTimeInterval(-5).timeIntervalSince1970 * 1000,
                completedBefore: now.addingTimeInterval(-1).timeIntervalSince1970 * 1000)])
        let frame = AOSessionReadFrame(version: 1, capabilities: ["session-read.v1"], instanceId: "22222222-2222-4222-8222-222222222222",
            appRunId: runID, appPath: "/Applications/AO.app", pid: 123, updatedAt: now.timeIntervalSince1970 * 1000,
            receipts: duplicate ? [receipt, receipt] : [receipt])
        return (.init(port: 43123, pid: 77, appRunID: runID), frame, native)
    }
    func testAOInternalViewReadsOnlyTheMatchingNativeMemberAndIsIdempotent() async {
        let (run, frame, original) = fixture(); var current = original; var calls = 0
        var other = AgentSession(id: "other-native", agentKind: .opencode, state: .done, source: .hook,
            updatedAt: original.updatedAt, createdAt: original.createdAt)
        other.notificationVersion = 2; other.readThroughVersion = 1
        other.turnStartedAt = original.turnStartedAt; other.turnEndedAt = original.turnEndedAt
        other.aoBinding = original.aoBinding; other.aoBinding?.sessionID = "other-worker"
        other.aoObservation = original.aoObservation
        let observer = AOSessionReadingObserver(load: { (run, frame) }, publisherMatches: { _ in true }, enabled: { true },
            sessions: { [current, other] }, markRead: { clicked, _ in
                XCTAssertEqual(clicked.id, current.id); current.readThroughVersion = clicked.notificationVersion; calls += 1; return true
            }, refreshUI: {})
        await observer.refreshNow(); await observer.refreshNow()
        XCTAssertEqual(calls, 1); XCTAssertEqual(current.readThroughVersion, 2); XCTAssertEqual(other.readThroughVersion, 1)
    }
    func testAnUnverifiedPublisherOrDuplicateOwnerCannotRead() async {
        for duplicate in [false, true] {
            let (run, frame, native) = fixture(duplicate: duplicate); var calls = 0
            let observer = AOSessionReadingObserver(load: { (run, frame) }, publisherMatches: { _ in duplicate }, enabled: { true },
                sessions: { [native] }, markRead: { _, _ in calls += 1; return true }, refreshUI: {})
            await observer.refreshNow(); XCTAssertEqual(calls, 0)
        }
    }
    func testDisabledStoppedAndNewNativeRepliesRetainUnread() async {
        let (run, frame, original) = fixture(); var current = original; var enabled = false; var calls = 0
        let observer = AOSessionReadingObserver(load: { (run, frame) }, publisherMatches: { _ in true }, enabled: { enabled },
            sessions: { [current] }, markRead: { _, _ in calls += 1; return true }, refreshUI: {})
        await observer.refreshNow(); XCTAssertEqual(calls, 0)
        enabled = true; current.notificationVersion += 1; current.turnStartedAt = Date(); current.turnEndedAt = Date()
        await observer.refreshNow(); XCTAssertEqual(calls, 0)
        current = original; observer.stop(); await observer.refreshNow(); XCTAssertEqual(calls, 0)
    }
}
