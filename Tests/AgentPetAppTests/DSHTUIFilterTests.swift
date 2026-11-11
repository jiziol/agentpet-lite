import XCTest
@testable import AgentPetCore
@testable import agentpet

@MainActor
final class DSHTUIFilterTests: XCTestCase {
    private let key = "agentpet.bubble.showDSHTUI"
    private func withSourcePreference(_ body: () -> Void) {
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        body()
    }
    private func session(_ id: String, _ kind: AgentKind, tui: Bool = false) -> AgentSession {
        var value = AgentSession(id: id, agentKind: kind, state: .working, source: .hook, updatedAt: Date())
        value.dshTUI = tui
        return value
    }

    func testSourceDefaultsOffAndPersistsIndependentOfAgentFilters() {
        withSourcePreference {
            let settings = BubbleSettings()
            let hidden = settings.hiddenKinds
            XCTAssertFalse(settings.showDSHTUI)
            XCTAssertFalse(settings.presentationConfiguration.showDSHTUI)
            settings.showDSHTUI = true
            XCTAssertTrue(BubbleSettings().showDSHTUI)
            XCTAssertEqual(settings.hiddenKinds, hidden)
            settings.showDSHTUI = false
            XCTAssertFalse(BubbleSettings().showDSHTUI)
        }
    }

    func testDefaultHidesTUIAcrossNativeKindsButKeepsDesktopAndIndependentSessions() {
        let values = [session("desktop", .dsh), session("agy", .antigravity), session("codex", .codex),
                      session("tui-agy", .antigravity, tui: true), session("tui-codex", .codex, tui: true)]
        var config = BubblePresentation.Configuration()
        XCTAssertEqual(Set(BubblePresentation.visible(values, settings: config).map(\.id)), ["desktop", "agy", "codex"])
        config.showDSHTUI = true
        XCTAssertEqual(Set(BubblePresentation.visible(values, settings: config).map(\.id)), Set(values.map(\.id)))
        config.hiddenKinds = [.antigravity]
        XCTAssertEqual(Set(BubblePresentation.visible(values, settings: config).map(\.id)), ["desktop", "codex", "tui-codex"])
    }

    func testPublicRepliesFollowSourceSwitchAndTUIHasNoUnsupportedDesktopNavigation() {
        withSourcePreference {
            let settings = BubbleSettings()
            let tui = session("tui", .antigravity, tui: true)
            XCTAssertFalse(settings.allowsAgentActivity(tui))
            XCTAssertFalse(BubblePresentation.Row(session: tui).canFocusTerminal)
            settings.showDSHTUI = true
            XCTAssertTrue(settings.allowsAgentActivity(tui))
            XCTAssertFalse(BubblePresentation.Row(session: tui).canFocusTerminal)
            XCTAssertTrue(BubblePresentation.Row(session: session("independent", .antigravity)).canFocusTerminal)
        }
    }
}
