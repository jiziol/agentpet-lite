import XCTest
import AgentPetCore
@testable import agentpet

@MainActor
final class AgentIconsTests: XCTestCase {
    /// Every kind offered in the brand-logo picker must actually decode to an
    /// image; a kind listed there without artwork would show a blank cell.
    func testEveryBrandKindHasAnImage() {
        for kind in AgentIcons.brandKinds {
            XCTAssertNotNil(AgentIcons.image(for: kind), "\(kind.rawValue) has no brand image")
        }
    }

    func testRetiredBrandArtIsAbsentAndMaintainedEditorsShareScope() {
        for kind in AgentPetCore.RetiredAgentRegistry.kinds { XCTAssertNil(AgentIcons.image(for: kind)) }
        XCTAssertEqual(BubbleMessages.editableAgents, AgentPetCore.AgentCatalog.maintainedKinds)
    }
}
