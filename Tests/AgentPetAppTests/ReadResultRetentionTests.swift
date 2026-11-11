import XCTest
import AgentPetCore
@testable import agentpet

final class ReadResultRetentionTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_000)
    private let kinds: [AgentKind] = [.codex, .antigravity, .opencode, .dsh, .claude, .pi]

    private func result(_ kind: AgentKind, failed: Bool = false) -> AgentSession {
        var s = AgentSession(id: kind.rawValue, agentKind: kind, state: .done, source: .hook, updatedAt: at)
        s.notificationVersion = 1; s.readThroughVersion = 1
        s.readAt = at; s.readDisplayRevision = 0
        // taskResult reads native result fields for these agents.
        if failed { s.codexTurnResult = .failed; s.opencodeTurnResult = .failed; s.antigravityTurnResult = .failed }
        return s
    }

    func testEveryAgentResultExpiresAtExactConfiguredDeadline() {
        for retention in ReadResultRetention.allCases where retention.seconds != nil {
            for kind in kinds {
                for failed in [false, true] {
                    let s = result(kind, failed: failed)
                    var config = BubblePresentation.Configuration(readResultRetention: retention)
                    let end = at.addingTimeInterval(retention.seconds!)
                    config.now = end.addingTimeInterval(-0.001)
                    XCTAssertEqual(BubblePresentation.visible([s], settings: config).count, 1)
                    config.now = end
                    XCTAssertTrue(BubblePresentation.visible([s], settings: config).isEmpty, "\(kind) \(retention)")
                }
            }
        }
    }

    func testForeverIncludesPreviouslyDemotedReadResultsButHonorsHiddenKinds() {
        for kind in kinds {
            var s = result(kind); s.state = .idle
            var config = BubblePresentation.Configuration(minStateFilter: .workingOnly,
                now: at.addingTimeInterval(100_000), readResultRetention: .forever)
            XCTAssertEqual(BubblePresentation.visible([s], settings: config).count, 1)
            config.hiddenKinds = [kind]
            XCTAssertTrue(BubblePresentation.visible([s], settings: config).isEmpty)
        }
    }

    func testUnreadActiveAndPendingRequestsAreNotExpiredByReading() {
        for kind in kinds {
            var unread = result(kind); unread.readThroughVersion = 0
            var working = result(kind); working.state = .working
            var waiting = result(kind); waiting.state = .waiting
            waiting.humanRequests = []
            let config = BubblePresentation.Configuration(now: at.addingTimeInterval(10_000), readResultRetention: .immediately)
            XCTAssertEqual(BubblePresentation.visible([unread, working, waiting], settings: config).count, 3)
            XCTAssertNil(BubblePresentation.nextReadResultDeadline([unread, working, waiting], retention: .fiveSeconds, now: at))
        }
    }

    func testMetadataDoesNotExtendReadDeadlineAndNewUnreadResultReappears() {
        var s = result(.codex); s.updatedAt = at.addingTimeInterval(4)
        var config = BubblePresentation.Configuration(now: at.addingTimeInterval(5))
        XCTAssertTrue(BubblePresentation.visible([s], settings: config).isEmpty)
        s.notificationVersion += 1; s.displayRevision = 1
        XCTAssertEqual(BubblePresentation.visible([s], settings: config).count, 1)
        s.state = .working
        config.now = at.addingTimeInterval(100)
        XCTAssertEqual(BubblePresentation.visible([s], settings: config).count, 1)
    }

    func testSchedulerChoosesEarliestFutureDeadlineAndStopsWhenNoneRemain() {
        let first = result(.codex)
        var second = result(.opencode); second.readAt = at.addingTimeInterval(3)
        XCTAssertEqual(BubblePresentation.nextReadResultDeadline([second, first], retention: .fiveSeconds, now: at), at.addingTimeInterval(5))
        XCTAssertEqual(BubblePresentation.nextReadResultDeadline([second, first], retention: .fiveSeconds, now: at.addingTimeInterval(5)), at.addingTimeInterval(8))
        XCTAssertNil(BubblePresentation.nextReadResultDeadline([second, first], retention: .fiveSeconds, now: at.addingTimeInterval(8)))
        XCTAssertNil(BubblePresentation.nextReadResultDeadline([first], retention: .forever, now: at))
    }

    func testLegacyReceiptWithoutReadTimestampUsesStoredTime() {
        var s = result(.pi); s.readAt = nil; s.readDisplayRevision = nil
        XCTAssertTrue(s.hasReadReceipt)
        XCTAssertEqual(BubblePresentation.readResultDeadline(s, retention: .fiveSeconds), at.addingTimeInterval(5))
    }
}
