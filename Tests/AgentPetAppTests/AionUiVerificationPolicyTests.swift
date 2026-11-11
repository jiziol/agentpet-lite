import XCTest
import AgentPetCore
@testable import agentpet

/// The real host-check decision chain: every unverifiable/matched result ->
/// policy action -> store transition -> what the Team row presents.
final class AionUiVerificationPolicyTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_000)
    private let id = "ses_team"

    private func verification(_ createdAt: Date, role: AionUiConversation.TeamRole? = .lead,
                              teamID: String? = "team_a", conversation: String = "chat_team",
                              at time: Date, launch: String? = nil) -> AionUiVerification {
        .init(conversationID: conversation, teamID: teamID, teamRole: role,
              sessionCreatedAt: createdAt, verifiedAt: time,
              launchEpoch: launch ?? AionUiVerificationLaunch.epoch)
    }

    private func record() -> AionUiMetadata.Record {
        .init(conversation: .init(id: "chat_team", nativeSessionID: id, agentKind: .antigravity,
                                  teamID: "team_a", teamName: "Team Alpha", teamRole: .lead),
              title: "Team Alpha")
    }

    /// A tracked session with a finished turn, before any host check.
    private func tracked() throws -> (SessionStore, AgentSession) {
        let store = SessionStore()
        var event = AgentEvent(sessionId: id, agentKind: .antigravity, eventName: "Stop", timestamp: at)
        event.turnResult = .completed
        let session = try XCTUnwrap(store.apply(event, now: at))
        return (store, session)
    }

    private func teamRow(_ session: AgentSession, now: Date) -> BubblePresentation.Row {
        BubblePresentation.Row(session: session,
                               team: .init(id: "team_a", name: "Team Alpha", leaderMissing: false,
                                           identityUnconfirmed: !BubblePresentation.isCurrentlyVerified(session, now: now),
                                           membersWorking: false))
    }

    func testFirstUnverifiableCheckDropsCurrencyThenRoleThenHeals() throws {
        let (store, applied) = try tracked()
        XCTAssertTrue(AionUiVerificationApplier.apply(record(), for: applied, in: store, verifiedAt: at))
        var session = try XCTUnwrap(store.session(id: id))
        XCTAssertTrue(BubblePresentation.isCurrentlyVerified(session, now: at))
        XCTAssertEqual(session.validAionUiTeam?.teamRole, .lead)

        var watchdog = TeamVerificationWatchdog()
        // First failure: the cached check is no longer current, the role stays.
        let first = AionUiVerificationPolicy.action(for: .notFound, session: session, now: at.addingTimeInterval(1),
                                                    watchdog: &watchdog)
        XCTAssertEqual(first, .invalidate(clearRole: false))
        XCTAssertTrue(store.clearAionUiVerification(id: id, createdAt: applied.createdAt, clearRole: false))
        session = try XCTUnwrap(store.session(id: id))
        XCTAssertFalse(BubblePresentation.isCurrentlyVerified(session, now: at.addingTimeInterval(1)))
        XCTAssertEqual(session.validAionUiTeam?.teamRole, .lead)
        XCTAssertEqual(teamRow(session, now: at.addingTimeInterval(1)).stateLabel, "主Agent已完成，当前无法确认")
        XCTAssertEqual(teamRow(session, now: at.addingTimeInterval(1)).lamp, .unknown)

        // Inside the grace window nothing else changes.
        let inside = AionUiVerificationPolicy.action(for: .unavailable, session: session,
                                                     now: at.addingTimeInterval(30), watchdog: &watchdog)
        XCTAssertEqual(inside, .invalidate(clearRole: false))
        XCTAssertFalse(store.clearAionUiVerification(id: id, createdAt: applied.createdAt, clearRole: false))

        // Past the grace window the verified role is dropped; the raw mark stays.
        let expired = AionUiVerificationPolicy.action(for: .unavailable, session: session,
                                                      now: at.addingTimeInterval(1 + TeamVerificationWatchdog.window),
                                                      watchdog: &watchdog)
        XCTAssertEqual(expired, .invalidate(clearRole: true))
        XCTAssertTrue(store.clearAionUiVerification(id: id, createdAt: applied.createdAt, clearRole: true))
        session = try XCTUnwrap(store.session(id: id))
        XCTAssertNil(session.validAionUiTeam)
        XCTAssertEqual(session.aionUiTeamScope?.teamName, "Team Alpha")
        let degraded = BubblePresentation.Row(session: session,
                                              team: .init(id: "team_a", name: "Team Alpha", leaderMissing: true))
        XCTAssertEqual(degraded.stateLabel, "主Agent状态未知")

        // A later successful check heals the whole chain.
        let healed = AionUiVerificationPolicy.action(for: .matched(record()), session: session,
                                                     now: at.addingTimeInterval(2 + TeamVerificationWatchdog.window),
                                                     watchdog: &watchdog)
        XCTAssertEqual(healed, .apply(record()))
        XCTAssertFalse(watchdog.isPending(id))
        XCTAssertTrue(AionUiVerificationApplier.apply(record(), for: session, in: store,
                                                      verifiedAt: at.addingTimeInterval(2 + TeamVerificationWatchdog.window)))
        session = try XCTUnwrap(store.session(id: id))
        XCTAssertEqual(session.validAionUiTeam?.teamRole, .lead)
        XCTAssertTrue(BubblePresentation.isCurrentlyVerified(session, now: at.addingTimeInterval(2 + TeamVerificationWatchdog.window)))
        XCTAssertEqual(teamRow(session, now: at.addingTimeInterval(2 + TeamVerificationWatchdog.window)).stateLabel,
                       "主Agent回合已完成，团队完成未确认")
    }

    func testAssociationWithoutAVerifiedRoleIsNeverInvalidated() throws {
        let (store, applied) = try tracked()
        // Only a raw mark with no verified role: nothing cached to drop.
        let mark = AionUiConversation(id: "chat_team", nativeSessionID: id, agentKind: .antigravity,
                                      teamID: "team_a", teamName: "Team Alpha", teamRole: nil)
        XCTAssertTrue(store.updateAionUiMetadata(id: id, createdAt: applied.createdAt,
                                                 record: .init(conversation: mark, title: nil), verifiedAt: at))
        let session = try XCTUnwrap(store.session(id: id))
        var watchdog = TeamVerificationWatchdog()
        XCTAssertEqual(AionUiVerificationPolicy.action(for: .notFound, session: session,
                                                       now: at.addingTimeInterval(600), watchdog: &watchdog), .ignore)
        XCTAssertFalse(watchdog.isPending(id))
    }

    /// A verification restored from an old snapshot (or absent at all) is never
    /// current evidence until a fresh check happens.
    func testRestoredSnapshotNeedsAFreshCheck() throws {
        let (store, applied) = try tracked()
        XCTAssertTrue(AionUiVerificationApplier.apply(record(), for: applied, in: store, verifiedAt: at))
        let encoded = try JSONEncoder().encode(try XCTUnwrap(store.session(id: id)))
        var restored = try JSONDecoder().decode(AgentSession.self, from: encoded)
        // Long after the snapshot was written the stored check is history.
        XCTAssertFalse(BubblePresentation.isCurrentlyVerified(restored, now: at.addingTimeInterval(3600)))
        XCTAssertNil(AgentSession(id: id, agentKind: .antigravity, state: .done, source: .hook, updatedAt: at)
            .attestableAionUiVerification)
        // A fresh check makes it current again.
        restored.aionUiVerification = verification(restored.createdAt, at: at.addingTimeInterval(3600))
        XCTAssertTrue(BubblePresentation.isCurrentlyVerified(restored, now: at.addingTimeInterval(3600)))
        // A check persisted at the same instant but by an earlier launch is still
        // history: the relaunch waits for a fresh check.
        var relaunched = try JSONDecoder().decode(AgentSession.self, from: encoded)
        relaunched.aionUiVerification = verification(relaunched.createdAt, at: at, launch: "previous-launch")
        XCTAssertFalse(BubblePresentation.isCurrentlyVerified(relaunched, now: at))
        // A stalled checker also stops being current evidence.
        relaunched.aionUiVerification = verification(relaunched.createdAt, at: at.addingTimeInterval(-61))
        XCTAssertFalse(BubblePresentation.isCurrentlyVerified(relaunched, now: at))
    }

    /// A recreated instance, a replaced conversation, a changed Team or role can
    /// never inherit an earlier verification.
    func testRecreatedOrChangedIdentityCannotInheritVerification() {
        var session = AgentSession(id: id, agentKind: .antigravity, state: .done, source: .hook, updatedAt: at)
        session.createdAt = at
        session.antigravityTurnResult = .completed
        session.notificationVersion = 1
        session.aionUiConversation = .init(id: "chat_team", nativeSessionID: id, agentKind: .antigravity,
                                           teamID: "team_a", teamName: "Team Alpha", teamRole: .lead)
        session.aionUiVerification = verification(session.createdAt, at: at)
        XCTAssertNotNil(session.attestableAionUiVerification)
        var recreated = session
        recreated.createdAt = at.addingTimeInterval(5)
        XCTAssertNil(recreated.attestableAionUiVerification)
        var otherConversation = session
        otherConversation.aionUiConversation = .init(id: "chat_other", nativeSessionID: id, agentKind: .antigravity,
                                                     teamID: "team_a", teamName: "Team Alpha", teamRole: .lead)
        XCTAssertNil(otherConversation.attestableAionUiVerification)
        var otherTeam = session
        otherTeam.aionUiConversation = .init(id: "chat_team", nativeSessionID: id, agentKind: .antigravity,
                                             teamID: "team_b", teamName: "Team Beta", teamRole: .lead)
        XCTAssertNil(otherTeam.attestableAionUiVerification)
        var otherRole = session
        otherRole.aionUiConversation = .init(id: "chat_team", nativeSessionID: id, agentKind: .antigravity,
                                             teamID: "team_a", teamName: "Team Alpha", teamRole: .teammate)
        XCTAssertNil(otherRole.attestableAionUiVerification)
        // Dropping the cached check is the same as never having one.
        var dropped = session
        dropped.aionUiVerification = nil
        XCTAssertNil(dropped.attestableAionUiVerification)
        XCTAssertFalse(BubblePresentation.isCurrentlyVerified(dropped, now: at))
    }

    /// An async host result only applies while the current session still
    /// presents the identity the check was requested for.
    func testStaleAsyncResultCannotCrossAChangedIdentity() throws {
        let (store, applied) = try tracked()
        XCTAssertTrue(AionUiVerificationApplier.apply(record(), for: applied, in: store, verifiedAt: at))
        let matched = try XCTUnwrap(store.session(id: id))
        let requested = AionUiAssociationToken(matched)
        XCTAssertTrue(requested.matches(matched))
        // A navigation update replaces the association while a check is in flight.
        var navigated = matched
        navigated.aionUiConversation = .init(id: "chat_navigated", nativeSessionID: id, agentKind: .antigravity,
                                             teamID: "team_a", teamName: "Team Alpha", teamRole: .lead)
        XCTAssertFalse(requested.matches(navigated), "an old matched result must be rejected")
        // The same guard rejects a stale failure whose clock belongs to the old
        // identity: the new association starts its own grace window instead of
        // inheriting the old one.
        var watchdog = TeamVerificationWatchdog()
        let staleKey = AionUiVerificationKey(matched)
        _ = watchdog.noteUnverifiable(staleKey, now: at)
        XCTAssertEqual(AionUiVerificationPolicy.action(for: .notFound, session: navigated,
                                                        now: at.addingTimeInterval(TeamVerificationWatchdog.window + 1),
                                                        watchdog: &watchdog), .invalidate(clearRole: false))
        XCTAssertTrue(watchdog.isPending(id), "the old association's clock is still the old one")
        // And once the identity is current again the fresh result is applied.
        XCTAssertTrue(AionUiVerificationApplier.apply(record(), for: navigated, in: store, verifiedAt: at.addingTimeInterval(2)))
        XCTAssertEqual(store.session(id: id)?.aionUiConversation?.id, "chat_team")
    }

    /// Regaining currency for an unchanged identity must refresh the bubble
    /// immediately, while an unchanged poll must not cause repeated refreshes
    /// or snapshot writes.
    func testCurrencyFlipRefreshesWithoutRewritingAnUnchangedIdentity() throws {
        let (store, applied) = try tracked()
        XCTAssertTrue(AionUiVerificationApplier.apply(record(), for: applied, in: store, verifiedAt: at),
                      "first success is a real display change")
        let verified = try XCTUnwrap(store.session(id: id))
        XCTAssertFalse(AionUiVerificationApplier.apply(record(), for: verified, in: store,
                                                       verifiedAt: at.addingTimeInterval(2)),
                       "an unchanged identity must not refresh or rewrite")
        // Losing currency is a display change too.
        XCTAssertTrue(store.clearAionUiVerification(id: id, createdAt: applied.createdAt, clearRole: false))
        let lapsed = try XCTUnwrap(store.session(id: id))
        XCTAssertFalse(BubblePresentation.isCurrentlyVerified(lapsed, now: at.addingTimeInterval(3)))
        XCTAssertTrue(AionUiVerificationApplier.apply(record(), for: lapsed, in: store,
                                                      verifiedAt: at.addingTimeInterval(3)),
                      "the currency flip must refresh even though nothing is persisted")
        XCTAssertTrue(BubblePresentation.isCurrentlyVerified(try XCTUnwrap(store.session(id: id)),
                                                            now: at.addingTimeInterval(3)))
    }
}
