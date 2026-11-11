import XCTest
@testable import AgentPetCore

final class SessionStateCompatibilityTests: XCTestCase {
    func testOldFlatRecordWithoutOptionalFieldsRemainsReadableAndFlat() throws {
        let legacy = Data(#"{"id":"synthetic","agentKind":"codex","state":"working","source":"hook","updatedAt":2,"stateSince":1,"createdAt":0,"codexDesktop":false,"notificationVersion":0,"readThroughVersion":0,"futureUnknownField":"ignored"}"#.utf8)
        var session = try JSONDecoder().decode(AgentSession.self, from: legacy)
        XCTAssertNil(session.attention.humanRequests)
        XCTAssertNil(session.opencodeContext.opencodeProcessStartedAt)
        session.receipt.displayRevision = 7
        session.antigravityContext.antigravityStepFloor = 19
        session.codexContext.codexLifecycleAt = Date(timeIntervalSinceReferenceDate: 9)
        session.hostContext.terminalTTY = "/dev/synthetic"
        let data = try JSONEncoder().encode(session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["displayRevision"] as? Int, 7)
        XCTAssertEqual(object["antigravityStepFloor"] as? Int, 19)
        XCTAssertEqual(object["codexLifecycleAt"] as? Double, 9)
        XCTAssertNil(object["identity"]); XCTAssertNil(object["receipt"]); XCTAssertNil(object["hostContext"])
        XCTAssertEqual(try JSONDecoder().decode(AgentSession.self, from: data), session)
        XCTAssertEqual(session.displayRevision, 7)
        XCTAssertEqual(session.antigravityStepFloor, 19)
    }
}
