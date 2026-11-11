import XCTest
@testable import AgentPetCore

final class AgentCatalogTests: XCTestCase {
    func testMaintainedScopeIsSharedAndComplete() {
        XCTAssertEqual(AgentCatalog.maintainedKinds, [.codex, .antigravity, .opencode, .dsh, .claude, .pi])
        XCTAssertEqual(Set(AgentCatalog.all.map(\.id)).count, 6)
        for kind in AgentCatalog.maintainedKinds where kind != .dsh {
            XCTAssertNotNil(AgentHooks.spec(for: kind))
        }
        XCTAssertNil(AgentHooks.spec(for: .dsh))
        XCTAssertNil(AgentHooks.spec(for: .gemini))
    }
    func testEvidenceDoesNotConflateRetainedCodeWithAcceptance() {
        for agent in AgentCatalog.all where agent.kind == .claude {
            XCTAssertFalse(agent.hosts.flatMap(\.capabilities).contains { $0.acceptance == .verified })
        }
        let dsh = AgentCatalog.all.first { $0.kind == .dsh }!
        XCTAssertEqual(dsh.installation, .externalBridge)
        let pi = AgentCatalog.all.first { $0.kind == .pi }!
        let piHost = pi.hosts.first { $0.host == .aionUi }!
        XCTAssertEqual(piHost.capabilities.first { $0.capability == .navigation }?.acceptance, .verified)
        XCTAssertEqual(piHost.capabilities.first { $0.capability == .lifecycle }?.acceptance, .verified)
        for capability: AgentCapability in [.humanChoice, .permission, .manualStop] {
            XCTAssertNotEqual(piHost.capabilities.first { $0.capability == capability }?.acceptance, .verified)
        }
        let agy = AgentCatalog.all.first { $0.kind == .antigravity }!
        let aion = agy.hosts.first { $0.host == .aionUi }!
        XCTAssertEqual(aion.capabilities.first { $0.capability == .humanChoice }?.acceptance, .hostUnsupported)
        XCTAssertNotEqual(aion.capabilities.first { $0.capability == .permission }?.native, .unsupported)
    }
}
