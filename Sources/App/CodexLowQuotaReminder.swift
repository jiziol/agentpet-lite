import Foundation
import CryptoKit

enum CodexLowQuotaReminder {
    struct Notice {
        let id: String
        let text: String
        var percent: Int? = nil
    }
    static let storageKey = "agentpet.codexLowQuota.windows.v1"

    static func fingerprint(accountID: String?) -> String? {
        guard let accountID, !accountID.isEmpty else { return nil }
        return SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Only a fresh, identified, real 300-minute window may claim a reminder.
    /// Store a digest + reset timestamp, never credentials or an account ID.
    static func rejection(_ provider: OpenUsageClient.Provider, enabled: Bool,
                          now: Date, defaults: UserDefaults = .standard) -> String? {
        guard enabled else { return "disabled" }
        guard provider.id == "codex" else { return "wrong_provider" }
        guard !provider.isStale, !provider.isLoading else { return "stale_or_loading" }
        guard let account = provider.accountFingerprint, account.count == 64 else { return "unknown_account" }
        guard let observed = provider.observedAt, (-30...480).contains(now.timeIntervalSince(observed)) else { return "stale_sample" }
        guard let window = provider.windows.first(where: { $0.durationMinutes == 300 }) else { return "missing_five_hour_window" }
        guard let left = window.fractionLeft, left.isFinite, (0...1).contains(left) else { return "unknown_remaining" }
        guard left < 0.1 else { return "above_threshold" }
        guard let reset = window.resetsAt, reset > now else { return "missing_or_expired_reset" }
        let windows = defaults.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
        if let previous = windows[account], previous > now.timeIntervalSince1970 { return "already_claimed" }
        return nil
    }

    static func claim(_ provider: OpenUsageClient.Provider, enabled: Bool = true,
                      now: Date = Date(), defaults: UserDefaults = .standard) -> Notice? {
        // Disabled notifications must not consume a reset window's one-time claim.
        guard rejection(provider, enabled: enabled, now: now, defaults: defaults) == nil,
              let account = provider.accountFingerprint,
              let window = provider.windows.first(where: { $0.durationMinutes == 300 }),
              let left = window.fractionLeft,
              let reset = window.resetsAt, reset > now else { return nil }
        var windows = defaults.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
        // The same account is suppressed until its claimed window has reset;
        // relative-reset rounding must not create repeated reminders.
        windows = windows.filter { $0.value > now.timeIntervalSince1970 }
        if windows.count >= 128 {
            for key in windows.sorted(by: { $0.value < $1.value }).prefix(windows.count - 127).map(\.key) {
                windows.removeValue(forKey: key)
            }
        }
        windows[account] = reset.timeIntervalSince1970
        defaults.set(windows, forKey: storageKey)
        let percent = Int((left * 100).rounded(.down))
        return .init(id: "\(account):\(Int(reset.timeIntervalSince1970))",
                     text: "Codex 五小时额度仅剩 \(percent)%，请留意使用。", percent: percent)
    }
}
