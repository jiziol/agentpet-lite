import Foundation
import CoreFoundation

struct QuotaWindow: Identifiable, Equatable {
    let id: String
    let fractionLeft: Double?
    let durationMinutes: Int?
    let resetsAt: Date?

    var label: String {
        switch durationMinutes {
        case 300: return NSLocalizedString("5-hour", comment: "Quota window")
        case 10080: return NSLocalizedString("Weekly", comment: "Quota window")
        case .some(let minutes): return String(format: NSLocalizedString("%d-minute window", comment: ""), minutes)
        case nil: return NSLocalizedString(id == "primary" ? "Primary quota" : "Secondary quota", comment: "")
        }
    }
}

/// Preserves each returned Codex window; missing values never become 100% remaining.
enum CodexQuota {
    static func provider(result: [String: Any], now: Date = Date()) -> OpenUsageClient.Provider? {
        let bucket: [String: Any]?
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any], !buckets.isEmpty {
            // Other model-specific buckets must not replace the ordinary Codex quota.
            bucket = buckets["codex"] as? [String: Any]
        } else { bucket = result["rateLimits"] as? [String: Any] }
        guard let bucket else { return nil }
        let windows = ["primary", "secondary"].map { key -> QuotaWindow in
            let value = bucket[key] as? [String: Any] ?? [:]
            return .init(id: key, fractionLeft: remaining(value["usedPercent"]),
                         durationMinutes: minutes(value["windowDurationMins"]),
                         resetsAt: timestamp(value["resetsAt"]))
        }
        return makeProvider(windows: windows, plan: bucket["planType"] as? String, now: now)
    }

    static func provider(wham: [String: Any], headers: [String: String] = [:], now: Date = Date()) -> OpenUsageClient.Provider? {
        guard let limit = wham["rate_limit"] as? [String: Any] else { return nil }
        let windows = ["primary", "secondary"].map { key -> QuotaWindow in
            let value = limit["\(key)_window"] as? [String: Any] ?? [:]
            let used: Any? = value["used_percent"] ?? headers["x-codex-\(key)-used-percent"]
                .flatMap(Double.init).map { NSNumber(value: $0) }
            let seconds = number(value["limit_window_seconds"])
            let reset = timestamp(value["reset_at"])
                ?? number(value["reset_after_seconds"] ?? value["resets_in_seconds"])
                    .flatMap { $0 >= 0 ? now.addingTimeInterval($0) : nil }
            return .init(id: key, fractionLeft: remaining(used),
                         durationMinutes: seconds.flatMap { minutes($0 / 60) }, resetsAt: reset)
        }
        return makeProvider(windows: windows, plan: wham["plan_type"] as? String, now: now)
    }

    private static func makeProvider(windows: [QuotaWindow], plan: String?, now: Date) -> OpenUsageClient.Provider {
        let tightest = windows.filter { $0.fractionLeft != nil }.min { $0.fractionLeft! < $1.fractionLeft! }
        return .init(id: "codex", displayName: "Codex", plan: plan,
                     fractionLeft: tightest?.fractionLeft, todayLabel: nil,
                     resetsAt: tightest?.resetsAt, windowLabel: tightest?.label,
                     windows: windows, observedAt: now)
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func remaining(_ value: Any?) -> Double? {
        guard let used = number(value), (0...100).contains(used) else { return nil }
        return (100 - used) / 100
    }
    private static func minutes(_ value: Any?) -> Int? {
        guard let n = number(value), n > 0, n <= 525_600, n.rounded() == n else { return nil }
        return Int(n)
    }
    private static func timestamp(_ value: Any?) -> Date? {
        guard let n = number(value), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n)
    }
}
