import XCTest
import AgentPetCore
@testable import agentpet

final class StatusLampTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 100)
    private func session(_ state: AgentState, result: CodexTurnResult? = nil) -> AgentSession {
        var session = AgentSession(id: "lamp", agentKind: .codex, state: state,
                                   source: .hook, updatedAt: at)
        session.codexTurnResult = result
        session.notificationVersion = 1
        session.displayRevision = 2
        return session
    }
    private func acknowledge(_ session: inout AgentSession) {
        session.readThroughVersion = session.notificationVersion
        session.readAt = at
        session.readDisplayRevision = session.displayRevision
    }

    func testSuccessAndFailureStayDistinctUntilTheirCurrentNotificationIsRead() {
        for (result, lamp) in [(CodexTurnResult.completed, BubblePresentation.Row.Lamp.success), (.failed, .failure)] {
            var s = session(.done, result: result)
            XCTAssertEqual(BubblePresentation.Row(session: s).lamp, lamp)
            XCTAssertTrue(BubblePresentation.Row(session: s).dotIsLit)
            acknowledge(&s)
            let read = BubblePresentation.Row(session: s)
            XCTAssertEqual(read.lamp, .off)
            XCTAssertFalse(read.dotSpins)
            s.notificationVersion += 1
            XCTAssertEqual(BubblePresentation.Row(session: s).lamp, lamp)
        }
    }

    func testStaleDisplayReceiptCannotExtinguishNewResult() {
        var s = session(.done, result: .failed)
        acknowledge(&s)
        s.displayRevision = 3
        XCTAssertEqual(BubblePresentation.Row(session: s).lamp, .failure)
    }

    func testWorkingKeepsBlueAfterClickAndWaitingReadRetainsPendingApproval() {
        var working = session(.working)
        acknowledge(&working)
        XCTAssertEqual(BubblePresentation.Row(session: working).lamp, .running)
        var waiting = session(.waiting)
        waiting.pendingApproval = .init(requestId: "request", toolName: "Bash", summary: "command")
        XCTAssertEqual(BubblePresentation.Row(session: waiting).lamp, .attention)
        acknowledge(&waiting)
        XCTAssertEqual(BubblePresentation.Row(session: waiting).lamp, .off)
        XCTAssertNotNil(waiting.pendingApproval)
        XCTAssertEqual(waiting.state, .waiting)
        waiting.notificationVersion += 1
        XCTAssertEqual(BubblePresentation.Row(session: waiting).lamp, .attention)
    }

    func testStoppedAndUnknownResultsDoNotBecomeSuccess() {
        XCTAssertEqual(BubblePresentation.Row(session: session(.done, result: .cancelled)).lamp, .off)
        let unknown = BubblePresentation.Row(session: session(.done))
        XCTAssertEqual(unknown.lamp, .unknown)
        XCTAssertEqual(unknown.indicatorLabel, "结果未知，未读")
        var disconnected = session(.done)
        disconnected.agentKind = .opencode
        disconnected.opencodeTurnResult = .completed
        disconnected.opencodeDisconnectedAt = at
        XCTAssertEqual(BubblePresentation.Row(session: disconnected).lamp, .unknown)
    }

    func testReadingOneSessionDoesNotExtinguishOtherSessions() {
        var success = session(.done, result: .completed)
        acknowledge(&success)
        let others = [session(.working), session(.waiting), session(.done, result: .failed)]
        XCTAssertEqual(([success] + others).map { BubblePresentation.Row(session: $0).lamp },
                       [.off, .running, .attention, .failure])
        XCTAssertEqual(BubblePresentation.Row(session: session(.idle)).lamp, .unknown)
        var idle = session(.idle); idle.notificationVersion = 0
        XCTAssertEqual(BubblePresentation.Row(session: idle).lamp, .off)
    }
}
