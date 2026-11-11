import Foundation
import XCTest
@testable import AgentPetCore
final class DSHAntigravityBindingTests: XCTestCase {
    func testInvalidIdentifiersCannotTriggerAProtocolLookup() {
        for value in ["", "../fake", "session-not-an-agy-uuid"] {
            XCTAssertEqual(DSHAntigravityBinding.read(sessionID: value, home: "/tmp/no-host-data"), .notFound)
        }
    }
}
