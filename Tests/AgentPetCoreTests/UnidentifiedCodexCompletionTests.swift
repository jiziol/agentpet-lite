import XCTest
@testable import AgentPetCore

final class UnidentifiedCodexCompletionTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 100)

    func testBareCompletionHookIsExcludedWithoutChangingReadState() {
        let store = SessionStore()
        store.apply(AgentEvent(sessionId: "unknown", agentKind: .codex, eventName: "UserPromptSubmit", timestamp: at), now: at)
        XCTAssertFalse(store.session(id: "unknown")!.isUnidentifiedCodexCompletion)
        let end = at.addingTimeInterval(2)
        store.apply(AgentEvent(sessionId: "unknown", agentKind: .codex, eventName: "Stop", timestamp: end), now: end)
        let completed = store.session(id: "unknown")!
        XCTAssertTrue(completed.isUnidentifiedCodexCompletion)
        XCTAssertTrue(completed.hasUnread)
        XCTAssertNil(completed.readAt)
        XCTAssertTrue(store.sorted.filter { !$0.isUnidentifiedCodexCompletion }.isEmpty)
        XCTAssertEqual(store.session(id: "unknown"), completed)
    }

    func testLateNativeMetadataRestoresCompletedConversation() {
        let store = SessionStore()
        store.apply(AgentEvent(sessionId: "known", agentKind: .codex, eventName: "Stop", timestamp: at), now: at)
        XCTAssertTrue(store.session(id: "known")!.isUnidentifiedCodexCompletion)
        store.updateCodexMetadata(id: "known", record: CodexMetadata.Record(title: "Real task", model: nil, rolloutPath: nil, isDesktop: true), home: "/isolated")
        XCTAssertFalse(store.session(id: "known")!.isUnidentifiedCodexCompletion)
        XCTAssertTrue(store.session(id: "known")!.hasUnread)
        XCTAssertNil(store.session(id: "known")!.readAt)
        XCTAssertEqual(store.sorted.filter { !$0.isUnidentifiedCodexCompletion }.count, 1)
    }

    func testIdentifiedTasksAndOtherAgentsRemainVisible() {
        var session = AgentSession(id: "test", agentKind: .codex, state: .done, source: .hook, updatedAt: at)
        for state: AgentState in [.working, .waiting] {
            var active = session; active.state = state
            XCTAssertFalse(active.isUnidentifiedCodexCompletion)
        }
        var titled = session; titled.title = "CLI task"
        XCTAssertFalse(titled.isUnidentifiedCodexCompletion)
        var desktop = session; desktop.codexDesktop = true
        XCTAssertFalse(desktop.isUnidentifiedCodexCompletion)
        var terminal = session; terminal.terminalProgram = "iTerm.app"
        XCTAssertFalse(terminal.isUnidentifiedCodexCompletion)
        var native = session; native.codexTurnID = "native-turn"
        XCTAssertFalse(native.isUnidentifiedCodexCompletion)
        var input = session; input.humanRequests = [HumanRequest(id: "question", kind: .choice, createdAt: at)]
        XCTAssertFalse(input.isUnidentifiedCodexCompletion)
        for kind: AgentKind in [.antigravity, .opencode, .claude, .pi] {
            session.agentKind = kind
            XCTAssertFalse(session.isUnidentifiedCodexCompletion)
        }
    }

    func testLateNativeResultRestoresUntitledCompletion() {
        let store = SessionStore()
        store.apply(AgentEvent(sessionId: "known", agentKind: .codex, eventName: "Stop", timestamp: at), now: at)
        XCTAssertTrue(store.session(id: "known")!.isUnidentifiedCodexCompletion)
        store.reconcileCodexLifecycle(id: "known", event: CodexLifecycle(turnID: "real-turn", timestamp: at.addingTimeInterval(1), startedAt: at.addingTimeInterval(-2), result: .completed))
        XCTAssertFalse(store.session(id: "known")!.isUnidentifiedCodexCompletion)
        XCTAssertTrue(store.session(id: "known")!.hasUnread)
        XCTAssertEqual(store.session(id: "known")!.taskResult, .completed)
    }
}
