import XCTest
import AgentPetCore
@testable import agentpet

/// Bounded invalidation of a cached Team verification (defect C). The clock is
/// keyed by the exact association, so a changed identity never inherits it.
final class TeamVerificationWatchdogTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 100)
    private func key(_ id: String, conversation: String? = "chat_a", team: String? = "team_a",
                     role: AionUiConversation.TeamRole? = .lead) -> AionUiVerificationKey {
        .init(sessionID: id, conversationID: conversation, teamID: team, teamRole: role)
    }

    func testTransientFailureKeepsHistoryInsideTheWindow() {
        var watchdog = TeamVerificationWatchdog()
        XCTAssertFalse(watchdog.noteUnverifiable(key("a"), now: at))
        XCTAssertTrue(watchdog.isPending("a"))
        XCTAssertFalse(watchdog.noteUnverifiable(key("a"), now: at.addingTimeInterval(TeamVerificationWatchdog.window - 1)))
        // The bounded window is measured from the first failure.
        XCTAssertTrue(watchdog.noteUnverifiable(key("a"), now: at.addingTimeInterval(TeamVerificationWatchdog.window)))
    }

    func testSuccessfulRecheckHealsAndRestartsTheWindow() {
        var watchdog = TeamVerificationWatchdog()
        _ = watchdog.noteUnverifiable(key("a"), now: at)
        watchdog.noteVerified(key("a"))
        XCTAssertFalse(watchdog.isPending("a"))
        XCTAssertFalse(watchdog.noteUnverifiable(key("a"), now: at.addingTimeInterval(TeamVerificationWatchdog.window * 10)))
        XCTAssertTrue(watchdog.noteUnverifiable(key("a"), now: at.addingTimeInterval(TeamVerificationWatchdog.window * 10
                                                                                + TeamVerificationWatchdog.window)))
    }

    func testEachIdentityIsTrackedSeparately() {
        var watchdog = TeamVerificationWatchdog()
        _ = watchdog.noteUnverifiable(key("a"), now: at)
        XCTAssertFalse(watchdog.noteUnverifiable(key("b"), now: at.addingTimeInterval(TeamVerificationWatchdog.window)))
        XCTAssertTrue(watchdog.noteUnverifiable(key("a"), now: at.addingTimeInterval(TeamVerificationWatchdog.window)))
        // A changed conversation/team/role is a different association: its clock
        // starts fresh instead of inheriting the old failure.
        _ = watchdog.noteUnverifiable(key("c"), now: at)
        XCTAssertFalse(watchdog.noteUnverifiable(key("c", conversation: "chat_other"),
                                                 now: at.addingTimeInterval(TeamVerificationWatchdog.window)))
        XCTAssertFalse(watchdog.noteUnverifiable(key("c", role: .teammate),
                                                 now: at.addingTimeInterval(TeamVerificationWatchdog.window)))
        XCTAssertFalse(watchdog.noteUnverifiable(key("c", team: "team_b"),
                                                 now: at.addingTimeInterval(TeamVerificationWatchdog.window)))
    }

    func testRetainDropsUntrackedSessions() {
        var watchdog = TeamVerificationWatchdog()
        _ = watchdog.noteUnverifiable(key("a"), now: at)
        _ = watchdog.noteUnverifiable(key("b"), now: at)
        watchdog.retain(["b"])
        XCTAssertFalse(watchdog.isPending("a"))
        XCTAssertTrue(watchdog.isPending("b"))
    }
}
