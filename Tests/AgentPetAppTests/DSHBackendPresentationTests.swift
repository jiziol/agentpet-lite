import XCTest
@testable import AgentPetCore
@testable import agentpet

final class DSHBackendPresentationTests: XCTestCase {
    func testHostedBackendCannotBeClickedWhileIndependentAntigravityCan() {
        var s = AgentSession(id: UUID().uuidString, agentKind: .antigravity, state: .working, source: .hook, updatedAt: Date())
        XCTAssertTrue(BubblePresentation.Row(session: s).canFocusTerminal)
        s.antigravityFromDSH = true
        XCTAssertFalse(BubblePresentation.Row(session: s).canFocusTerminal)
        s.antigravityFromDSH = false
        XCTAssertTrue(BubblePresentation.Row(session: s).canFocusTerminal)
    }
}
