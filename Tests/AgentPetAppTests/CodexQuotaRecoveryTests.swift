import XCTest
@testable import agentpet

final class CodexQuotaRecoveryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100_000)
    private func sample(_ at: Date, left: Double = 0.08, reset: Date? = nil, account: String = "first") -> OpenUsageClient.Provider {
        .init(id: "codex", displayName: "Codex", plan: nil, fractionLeft: left, todayLabel: nil,
              windows: [.init(id: "primary", fractionLeft: left, durationMinutes: 300, resetsAt: reset ?? start.addingTimeInterval(100))],
              observedAt: at, accountFingerprint: CodexLowQuotaReminder.fingerprint(accountID: account))
    }
    private func isolated(_ body: (UserDefaults, String) -> Void) {
        let name = "quota-recovery-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults, name)
    }
    func testActualResetAfterLowTriggersOnceAcrossRestart() {
        isolated { defaults, name in
            XCTAssertNil(CodexQuotaRecovery.observe(sample(start), enabled: true, now: start, defaults: defaults))
            let later = start.addingTimeInterval(101)
            let restored = sample(later, left: 1, reset: later.addingTimeInterval(18_000))
            XCTAssertEqual(CodexQuotaRecovery.observe(restored, enabled: true, now: later, defaults: defaults)?.percent, 100)
            let restarted = UserDefaults(suiteName: name)!
            XCTAssertNil(CodexQuotaRecovery.observe(restored, enabled: true, now: later, defaults: restarted))
        }
    }
    func testFirstHighReadingAndClockEstimateCannotInventRecovery() {
        isolated { defaults, _ in
            XCTAssertNil(CodexQuotaRecovery.observe(sample(start, left: 1), enabled: true, now: start, defaults: defaults))
            XCTAssertNil(CodexQuotaRecovery.observe(sample(start), enabled: true, now: start, defaults: defaults))
            // More remaining before the old reset is not a new reset.
            XCTAssertNil(CodexQuotaRecovery.observe(sample(start.addingTimeInterval(50), left: 0.4), enabled: true, now: start.addingTimeInterval(50), defaults: defaults))
            let later = start.addingTimeInterval(101)
            // Expired data and a tiny relative-reset rounding shift are not evidence.
            XCTAssertNil(CodexQuotaRecovery.observe(sample(later, left: 1), enabled: true, now: later, defaults: defaults))
            XCTAssertNil(CodexQuotaRecovery.observe(sample(later, left: 1, reset: start.addingTimeInterval(130)), enabled: true, now: later, defaults: defaults))
        }
    }
    func testBadSamplesAndDisabledDoNotConsumeConfirmedRecovery() {
        isolated { defaults, _ in
            _ = CodexQuotaRecovery.observe(sample(start), enabled: true, now: start, defaults: defaults)
            let later = start.addingTimeInterval(101)
            let good = sample(later, left: 0.42, reset: later.addingTimeInterval(18_000))
            for mode in 0..<7 {
                var bad = good
                switch mode {
                case 0: bad.isStale = true
                case 1: bad.isLoading = true
                case 2: bad.observedAt = later.addingTimeInterval(-481)
                case 3: bad.accountFingerprint = nil
                case 4: bad.windows = [.init(id: "weekly", fractionLeft: 1, durationMinutes: 10080, resetsAt: later.addingTimeInterval(18_000))]
                case 5: bad.windows = [.init(id: "primary", fractionLeft: .nan, durationMinutes: 300, resetsAt: later.addingTimeInterval(18_000))]
                default: bad.observedAt = later.addingTimeInterval(31)
                }
                XCTAssertNil(CodexQuotaRecovery.observe(bad, enabled: true, now: later, defaults: defaults))
            }
            XCTAssertNil(CodexQuotaRecovery.observe(good, enabled: false, now: later, defaults: defaults))
            XCTAssertEqual(CodexQuotaRecovery.observe(good, enabled: true, now: later, defaults: defaults)?.percent, 42)
        }
    }
    func testAccountSwitchFencesLegacyBaselineOnSubsequentPollsToo() {
        isolated { defaults, _ in
            let low = sample(start)
            _ = CodexQuotaRecovery.observe(low, enabled: true, now: start, defaults: defaults)
            _ = CodexLowQuotaReminder.claim(low, now: start, defaults: defaults)
            let claimed = defaults.dictionary(forKey: CodexLowQuotaReminder.storageKey)! as NSDictionary
            _ = CodexQuotaRecovery.observe(sample(start, left: 1, account: "second"), enabled: true, now: start, defaults: defaults)
            let later = start.addingTimeInterval(101)
            let back = sample(later, left: 1, reset: later.addingTimeInterval(18_000))
            for _ in 0..<3 { XCTAssertNil(CodexQuotaRecovery.observe(back, enabled: true, now: later, defaults: defaults)) }
            XCTAssertEqual(defaults.dictionary(forKey: CodexLowQuotaReminder.storageKey)! as NSDictionary, claimed)
        }
    }
    func testUpgradeCanUsePriorRealLowClaimWithoutChangingIt() {
        isolated { defaults, _ in
            _ = CodexLowQuotaReminder.claim(sample(start), now: start, defaults: defaults)
            let claimed = defaults.dictionary(forKey: CodexLowQuotaReminder.storageKey)! as NSDictionary
            let later = start.addingTimeInterval(101)
            let high = sample(later, left: 0.87, reset: later.addingTimeInterval(18_000))
            XCTAssertEqual(CodexQuotaRecovery.observe(high, enabled: true, now: later, defaults: defaults)?.percent, 87)
            XCTAssertNil(CodexQuotaRecovery.observe(high, enabled: true, now: later, defaults: defaults))
            XCTAssertEqual(defaults.dictionary(forKey: CodexLowQuotaReminder.storageKey)! as NSDictionary, claimed)
        }
    }
    func testNewLowWindowRearmsAndOldBaselinesExpire() {
        isolated { defaults, _ in
            _ = CodexQuotaRecovery.observe(sample(start), enabled: true, now: start, defaults: defaults)
            let later = start.addingTimeInterval(9 * 3600)
            XCTAssertNil(CodexQuotaRecovery.observe(sample(later, left: 1, reset: later.addingTimeInterval(100)), enabled: true, now: later, defaults: defaults))
            _ = CodexQuotaRecovery.observe(sample(later, reset: later.addingTimeInterval(100)), enabled: true, now: later, defaults: defaults)
            let next = later.addingTimeInterval(101)
            XCTAssertNotNil(CodexQuotaRecovery.observe(sample(next, left: 1, reset: next.addingTimeInterval(18_000)), enabled: true, now: next, defaults: defaults))
        }
    }
}
