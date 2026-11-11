import Foundation

/// Retains last-known numbers only for the same identifiable account. Stale
/// display data is never a fresh input to the low-quota reminder.
enum CodexUsagePresentation {
    static func refreshed(_ found: [OpenUsageClient.Provider], previous: [OpenUsageClient.Provider],
                          currentAccount: String?) -> [OpenUsageClient.Provider] {
        let found = found.filter { $0.id != "codex" || $0.accountFingerprint == currentAccount }
        guard !found.contains(where: { $0.id == "codex" }), let currentAccount,
              var old = previous.first(where: { $0.id == "codex" && $0.accountFingerprint == currentAccount })
        else { return found }
        old.isStale = true
        old.isLoading = false
        return found + [old]
    }

    static func combined(native: [OpenUsageClient.Provider], fallback: [OpenUsageClient.Provider],
                         codexConfigured: Bool, loading: Bool) -> [OpenUsageClient.Provider] {
        let native = native.filter { !($0.id == "codex" && $0.isLoading) }
        let nativeIDs = Set(native.map(\.id))
        // An optional helper has no account identity. A configured native Codex
        // source must not borrow its numbers while switching/refreshing accounts.
        var values = native + fallback.filter {
            !nativeIDs.contains($0.id) && !(codexConfigured && $0.id == "codex")
        }
        if codexConfigured && !values.contains(where: { $0.id == "codex" }) {
            // No duration, reset or percentage is invented before a real sample.
            values.append(.init(id: "codex", displayName: "Codex", plan: nil,
                                fractionLeft: nil, todayLabel: nil,
                                windows: [.init(id: "primary", fractionLeft: nil, durationMinutes: nil, resetsAt: nil),
                                          .init(id: "secondary", fractionLeft: nil, durationMinutes: nil, resetsAt: nil)],
                                isLoading: loading))
        }
        return values
    }
}
