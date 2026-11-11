import XCTest
@testable import agentpet

final class CodexQuotaTraceTests: XCTestCase {
    func testTraceRetainsZeroButExcludesAccountPlanAndDisplayText() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let hash = CodexLowQuotaReminder.fingerprint(accountID: "private-account-id")!
        let p = OpenUsageClient.Provider(id: "codex", displayName: "private-display",
            plan: "private-plan", fractionLeft: 0, todayLabel: "private-label",
            windows: [.init(id: "primary", fractionLeft: 0, durationMinutes: 300,
                            resetsAt: now.addingTimeInterval(200))], observedAt: now,
            accountFingerprint: hash)
        let row = CodexQuotaTrace.fields(provider: p, account: hash, decision: "triggered",
                                        startedAt: now.addingTimeInterval(-0.25), now: now)
        XCTAssertEqual(row["account_hash"] as? String, String(hash.prefix(12)))
        XCTAssertEqual(row["five_hour_left_percent"] as? Double, 0)
        XCTAssertEqual(row["read_ms"] as? Double, 250)
        let json = String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!
        for secret in ["private-account-id", "private-display", "private-plan", "private-label", hash] {
            XCTAssertFalse(json.contains(secret))
        }
    }

    func testMissingReadOrWeeklyOnlyCannotInventFiveHourState() {
        let now = Date(timeIntervalSince1970: 1000)
        let missing = CodexQuotaTrace.fields(provider: nil, account: nil, decision: "unknown_account",
                                            startedAt: now, now: now)
        XCTAssertNil(missing["account_hash"])
        XCTAssertNil(missing["five_hour_left_percent"])
        XCTAssertNil(missing["reset_at"])
        let p = OpenUsageClient.Provider(id: "codex", displayName: "Codex", plan: nil,
            fractionLeft: 0, todayLabel: nil,
            windows: [.init(id: "secondary", fractionLeft: 0, durationMinutes: 10080,
                            resetsAt: now.addingTimeInterval(200))])
        let row = CodexQuotaTrace.fields(provider: p, account: nil, decision: "missing_five_hour_window",
                                        startedAt: now, now: now)
        XCTAssertNil(row["five_hour_left_percent"])
        XCTAssertNil(row["reset_at"])
    }
}
