import XCTest
@testable import AgentPetCore

final class EventSocketReliabilityTests: XCTestCase {
    func testFraming() throws { _ = try SocketTransportScenarios.framing() }
    func testBounds() throws { _ = try SocketTransportScenarios.limits() }
    func testDeadlines() throws { _ = try SocketTransportScenarios.deadlines() }
    func testLifecycle() throws { _ = try SocketTransportScenarios.lifecycle() }
    func testApprovals() throws { _ = try SocketTransportScenarios.approvals() }
}
