import Foundation

/// Confirm a real reset after a previously observed low window. A timer reaching
/// its estimate is not evidence that a provider has actually restored quota.
enum CodexQuotaRecovery {
    struct Notice { let id: String; let percent: Int }
    private struct Record: Codable {
        let reset: Date
        let observed: Date
        var recovered = false
    }
    static let storageKey = "agentpet.codexQuotaRecovery.lowWindows.v1"
    static let accountKey = "agentpet.codexQuotaRecovery.activeAccount.v1"

    static func observe(_ provider: OpenUsageClient.Provider, enabled: Bool,
                        now: Date = Date(), defaults: UserDefaults = .standard) -> Notice? {
        guard provider.id == "codex", !provider.isStale, !provider.isLoading,
              let account = provider.accountFingerprint, account.count == 64,
              account.allSatisfy({ $0.isHexDigit }), let at = provider.observedAt,
              (-30...480).contains(now.timeIntervalSince(at)),
              let window = provider.windows.first(where: { $0.durationMinutes == 300 }),
              let left = window.fractionLeft, left.isFinite, (0...1).contains(left),
              let reset = window.resetsAt, reset > now else { return nil }
        var records: [String: Record] = [:]
        if let data = defaults.data(forKey: storageKey), data.count <= 32768,
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data), decoded.count <= 128 {
            records = decoded.filter { key, value in
                key.count == 64 && key.allSatisfy({ $0.isHexDigit }) && value.reset.timeIntervalSince1970.isFinite &&
                    value.observed.timeIntervalSince1970.isFinite && value.observed <= now.addingTimeInterval(30) &&
                    now.timeIntervalSince(value.observed) < 8 * 3600
            }
        }
        let previousAccount = defaults.string(forKey: accountKey)
        let switched = previousAccount != nil && previousAccount != account
        if switched {
            // Fence this account's old baseline and legacy claim across later
            // polls too. Switching is not a reset observed in this account.
            records[account] = Record(reset: reset, observed: now, recovered: true)
            if left < 0.1 { records[account] = Record(reset: reset, observed: now) }
        }
        defaults.set(account, forKey: accountKey)
        // Existing v1 low-quota claims are real evidence, not a fabricated low
        // sample. This preserves the user's .68 window through this upgrade.
        if records[account] == nil, !switched,
           let oldReset = (defaults.dictionary(forKey: CodexLowQuotaReminder.storageKey) as? [String: Double])?[account],
           oldReset.isFinite, abs(now.timeIntervalSince1970 - oldReset) < 3 * 3600 {
            records[account] = Record(reset: Date(timeIntervalSince1970: oldReset),
                                      observed: Date(timeIntervalSince1970: oldReset - 5 * 3600))
        }
        var notice: Notice?
        if let previous = records[account], !previous.recovered, now >= previous.reset,
           reset.timeIntervalSince(previous.reset) > 60, left >= 0.1, enabled {
            notice = .init(id: "recovered:\(account):\(Int(previous.reset.timeIntervalSince1970))", percent: Int((left * 100).rounded(.down)))
            records[account] = Record(reset: previous.reset, observed: now, recovered: true)
        } else if left < 0.1 {
            if let previous = records[account], now < previous.reset {
                records[account] = Record(reset: previous.reset, observed: now)
            } else { records[account] = Record(reset: reset, observed: now) }
        }
        if records.count > 128 {
            for key in records.sorted(by: { $0.value.observed < $1.value.observed }).prefix(records.count - 128).map(\.key) { records.removeValue(forKey: key) }
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: storageKey) }
        return notice
    }
}
