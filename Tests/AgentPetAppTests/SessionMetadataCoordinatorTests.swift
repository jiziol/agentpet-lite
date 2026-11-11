import XCTest
import AgentPetCore
@testable import agentpet

@MainActor
final class SessionMetadataCoordinatorTests: XCTestCase {
    private func session() -> AgentSession {
        .init(id: "synthetic", agentKind: .codex, state: .working, source: .hook, updatedAt: Date(timeIntervalSince1970: 100))
    }
    private func waitForIdle(_ coordinator: SessionMetadataCoordinator) async {
        for _ in 0..<200 {
            if coordinator.runningCount == 0 && coordinator.pendingCount == 0 { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("metadata did not drain")
    }
    func testBoundedConcurrencyQueueAndLatestPendingValue() async {
        let s = session(); let gate = DispatchSemaphore(value: 0); defer { gate.signal() }
        let started = expectation(description: "background reader started")
        let coordinator = SessionMetadataCoordinator(concurrency: 1, capacity: 2, current: { _ in s })
        var values: [Int] = []
        coordinator.read(s, purpose: "busy", load: { started.fulfill(); gate.wait(); return 0 }, apply: { values.append($0) })
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(coordinator.read(s, purpose: "queued", load: { 1 }, apply: { values.append($0) }))
        XCTAssertTrue(coordinator.read(s, purpose: "queued", force: true, load: { 2 }, apply: { values.append($0) }))
        XCTAssertTrue(coordinator.read(s, purpose: "other", load: { 3 }, apply: { values.append($0) }))
        XCTAssertFalse(coordinator.read(s, purpose: "overflow", load: { 4 }, apply: { values.append($0) }))
        XCTAssertEqual(coordinator.runningCount, 1); XCTAssertEqual(coordinator.pendingCount, 2)
        gate.signal(); await waitForIdle(coordinator)
        XCTAssertEqual(values, [0, 2, 3])
    }
    func testLateMetadataRejectedForReplacedInstanceAndFreshInstanceNotThrottled() async {
        let old = session(); var current = old
        let gate = DispatchSemaphore(value: 0); defer { gate.signal() }
        let started = expectation(description: "reader")
        let coordinator = SessionMetadataCoordinator(concurrency: 1, current: { _ in current })
        var values: [String] = []
        coordinator.read(old, purpose: "title", interval: 30, now: old.updatedAt, load: { started.fulfill(); gate.wait(); return "old" }, apply: { values.append($0) })
        await fulfillment(of: [started], timeout: 1)
        current.createdAt = old.createdAt.addingTimeInterval(1)
        XCTAssertTrue(coordinator.read(current, purpose: "title", interval: 30, now: current.createdAt, load: { "fresh" }, apply: { values.append($0) }))
        gate.signal(); await waitForIdle(coordinator)
        XCTAssertEqual(values, ["fresh"])
    }
    func testRemovalAndStopRejectLateResultsAndStopDoesNotStartQueuedIO() async {
        let s = session(); var current: AgentSession? = s
        let gate = DispatchSemaphore(value: 0); defer { gate.signal() }
        let started = expectation(description: "reader")
        let coordinator = SessionMetadataCoordinator(concurrency: 1, current: { _ in current })
        var values: [String] = []
        coordinator.read(s, purpose: "title", load: { started.fulfill(); gate.wait(); return "late" }, apply: { values.append($0) })
        await fulfillment(of: [started], timeout: 1)
        coordinator.read(s, purpose: "model", load: { XCTFail("queued IO started after stop"); return "queued" }, apply: { values.append($0) })
        current = nil; coordinator.retain([]); XCTAssertEqual(coordinator.pendingCount, 0)
        coordinator.stop(); gate.signal()
        XCTAssertFalse(coordinator.read(s, purpose: "title", load: { "new" }, apply: { values.append($0) }))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(values.isEmpty)
    }
    func testHiddenCodexCompletionRetainedUntilStoreRemovalAndStopClearsOwnership() {
        var s = session(); s.state = .done
        XCTAssertTrue(s.isUnidentifiedCodexCompletion)
        let coordinator = SessionObservationCoordinator(current: { _ in s }, receive: { _ in XCTFail("unexpected event") }, human: { _,_,_,_ in XCTFail("unexpected input") })
        coordinator.reconcile([s])
        XCTAssertEqual(coordinator.trackedIDs, [s.id])
        coordinator.reconcile([]); XCTAssertTrue(coordinator.trackedIDs.isEmpty)
        coordinator.reconcile([s]); coordinator.stop(); XCTAssertTrue(coordinator.trackedIDs.isEmpty)
    }
    func testNativeTurnBeforeFirstHookStillReachesStoreThroughInstanceOwner() async throws {
        let s = session()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("rollout.jsonl")
        try Data("{\"type\":\"event_msg\",\"timestamp\":90,\"payload\":{\"type\":\"task_started\",\"turn_id\":\"before-hook\"}}\n".utf8).write(to: path)
        let received = expectation(description: "earlier native turn")
        let coordinator = SessionObservationCoordinator(current: { _ in s }, receive: { observation in
            guard case .codexLifecycle(let id, let event) = observation.payload else { return }
            XCTAssertEqual(id, s.id); XCTAssertEqual(event.timestamp, Date(timeIntervalSince1970: 90))
            received.fulfill()
        }, human: { _,_,_,_ in })
        coordinator.reconcile([s]); coordinator.watchCodex(s, path: path.path)
        await fulfillment(of: [received], timeout: 1)
        coordinator.stop()
    }

}
