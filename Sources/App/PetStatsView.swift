import AppKit
import QuartzCore
import SwiftUI
import AgentPetCore

/// The pet's right-click HUD: the companion's stats plus a compact footer with
/// Settings / Refresh / Quit.
struct PetStatsView: View {
    /// The pet whose stats to show. `nil` resolves to the globally selected pet
    /// (preserves today's right-click-on-the-single-pet behaviour).
    var petID: String? = nil
    @ObservedObject var noticeSource: SystemNoticeCenter = PetController.shared.systemNotices
    var noticeModel: PetWindowModel? = nil
    var showSystemNotice = true
    var refreshUsage: () -> Void = { NativeUsageProbe.shared.poll(); OpenUsageClient.shared.poll() }
    @ObservedObject private var care = PetCareController.shared
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var imagePets = ImagePetStore.shared
    @ObservedObject private var usage = OpenUsageClient.shared
    @ObservedObject private var tokens = DailyTokenUsageController.shared

    private static let stageColors: [Color] = [.green, .teal, .blue, .purple, .orange]

    /// The pet id this card is showing — the passed id, else the selected pet.
    private var resolvedPetID: String? { petID ?? pet.selectedPetID }

    private var pack: ImagePetPack? {
        resolvedPetID.flatMap { imagePets.pack(id: $0) }
    }

    /// Care state of the resolved pet.
    private var careState: PetCareState { care.state(for: resolvedPetID) }
    private var level: Int { PetCare.displayLevel(forXP: careState.xp) }
    private var stageKey: String { PetCare.stageName(forLevel: PetCare.level(forXP: careState.xp)) }
    private var stageIndex: Int { PetCare.stageIndex(forLevel: PetCare.level(forXP: careState.xp)) }
    private var levelProgress: Double { PetCare.progress(forXP: careState.xp) }
    private var hunger: PetHunger { PetCare.hunger(state: careState, now: Date()) }

    private var stageColor: Color { Self.stageColors[min(stageIndex, Self.stageColors.count - 1)] }

    var body: some View {
        let state = careState
        VStack(alignment: .leading, spacing: 4) {
            if showSystemNotice, let notice = noticeSource.current, BubbleSettings.shared.superchatEnabled {
                SystemNoticeView(source: noticeSource, notice: notice, width: 272)
                    .background(SystemNoticeMarker(model: noticeModel, id: notice.id))
            }
            header(state)
            xpBlock(state)
            DailyTokenUsageView(snapshot: tokens.snapshot, isRefreshing: tokens.isRefreshing,
                openSettings: { SettingsWindowController.shared.show(focusAgentIntegrations: true) })
            if tokens.error != nil { Text(LocalizedStringKey(tokens.error!)).font(.caption2).foregroundStyle(.orange) }
            usageBlock
            footer
        }
        .padding(14)
        .frame(width: 300)
        .background(StatusHUDStyle.background)
        .appAppearance()
        .textSelection(.enabled)
        .noFocusRing()
        .onAppear(perform: refreshUsage)
        .onAppear { tokens.refresh() }
    }

    // MARK: - Footer (Settings / Refresh / Quit)

