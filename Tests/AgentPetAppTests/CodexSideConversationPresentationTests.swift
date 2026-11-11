import XCTest
@testable import AgentPetCore
@testable import agentpet

final class CodexSideConversationPresentationTests: XCTestCase {
    func testMissingExitLogFiltersOnlyConfirmedDesktopOwnerAndPreservesNormalCodex() {
        let at = Date(timeIntervalSince1970: 1_792_200_000)
        var internalTask = AgentSession(id: UUID().uuidString, agentKind: .codex, state: .working,
                                       source: .hook, updatedAt: at, createdAt: at)
        internalTask.codexHome = "/synthetic/codex"
        internalTask.model = "gpt-6-luna"
        internalTask.codexTurnID = "internal-turn"
        internalTask.codexInternalTaskObservedAt = at.addingTimeInterval(1)
        internalTask.codexTransientSource = .init(sessionID: internalTask.id, home: "/synthetic/codex",
            process: "pid:12345:12345678-1234-4234-8234-123456789abc", lastNativeAt: at)
        internalTask.notificationVersion = 4; internalTask.readThroughVersion = 1
        internalTask.codexInternalTaskKind = "desktopTransientCandidate"
        var ordinary = AgentSession(id: UUID().uuidString, agentKind: .codex, state: .working,
                                    source: .hook, updatedAt: at)
        ordinary.model = "gpt-6-luna"
        XCTAssertEqual(BubblePresentation.visible([internalTask, ordinary], settings: .init()).count, 2)
        internalTask.codexInternalTaskKind = "desktopProcessExited"
        let before = internalTask
        for grouping: BubbleSessionGrouping in [.byKind, .allSessions] {
            let settings = BubblePresentation.Configuration(sessionGrouping: grouping, now: at)
            XCTAssertEqual(BubblePresentation.groups([internalTask, ordinary], settings: settings).map(\.session.id), [ordinary.id])
        }
        XCTAssertFalse(BubblePresentation.Row(session: internalTask).canFocusTerminal)
        XCTAssertTrue(SessionNotificationPolicy.effects(before: nil, session: internalTask).isEmpty)
        var speech = PetSpeechState(globalCooldown: 0)
        speech.receive(.init(fence: .init(internalTask, turnID: "internal-turn"), itemID: "message",
            timestamp: at, revision: 0, content: .snapshot("Internal reply")), session: internalTask, now: at)
        XCTAssertTrue(speech.visible(sessions: [internalTask], hiddenKinds: [], now: at).isEmpty)
        XCTAssertEqual(internalTask, before)
        XCTAssertEqual(internalTask.state, .working)
        XCTAssertNil(internalTask.codexTurnResult)
    }

    func testSideChatDoesNotEnterTasksSpeechOrNavigationButNormalCodexRemains() {
        let at = Date(timeIntervalSince1970: 1_792_200_000)
        var side = AgentSession(id: UUID().uuidString, agentKind: .codex, state: .working,
                                source: .hook, updatedAt: at)
        side.createdAt = at; side.turnStartedAt = at; side.codexTurnID = "side-turn"
        side.codexInternalTaskKind = "desktopSideConversation"
        side.codexInternalTaskObservedAt = at.addingTimeInterval(1)
        side.notificationVersion = 4; side.readThroughVersion = 1
        var normal = AgentSession(id: UUID().uuidString, agentKind: .codex, state: .working,
                                  source: .hook, updatedAt: at)
        normal.codexDesktop = true; normal.codexHasNativeThreadRecord = true
        for state: AgentState in [.working, .waiting, .done, .idle] {
            side.state = state
            XCTAssertEqual(BubblePresentation.visible([side, normal], settings: .init()).map(\.id), [normal.id])
            XCTAssertFalse(BubblePresentation.Row(session: side).canFocusTerminal)
        }
        var speech = PetSpeechState(globalCooldown: 0)
        let candidate = PetSpeechState.Candidate(fence: .init(side, turnID: "side-turn"), itemID: "message",
            timestamp: at, revision: 0, content: .snapshot("Side chat reply"))
        speech.receive(candidate, session: side, now: at)
        XCTAssertTrue(speech.visible(sessions: [side], hiddenKinds: [], now: at).isEmpty)
        XCTAssertEqual(side.readThroughVersion, 1)
        XCTAssertEqual(side.notificationVersion, 4)
        XCTAssertTrue(BubblePresentation.Row(session: normal).canFocusTerminal)
    }
}
