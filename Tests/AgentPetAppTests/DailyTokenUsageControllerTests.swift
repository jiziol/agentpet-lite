import XCTest
import Combine
import AgentPetCore
@testable import agentpet

@MainActor
final class DailyTokenUsageControllerTests: XCTestCase {
    override nonisolated func setUpWithError() throws { try TestIsolation.require() }

    func testTimerCollectsWithoutOpeningHUDAndDoesNotResetStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-timer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = TokenUsageInstance(source: .codex, root: root)
        let repeated = expectation(description: "Background timer refreshes repeatedly")
        let changes = PassthroughSubject<Void, Never>()
        var inspections = 0
        let controller = DailyTokenUsageController(url: root.appendingPathComponent("l.sqlite"), mode: "test",
            refreshInterval: 0.05, integrationChanges: changes.eraseToAnyPublisher(), reader: { _, _, _ in TokenReadResult() },
            eligibility: {
                inspections += 1
                if inspections == 3 { repeated.fulfill() }
                return [.init(instance: instance, eligible: true, removed: false)]
            })
        controller.start(); defer { controller.stop() }
        await fulfillment(of: [repeated], timeout: 3)
        XCTAssertTrue(controller.states.first?.enabled == true)
        XCTAssertEqual(controller.states.first?.intervals.count, 1)
        XCTAssertNil(controller.error)
    }

    func testIntegrationChangeDuringRefreshIsReplayedWithoutWaitingForTimer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-change-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = TokenUsageInstance(source: .codex, root: root)
        let inspecting = expectation(description: "First inspection in flight")
        let activated = expectation(description: "Integration event activated collection")
        let changes = PassthroughSubject<Void, Never>()
        var installed = false, first = true
        var continuation: CheckedContinuation<Void, Never>?
        let controller = DailyTokenUsageController(url: root.appendingPathComponent("l.sqlite"), mode: "test",
            refreshInterval: 600, integrationChanges: changes.eraseToAnyPublisher(), reader: { _, _, _ in TokenReadResult() },
            eligibility: {
                let eligible = installed
                if first {
                    first = false
                    await withCheckedContinuation { continuation = $0; inspecting.fulfill() }
                }
                return [.init(instance: instance, eligible: eligible, removed: !eligible)]
            })
        let observation = controller.$states.filter { $0.first?.enabled == true }.prefix(1).sink { _ in activated.fulfill() }
        controller.start(); defer { controller.stop(); observation.cancel() }
        await fulfillment(of: [inspecting], timeout: 3)
        installed = true
        changes.send(())
        // Let the event reach the busy guard before the stale inspection finishes.
        await Task.yield()
        continuation?.resume()
        await fulfillment(of: [activated], timeout: 3)
        XCTAssertTrue(controller.states.first?.enabled == true)
        XCTAssertEqual(controller.states.first?.intervals.count, 1)
    }
}
