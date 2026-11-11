import XCTest
@testable import AgentPetCore

final class CodexSideConversationTests: XCTestCase {
    func testSideConversationStaysExcludedAcrossTurnsWithoutAcknowledgingResults() throws {
        let at = Date(timeIntervalSince1970: 1_792_200_000)
        let id = UUID().uuidString, home = "/synthetic/codex"
        let store = SessionStore()
        var event = AgentEvent(sessionId: id, agentKind: .codex, eventName: "UserPromptSubmit",
                               timestamp: at)
        event.codexHome = home
        let expected = try XCTUnwrap(store.apply(event, now: at))
        let evidence = CodexInternalTaskEvidence.Record(sessionID: id, home: home,
            kind: "desktopSideConversation", exitedAt: nil, observedAt: at.addingTimeInterval(1))
        XCTAssertTrue(store.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence))
        var session = try XCTUnwrap(store.session(id: id))
        session.updatedAt = at.addingTimeInterval(60)
        session.notificationVersion = 5; session.readThroughVersion = 2
        for state: AgentState in [.working, .waiting, .done, .idle] {
            session.state = state
            let before = session
            XCTAssertTrue(session.isCodexInternalTask)
            XCTAssertTrue(SessionNotificationPolicy.effects(before: nil, session: session).isEmpty)
            XCTAssertEqual(session, before, "Hiding must preserve lifecycle, unread and read receipts")
        }
        store.updateCodexMetadata(id: id,
            record: .init(title: "Saved conversation", model: nil, rolloutPath: nil, isDesktop: true), home: home)
        let saved = try XCTUnwrap(store.session(id: id))
        XCTAssertFalse(saved.isCodexInternalTask, "Saving to a normal native thread supersedes transient evidence")
        XCTAssertNil(saved.codexInternalTaskKind)
    }

    func testSideConversationEvidenceCannotHideAnInteractiveNativeRouteOrAnotherAgent() {
        var value = AgentSession(id: UUID().uuidString, agentKind: .codex, state: .working,
                                 source: .hook, updatedAt: Date())
        value.codexInternalTaskKind = "desktopSideConversation"
        value.codexInternalTaskObservedAt = value.createdAt.addingTimeInterval(1)
        XCTAssertTrue(value.isCodexInternalTask)
        for mutate: (inout AgentSession) -> Void in [
            { $0.codexHasNativeThreadRecord = true }, { $0.codexDesktop = true },
            { $0.title = "Saved" }, { $0.terminalTTY = "/dev/ttys001" },
            { $0.agentKind = .opencode }, { $0.codexInternalTaskObservedAt = nil }
        ] {
            var normal = value; mutate(&normal)
            XCTAssertFalse(normal.isCodexInternalTask)
        }
    }
}
