import SwiftUI

/// Remaining-budget bands used by cockpit-tools; independent of animation triggers.
enum UsageQuotaBand {
    case high, medium, low, critical, unavailable

    static func classify(_ remaining: Double?) -> Self {
        guard let remaining, remaining.isFinite, (0...1).contains(remaining) else { return .unavailable }
        if remaining >= 0.8 { return .high }
        if remaining >= 0.4 { return .medium }
        if remaining >= 0.1 { return .low }
        return .critical
    }

    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
        case .low: return .orange
        case .critical: return .red
        case .unavailable: return .secondary
        }
    }
}

/// Status-card colors describe remaining budget; collection and alert rules stay unchanged.
enum StatusQuotaPresentation {
    static func valid(_ fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return fraction
    }
    static func label(_ window: QuotaWindow, bundle: Bundle) -> String {
        let key: String
        switch window.durationMinutes {
        case 300: key = "5-hour"
        case 10080: key = "Weekly"
        case .some(let minutes):
            return String(format: bundle.localizedString(forKey: "%d-minute window", value: nil, table: nil), minutes)
        case nil: key = window.id == "primary" ? "Primary quota" : "Secondary quota"
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

}

/// Shared remaining-budget presentation for Settings and the Status card.
struct UsageQuotaView: View {
    let provider: OpenUsageClient.Provider
    var compact = false
    var statusPresentation = false
    var bundle: Bundle = .main

    var body: some View {
        if statusPresentation { statusContent } else { standardContent }
    }

    @ViewBuilder private var standardContent: some View {
        if provider.id == "codex", !readStatus.isEmpty {
            Text(verbatim: readStatus)
                .font(compact ? .system(size: 9) : .caption)
                .foregroundStyle(.secondary)
                .frame(height: compact ? 12 : 16, alignment: .leading)
                .accessibilityIdentifier("quota-codex-read-status")
        }
        ForEach(provider.displayWindows) { window in
            let left = window.fractionLeft
            let color = UsageQuotaBand.classify(left).color
            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                HStack(spacing: 6) {
                    Text(verbatim: provider.displayName)
                        .font(compact ? .system(size: 11, weight: .semibold) : .callout.weight(.medium))
                    if let label = provider.windows.isEmpty ? provider.windowLabel : window.label {
                        Text(verbatim: label)
                            .font(compact ? .system(size: 9) : .caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let left {
                        Text(String(format: NSLocalizedString("%d%% remaining", comment: ""), Int((left * 100).rounded())))
                            .font(compact ? .system(size: 10, weight: .semibold) : .caption.weight(.semibold))
                            .foregroundStyle(color)
                    } else {
                        Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                    if let reset = PetStatsView.resetText(window.resetsAt) {
                        Text(verbatim: "· \(reset)")
                            .font(compact ? .system(size: 9) : .caption).foregroundStyle(.secondary)
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        if let left { Capsule().fill(color).frame(width: geometry.size.width * left) }
                    }
                }
                .frame(height: compact ? 5 : 6)
            }
            .padding(.vertical, compact ? 0 : 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("quota-\(provider.id)-\(window.id)")
        }
    }

    @ViewBuilder private var statusContent: some View {
        if provider.isLoading || provider.isStale {
            Text(provider.isLoading ? "status.quotaLoading" : "status.quotaStale", bundle: bundle)
                .font(.system(size: 10)).foregroundStyle(StatusHUDStyle.tertiary)
                .accessibilityIdentifier("quota-codex-read-status")
        }
        ForEach(provider.displayWindows) { window in
            let left = StatusQuotaPresentation.valid(window.fractionLeft)
            let color = UsageQuotaBand.classify(left).color
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: provider.displayName).font(.system(size: 11, weight: .semibold))
                    if let label = provider.windows.isEmpty ? provider.windowLabel : StatusQuotaPresentation.label(window, bundle: bundle) {
                        Text(verbatim: "(\(label))").font(.system(size: 10)).foregroundStyle(StatusHUDStyle.tertiary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 3)
                    if let left {
                        Text(String(format: bundle.localizedString(forKey: "%d%% remaining", value: nil, table: nil), Int((left * 100).rounded())))
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                    } else {
                        Text("Unavailable", bundle: bundle).font(.system(size: 10)).foregroundStyle(StatusHUDStyle.tertiary)
                    }
                    if let reset = PetStatsView.resetText(window.resetsAt, bundle: bundle) {
                        Text(verbatim: "· \(reset)").font(.system(size: 9)).foregroundStyle(StatusHUDStyle.tertiary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        if let left { Capsule().fill(color).frame(width: geometry.size.width * left) }
                    }
                }.frame(height: 6)
            }
            .help(Text("status.quotaBarMeaning", bundle: bundle))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("quota-\(provider.id)-\(window.id)")
        }
    }

    private var readStatus: String {
        if provider.isLoading { return "正在读取额度…" }
        if provider.isStale {
            let time = provider.observedAt?.formatted(date: .omitted, time: .shortened) ?? ""
            return "刷新暂未成功 · 上次获取 \(time)"
        }
        if provider.windows.allSatisfy({ $0.fractionLeft == nil }) && provider.fractionLeft == nil {
            return "额度暂不可用，稍后重试"
        }
        return ""
    }
}
