import XCTest
@testable import agentpet

final class CodexUsagePresentationTests: XCTestCase {
    private func sample(_ account: String = "account-a") -> OpenUsageClient.Provider {
        .init(id: "codex", displayName: "Codex", plan: "plus", fractionLeft: 0.09, todayLabel: nil,
              windows: [.init(id: "primary", fractionLeft: 0.09, durationMinutes: 300, resetsAt: Date(timeIntervalSince1970: 1000)),
                        .init(id: "secondary", fractionLeft: 0.21, durationMinutes: 10080, resetsAt: Date(timeIntervalSince1970: 5000))],
              observedAt: Date(timeIntervalSince1970: 100),
              accountFingerprint: CodexLowQuotaReminder.fingerprint(accountID: account))
    }

    func testFailureRetainsBothWindowsOnlyAsStaleForSameAccount() {
        var old = sample(); old.isLoading = true
        let result = CodexUsagePresentation.refreshed([], previous: [old], currentAccount: old.accountFingerprint)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isStale)
        XCTAssertFalse(result[0].isLoading)
        XCTAssertEqual(result[0].windows, old.windows)
        XCTAssertEqual(result[0].observedAt, old.observedAt)
    }

    func testAccountSwitchOrLogoutDoesNotDisplayOldPercentages() {
        for account in [nil, CodexLowQuotaReminder.fingerprint(accountID: "account-b")] {
            let result = CodexUsagePresentation.refreshed([], previous: [sample()], currentAccount: account)
            XCTAssertTrue(result.isEmpty)
            let shown = CodexUsagePresentation.combined(native: result, fallback: [], codexConfigured: true, loading: false)
            XCTAssertEqual(shown[0].windows.count, 2)
            XCTAssertTrue(shown[0].windows.allSatisfy { $0.fractionLeft == nil && $0.durationMinutes == nil && $0.resetsAt == nil })
        }
    }

    func testSuccessfulRetryReplacesStaleDataAndPlaceholderDoesNotHideCodex() {
        var old = sample(); old.isStale = true
        let fresh = sample()
        XCTAssertEqual(CodexUsagePresentation.refreshed([fresh], previous: [old], currentAccount: fresh.accountFingerprint), [fresh])
        let pending = CodexUsagePresentation.combined(native: [], fallback: [], codexConfigured: true, loading: true)
        XCTAssertTrue(pending[0].isLoading); XCTAssertNil(pending[0].fractionLeft)
        XCTAssertTrue(CodexUsagePresentation.combined(native: [], fallback: [], codexConfigured: false, loading: false).isEmpty)
        XCTAssertEqual(CodexUsagePresentation.combined(native: [fresh], fallback: [fresh], codexConfigured: true, loading: false), [fresh])
    }

    func testAccountChangedAfterReadRejectsResponseAndUnidentifiedHelper() {
        let old = sample()
        let next = CodexLowQuotaReminder.fingerprint(accountID: "account-b")
        XCTAssertTrue(CodexUsagePresentation.refreshed([old], previous: [old], currentAccount: next).isEmpty)
        var loading = old; loading.isLoading = true
        let pending = CodexUsagePresentation.combined(native: [loading], fallback: [old], codexConfigured: true, loading: true)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending[0].isLoading)
        XCTAssertTrue(pending[0].windows.allSatisfy { $0.fractionLeft == nil })
        XCTAssertEqual(CodexUsagePresentation.combined(native: [], fallback: [old], codexConfigured: false, loading: false), [old])
    }

    func testStaleRecentLowQuotaCannotClaimAnimationReminder() {
        let suite = "stale-quota-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = sample(); old.isStale = true
        XCTAssertNil(CodexLowQuotaReminder.claim(old, now: Date(timeIntervalSince1970: 101), defaults: defaults))
        old.isStale = false; old.isLoading = true
        XCTAssertNil(CodexLowQuotaReminder.claim(old, now: Date(timeIntervalSince1970: 101), defaults: defaults))
        old.isLoading = false
        XCTAssertNotNil(CodexLowQuotaReminder.claim(old, now: Date(timeIntervalSince1970: 101), defaults: defaults))
    }
}