    private var footer: some View {
        VStack(spacing: 8) {
            Divider().overlay(Theme.cardStroke)
            HStack {
                footButton(icon: "gearshape", label: "Settings") {
                    SettingsWindowController.shared.show()
                }
                footButton(icon: "arrow.triangle.2.circlepath",
                           label: probe.isPolling ? "Refreshing…" : "Refresh") {
                    probe.poll(force: true)
                    usage.poll()
                    tokens.refresh()
                }
                .accessibilityIdentifier("status-refresh-usage")
                Spacer()
                footButton(icon: "power", label: "Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func footButton(icon: String, label: String, badge: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                    if badge {
                        Circle().fill(Color.orange).frame(width: 5, height: 5).offset(x: 3, y: -3)
                    }
                }
                Text(verbatim: label)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header

    private func header(_ state: PetCareState) -> some View {
        HStack(spacing: 10) {
            Group {
                if let frame = pack?.clip(0).first {
                    Image(nsImage: frame).resizable().interpolation(.none).scaledToFit().padding(4)
                } else {
                    Image(systemName: "pawprint.fill").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(stageColor.opacity(0.14)))

            VStack(alignment: .leading, spacing: 3) {
                Text(imagePets.displayName(for: resolvedPetID))
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                HStack(spacing: 6) {
                    Text(verbatim: "Lv \(level)")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(stageColor)
                    StageBadge(stageIndex: stageIndex, size: 16)
                    Text(NSLocalizedString(stageKey, comment: "stage"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(stageColor.opacity(0.2)))
                        .foregroundStyle(stageColor)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 3) {
                    PetFullnessLight(color: fullness > 0.5 ? .green : (fullness > 0.25 ? .orange : .red))
                        .frame(width: 12, height: 12).allowsHitTesting(false).accessibilityHidden(true)
                    Text(hungerText)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(StatusHUDStyle.secondary)
                }
                if let last = state.lastFedAt {
                    Text(String(format: NSLocalizedString("status.lastFed", comment: "Compact last feeding time"),
                                last.formatted(.relative(presentation: .named))))
                        .font(.system(size: 10)).foregroundStyle(StatusHUDStyle.tertiary)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.85)
        }
    }

    // MARK: - XP

    private func xpBlock(_ state: PetCareState) -> some View {
        let (inLevel, span) = PetCare.xpWithinLevel(forXP: state.xp)
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: levelProgress).tint(stageColor).controlSize(.small)
            HStack {
                Text(verbatim: "\(Self.plain(inLevel)) / \(Self.plain(span)) XP")
                    .font(.system(size: 10)).foregroundStyle(StatusHUDStyle.tertiary)
                Spacer()
                Text(verbatim: "\(Int((levelProgress * 100).rounded()))%")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(StatusHUDStyle.secondary)
            }
        }
        // Preserve the established section height and footer position.
        .padding(.bottom, 17)
    }

    // MARK: - Usage / limits

    @ObservedObject private var probe = NativeUsageProbe.shared

    @ViewBuilder private var usageBlock: some View {
        let providers = NativeUsageProbe.combined()
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("status.quotaTitle").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)

                }
                ForEach(providers) { p in
                    UsageQuotaView(provider: p, compact: true, statusPresentation: true)
                }
            }.statusHUDSection()
        }
    }

    /// "resets in 3h" / "in 12m" from a reset timestamp.
    static func resetText(_ date: Date?, bundle: Bundle = .main) -> String? {
        guard let date else { return nil }
        let secs = date.timeIntervalSinceNow
        guard secs > 0 else { return nil }
        if secs >= 86400 { return String(format: bundle.localizedString(forKey: "resets in %dd", value: nil, table: nil), Int(secs / 86400)) }
        if secs >= 3600 { return String(format: bundle.localizedString(forKey: "resets in %dh", value: nil, table: nil), Int(secs / 3600)) }
        return String(format: bundle.localizedString(forKey: "resets in %dm", value: nil, table: nil), max(1, Int(secs / 60)))
    }

    // MARK: - Derived

    /// Continuous fullness 0…1 (48h since the last feeding → empty).
    private var fullness: Double {
        guard let last = careState.lastFedAt else { return 0.5 }
        let hours = Date().timeIntervalSince(last) / 3600
        return max(0, min(1, 1 - hours / 48))
    }

    private var hungerText: String {
        switch hunger {
        case .full: return NSLocalizedString("Full", comment: "hunger")
        case .satisfied: return NSLocalizedString("Satisfied", comment: "hunger")
        case .peckish: return NSLocalizedString("Peckish", comment: "hunger")
        case .hungry: return NSLocalizedString("Hungry", comment: "hunger")
        case .starving: return NSLocalizedString("Starving", comment: "hunger")
        }
    }

    private static func plain(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// A small, soft pulse rendered by Core Animation rather than a per-frame
/// SwiftUI update. The status text carries the meaning independently of color.
private struct PetFullnessLight: NSViewRepresentable {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PetFullnessLightNSView { PetFullnessLightNSView() }
    func updateNSView(_ view: PetFullnessLightNSView, context: Context) {
        view.configure(color: NSColor(color), animated: !reduceMotion)
    }
    static func dismantleNSView(_ view: PetFullnessLightNSView, coordinator: ()) { view.teardown() }

}

final class PetFullnessLightNSView: NSView {
    private let glow = CALayer()
    private let dot = CALayer()
    private var animated = false
    private var color: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glow.cornerRadius = 5; glow.opacity = 0.2
        glow.shadowOffset = .zero; glow.shadowRadius = 2; glow.shadowOpacity = 0.4
        dot.cornerRadius = 2.5
        layer?.addSublayer(glow); layer?.addSublayer(dot)
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(color: NSColor, animated: Bool) {
        if self.color != color {
            self.color = color
            glow.backgroundColor = color.cgColor; glow.shadowColor = color.cgColor
            dot.backgroundColor = color.cgColor
        }
        self.animated = animated
        updateAnimation()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = CGRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10)
        glow.shadowPath = CGPath(ellipseIn: glow.bounds, transform: nil)
        dot.frame = CGRect(x: bounds.midX - 2.5, y: bounds.midY - 2.5, width: 5, height: 5)
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
    private func updateAnimation() {
        guard animated, window != nil else { glow.removeAnimation(forKey: "breathing"); return }
        guard glow.animation(forKey: "breathing") == nil else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.12; opacity.toValue = 0.3
        opacity.duration = 1.8; opacity.autoreverses = true; opacity.repeatCount = .infinity
        opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        opacity.beginTime = CACurrentMediaTime()
        glow.add(opacity, forKey: "breathing")
    }
    func teardown() { animated = false; glow.removeAllAnimations() }
}
