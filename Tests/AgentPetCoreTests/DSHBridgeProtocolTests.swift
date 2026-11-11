import Foundation
import XCTest
@testable import AgentPetCore

final class DSHBridgeProtocolTests: XCTestCase {
    private func payload() -> [String: Any] {
        ["schema": 1, "requestID": UUID().uuidString, "profileID": String(repeating: "a", count: 24),
         "hostID": UUID().uuidString, "hostStartedAt": Date().timeIntervalSince1970 - 20,
         "protocolMajor": 1, "capabilities": ["lifecycle.v1", "navigation.v1", "future.v8"],
         "packageVersion": "99.0.0", "clientCount": 1, "eventConnected": true,
         "eventSocket": "/tmp/test-pet.sock", "futureOptionalField": ["ignored": true]]
    }
    private func decode(_ value: [String: Any]) throws -> DSHBridgeProtocol.Status {
        try JSONDecoder().decode(DSHBridgeProtocol.Status.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testProtocolAndCapabilitiesAreIndependentOfPackageVersionAndOptionalFields() throws {
        var value = payload()
        for version in ["0.1.6", "0.1.8", "99.0.0"] {
            value["packageVersion"] = version
            let status = try decode(value)
            XCTAssertTrue(status.valid); XCTAssertTrue(status.compatible); XCTAssertTrue(status.navigationReady)
        }
        value["protocolMajor"] = 2
        XCTAssertFalse(try decode(value).compatible)
        value["protocolMajor"] = 1; value["clientCount"] = 2
        XCTAssertFalse(try decode(value).navigationReady)
    }
    func testInvalidIdentityAndUnboundedCapabilitiesCannotConfirmHealth() throws {
        for (key, invalid) in [("requestID", "bad" as Any), ("hostID", "bad" as Any),
            ("profileID", "bad" as Any), ("clientCount", 5 as Any),
            ("capabilities", ["lifecycle.v1", "lifecycle.v1"] as Any),
            ("capabilities", Array(repeating: "capability", count: 33) as Any),
            ("eventSocket", "relative.sock" as Any)] {
            var value = payload(); value[key] = invalid
            XCTAssertFalse(try decode(value).valid, key)
        }
        XCTAssertNil(DSHBridgeProtocol.status(at: "/tmp/untrusted/path.sock"))
    }
    func testPinnedContractFixtureHasExpectedVersionAndNoHostSDKVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/dsh-bridge-v1.json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fixture["supportedProtocolMajor"] as? Int, 1)
        XCTAssertEqual(fixture["operations"] as? [String], ["status", "binding", "navigate"])
        XCTAssertNil(fixture["dshVersion"])
    }
}
