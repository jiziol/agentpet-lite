import XCTest
@testable import agentpet
@testable import AgentPetCore

final class DSHLiveSignalsTests: XCTestCase {
    func testOnlyFreshValidLiveMetadataCanConfirmTheMatchingProfile() {
        let now = Date()
        var value = DSHObservation(schema: 1, profileID: String(repeating: "a", count: 24),
            hostID: UUID().uuidString, hostStartedAt: now.addingTimeInterval(-60), nativeSessionID: "fixture",
            revision: 1, nativeSeq: 1, turn: nil, phase: .idle, pending: [], baseline: true, heartbeat: false, gap: false)
        var event = AgentEvent(sessionId: value.sessionKey, agentKind: .dsh, eventName: "dsh/observation", timestamp: now)
        event.dsh = value
        var live = DSHLiveSignals()
        XCTAssertNil(live.signal(profileID: value.profileID, since: now.addingTimeInterval(-1)))
        var replay = event; replay.timestamp = now.addingTimeInterval(-10)
        live.receive(replay, at: now)
        XCTAssertNil(live.signal(profileID: value.profileID, since: now.addingTimeInterval(-1)))
        live.receive(event, at: now)
        XCTAssertNotNil(live.signal(profileID: value.profileID, since: now))
        XCTAssertNil(live.signal(profileID: String(repeating: "b", count: 24), since: now))
        XCTAssertNil(live.signal(profileID: value.profileID, since: now.addingTimeInterval(1)))
        // A repeated/stale observation cannot freshen its reception time.
        live.receive(event, at: now.addingTimeInterval(2))
        XCTAssertNil(live.signal(profileID: value.profileID, since: now.addingTimeInterval(1)))
        value.revision += 1; event.dsh = value
        live.receive(event, at: now.addingTimeInterval(2))
        XCTAssertNotNil(live.signal(profileID: value.profileID, since: now.addingTimeInterval(1)))
    }
}
