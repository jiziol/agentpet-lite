import Foundation
import AgentPetCore

/// Local bounded operational evidence. No token, raw account ID, prompt or
/// response body is accepted by this API. It never claims a reminder itself.
enum CodexQuotaTrace {
    static func fields(provider: OpenUsageClient.Provider?, account: String?, decision: String,
                       startedAt: Date, now: Date) -> [String: Any] {
        var row: [String: Any] = ["at": now.timeIntervalSince1970,
                                 "read_ms": max(0, now.timeIntervalSince(startedAt) * 1000), "decision": decision]
        if let account, account.count == 64 { row["account_hash"] = String(account.prefix(12)) }
        if let provider {
            row["stale"] = provider.isStale; row["loading"] = provider.isLoading
            if let at = provider.observedAt { row["observed_at"] = at.timeIntervalSince1970 }
            if let w = provider.windows.first(where: { $0.durationMinutes == 300 }) {
                if let left = w.fractionLeft, left.isFinite { row["five_hour_left_percent"] = left * 100 }
                if let reset = w.resetsAt { row["reset_at"] = reset.timeIntervalSince1970 }
            }
        }
        return row
    }
    static func record(provider: OpenUsageClient.Provider?, account: String?, decision: String,
                       startedAt: Date, now: Date) {
        guard AgentPetPaths.isLocal else { return }
        let path = AgentPetPaths.baseDir + "/codex-quota-events.jsonl"
        guard var data = try? JSONSerialization.data(withJSONObject:
            fields(provider: provider, account: account, decision: decision, startedAt: startedAt, now: now), options: .sortedKeys) else { return }
        data.append(10)
        let fm = FileManager.default
        if let n = try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber, n.intValue > 65_536 {
            try? fm.removeItem(atPath: path + ".previous")
            try? fm.moveItem(atPath: path, toPath: path + ".previous")
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let file = FileHandle(forWritingAtPath: path) else { return }
        defer { try? file.close() }
        do { try file.seekToEnd(); try file.write(contentsOf: data) } catch { }
    }
}
