import XCTest
@testable import AgentPetCore
final class ArchiveReliabilityTests: XCTestCase {
    func testArchiveFailureRecoveryAndRetention() throws {
        XCTAssertGreaterThan(try ArchiveReliabilityScenarios.runAll(), 100)
    }
}
