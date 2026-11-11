import Foundation
import XCTest
@testable import agentpet

@MainActor
final class NotificationAvailabilityTests: XCTestCase {
    func testIdentifiedTestRunnerIsNotAUserNotificationApplication() {
        XCTAssertFalse(NotificationManager.hasApplicationIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin"),
            identifier: "com.apple.dt.xctest.tool"))
        XCTAssertFalse(NotificationManager.hasApplicationIdentity(
            bundleURL: URL(fileURLWithPath: "/tmp/AgentPet Lite.app"), identifier: nil))
        XCTAssertTrue(NotificationManager.hasApplicationIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/AgentPet Lite.app"),
            identifier: "local.acerz.agentpet"))
    }
}
