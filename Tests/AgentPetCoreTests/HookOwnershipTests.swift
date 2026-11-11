import XCTest
@testable import AgentPetCore
final class HookOwnershipTests: XCTestCase {
    func testOwnershipAndFileTransactions() throws {
        XCTAssertGreaterThan(try HookOwnershipScenarios.runAll(), 80)
    }
}
