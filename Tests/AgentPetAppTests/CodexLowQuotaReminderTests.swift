import XCTest
@testable import agentpet

final class CodexLowQuotaReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100)
    private func provider(left: Double = 0.09, account: String = "test-account", reset: Double = 1000) -> OpenUsageClient.Provider {
        .init(id: "codex", displayName: "Codex", plan: "plus", fractionLeft: left, todayLabel: nil,
              windows: [.init(id: "primary", fractionLeft: left, durationMinutes: 300, resetsAt: Date(timeIntervalSince1970: reset)),
                        .init(id: "secondary", fractionLeft: 0, durationMinutes: 10080, resetsAt: Date(timeIntervalSince1970: 5000))],
              observedAt: now, accountFingerprint: CodexLowQuotaReminder.fingerprint(accountID: account))
    }
    private func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let suite = "quota-reminder-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, suite)
    }
    func testOnlyFiveHourLessThanTenPercentCanTrigger() {
        withDefaults { defaults, _ in
            XCTAssertNil(CodexLowQuotaReminder.claim(provider(left: 0.9), now: now, defaults: defaults))
            XCTAssertNil(CodexLowQuotaReminder.claim(provider(left: 0.1), now: now, defaults: defaults))
            XCTAssertNotNil(CodexLowQuotaReminder.claim(provider(), now: now, defaults: defaults))
        }
    }
    func testZeroRemainingTriggersAndDiagnosticDoesNotConsumeClaim() {
        withDefaults { defaults, _ in
            let p = provider(left: 0)
            XCTAssertNil(CodexLowQuotaReminder.rejection(p, enabled: true, now: now, defaults: defaults))
            XCTAssertNil(defaults.object(forKey: CodexLowQuotaReminder.storageKey))
            XCTAssertEqual(CodexLowQuotaReminder.claim(p, now: now, defaults: defaults)?.text,
                           "Codex 五小时额度仅剩 0%，请留意使用。")
            XCTAssertEqual(CodexLowQuotaReminder.rejection(p, enabled: true, now: now, defaults: defaults), "already_claimed")
        }
    }
    func testDiagnosticDistinguishesDisabledHighMissingStaleAndInvalidSamples() {
        withDefaults { defaults, _ in
            func reason(_ p: OpenUsageClient.Provider, enabled: Bool = true) -> String? {
                CodexLowQuotaReminder.rejection(p, enabled: enabled, now: now, defaults: defaults)
            }
            XCTAssertEqual(reason(provider(), enabled: false), "disabled")
            XCTAssertEqual(reason(provider(left: 0.1)), "above_threshold")
            var p = provider(); p.accountFingerprint = nil
            XCTAssertEqual(reason(p), "unknown_account")
            p = provider(); p.isStale = true
            XCTAssertEqual(reason(p), "stale_or_loading")
            p = provider(); p.observedAt = now.addingTimeInterval(-481)
            XCTAssertEqual(reason(p), "stale_sample")
            p = provider(); p.windows.removeFirst()
            XCTAssertEqual(reason(p), "missing_five_hour_window")
            for invalid in [Double.nan, .infinity, -0.01, 1.01] {
                XCTAssertEqual(reason(provider(left: invalid)), "unknown_remaining")
                XCTAssertNil(CodexLowQuotaReminder.claim(provider(left: invalid), now: now, defaults: defaults))
            }
            XCTAssertNil(defaults.object(forKey: CodexLowQuotaReminder.storageKey))
        }
    }
    func testDisabledDoesNotConsumeWindowAndReenableDoesNotReplayClaimedWindow() {
        withDefaults { defaults, _ in
            XCTAssertNil(CodexLowQuotaReminder.claim(provider(), enabled: false, now: now, defaults: defaults))
            XCTAssertNil(defaults.object(forKey: CodexLowQuotaReminder.storageKey))
            XCTAssertNotNil(CodexLowQuotaReminder.claim(provider(), enabled: true, now: now, defaults: defaults))
            let claimed = defaults.dictionary(forKey: CodexLowQuotaReminder.storageKey)!
            XCTAssertNil(CodexLowQuotaReminder.claim(provider(), enabled: false, now: now, defaults: defaults))
            XCTAssertNil(CodexLowQuotaReminder.claim(provider(), enabled: true, now: now, defaults: defaults))
            XCTAssertEqual(defaults.dictionary(forKey: CodexLowQuotaReminder.storageKey) as NSDictionary?, claimed as NSDictionary)
        }
    }
    func testSameWindowPersistsAcrossReaderRestartAndResetRounding() {
        withDefaults { defaults, suite in
            XCTAssertNotNil(CodexLowQuotaReminder.claim(provider(), now: now, defaults: defaults))
            let restarted = UserDefaults(suiteName: suite)!
            XCTAssertNil(CodexLowQuotaReminder.claim(provider(reset: 1002), now: now, defaults: restarted))
            let stored = defaults.dictionary(forKey: CodexLowQuotaReminder.storageKey)!
            XCTAssertEqual(stored.count, 1); XCTAssertNil(stored["test-account"])
        }
    }
    func testAccountSwitchAndNewResetWindowRearmIndependently() {
        withDefaults { defaults, _ in
            XCTAssertNotNil(CodexLowQuotaReminder.claim(provider(), now: now, defaults: defaults))
            XCTAssertNotNil(CodexLowQuotaReminder.claim(provider(account: "second"), now: now, defaults: defaults))
            var later = provider(reset: 2000); later.observedAt = Date(timeIntervalSince1970: 1001)
            XCTAssertNotNil(CodexLowQuotaReminder.claim(later, now: later.observedAt!, defaults: defaults))
        }
    }
    func testMissingAccountDurationResetOrStaleUsageDoesNotInventReminder() {
        withDefaults { defaults, _ in
            var p = provider(); p.accountFingerprint = nil
            XCTAssertNil(CodexLowQuotaReminder.claim(p, now: now, defaults: defaults))
            p = provider(); p.windows[0] = .init(id: "primary", fractionLeft: 0, durationMinutes: nil, resetsAt: Date(timeIntervalSince1970: 1000))
            XCTAssertNil(CodexLowQuotaReminder.claim(p, now: now, defaults: defaults))
            p = provider(); p.observedAt = now.addingTimeInterval(-481)
            XCTAssertNil(CodexLowQuotaReminder.claim(p, now: now, defaults: defaults))
            p = provider(reset: 99)
            XCTAssertNil(CodexLowQuotaReminder.claim(p, now: now, defaults: defaults))
        }
    }
}
