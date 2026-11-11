import SwiftUI
import AppKit
import AgentPetCore

/// Elapsed-time labels show seconds below this many seconds, then whole
/// minutes. Shared by the label (`AgentRow.elapsedString`) and its tick
/// schedule (`ElapsedSchedule`) so the two can't drift apart.
let ELAPSED_SECONDS_LIMIT = 60

// MARK: - Simple Chat Bubble (celebrate / done / waiting fallback)

/// A plain speech bubble with a downward tail, used for celebrate/done lines.
/// Theme-aware (light/dark/system); reused by the Settings live preview.
/// When `projectName` is non-nil (split-pet mode), a small dimmed caption is
/// rendered above the main text so the window is identifiable.
struct ChatBubble: View {
    let text: String
    var projectName: String? = nil
    @ObservedObject private var settings = BubbleSettings.shared
    @Environment(\.bubbleTailOffset) private var tailOffset

    private var fill: Color {
        switch settings.theme {
        case .light:  return Color.white.opacity(settings.opacity)
        case .dark:   return Theme.card.opacity(settings.opacity)
        case .system: return Color(nsColor: .textBackgroundColor).opacity(settings.opacity)
        }
    }

    private var textColor: Color {
        switch settings.theme {
        case .light:  return .black.opacity(0.85)
        case .dark:   return .white.opacity(0.85)
        case .system: return Color.primary.opacity(0.85)
        }
    }

    private var dimmedTextColor: Color {
        switch settings.theme {
        case .light:  return .black.opacity(0.45)
        case .dark:   return .white.opacity(0.45)
        case .system: return Color.primary.opacity(0.45)
        }
    }

    private var borderColor: Color {
        switch settings.theme {
        case .light:  return .black.opacity(0.06 * settings.opacity)
        case .dark:   return .white.opacity(0.12 * settings.opacity)
        case .system: return Color.primary.opacity(0.08 * settings.opacity)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                if let name = projectName {
                    Text(name)
                        .font(.system(size: settings.fontSize.secondaryPt, weight: .regular))
                        .foregroundStyle(dimmedTextColor)
                        .opacity(settings.textOpacity)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(text)
                    .font(.system(size: settings.fontSize.primaryPt, weight: .medium))
                    .foregroundStyle(textColor)
                    .opacity(settings.textOpacity)
                    .contentTransition(.opacity)   // cross-fade text changes instead of a hard swap (no flicker)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
            // Flatten to one layer so the shadow traces the capsule's
            // rounded silhouette instead of its rectangular bounding box
            // (SwiftUI draws boxy shadows on composed views otherwise).
            .compositingGroup()
            .shadow(color: .black.opacity(0.18 * settings.opacity), radius: 5, y: 2)
            BubblePointerShape()
                .fill(fill)
                .frame(width: 12, height: 7)
                .offset(x: tailOffset)
        }
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: 420)
        .appAppearance()
    }
}

// MARK: - State dot

/// State dot — either a flat color-coded circle, or a Claude-style asterisk
/// that spins smoothly while the agent is active (continuous rotation, not
/// frame substitution, which reads as flashing since glyph shapes differ in
/// weight/size). Idle/done sit still.
struct StateDot: View {
    let color: Color
    let spins: Bool
    let style: BubbleSettings.DotStyle
    var isLit = true
    @Environment(\.animationsEnabled) private var animationsEnabled

    var body: some View {
        Group {
            if !isLit {
                // Retain the layout marker but remove all glow/rotation layers.
                switch style {
                case .plain: Circle().fill(color.opacity(0.25)).frame(width: 8, height: 8)
                case .claude: glyph("✻").opacity(0.25)
                }
            } else if !animationsEnabled || !spins {
                // Static branch — no CALayer, no spin. Plain renders a flat
                // circle; Claude renders the resting glyph. Identical to the
                // pre-experiment off/idle path.
                switch style {
                case .plain:
                    Circle().fill(color).frame(width: 8, height: 8)
                case .claude:
                    glyph("✻")
                }
            } else {
                // Animated branch (animations on AND spinning) runs entirely in
                // Core Animation — the ring bloom / glyph cycle live on the
                // render server and never wake SwiftUI per frame.
                StateDotLayer(color: color, style: style)
                    .frame(width: 14, height: 14)
            }
        }
        // The active↔idle/done switch swaps to a wholly different view
        // (spinner ↔ static glyph/circle); never let an ambient animation
        // cross-fade that swap into a flash.
        .animation(nil, value: spins)
        .animation(nil, value: isLit)
        .frame(width: 14, height: 14)
    }

    private func glyph(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(color)
    }
}

// MARK: - State dot (Core Animation)

/// SwiftUI bridge to the CALayer-backed state-dot animator. The bloom pulse
/// (`.plain`) and the glyph cycle (`.claude`) both run as `CAAnimation`s on the
/// render server, so — unlike a SwiftUI `TimelineView` — they do NOT force
/// SwiftUI to re-render the bubble view tree every frame. Only the animated
/// (animations-on + spinning) path is routed through here; the static paths
/// stay plain SwiftUI.
private struct StateDotLayer: NSViewRepresentable {
    let color: Color
    let style: BubbleSettings.DotStyle

    func makeNSView(context: Context) -> StateDotNSView {
        let view = StateDotNSView()
        view.configure(color: color, style: style)
        return view
    }

    func updateNSView(_ view: StateDotNSView, context: Context) {
        // Called on every SwiftUI re-render of the parent. `configure` is
        // idempotent: it only rebuilds layers / re-adds CAAnimations when the
        // color or style actually changed, so an unrelated re-render never
        // restarts (and visually jitters) the running animation.
        view.configure(color: color, style: style)
    }

    static func dismantleNSView(_ view: StateDotNSView, coordinator: ()) {
        view.teardown()
    }
}

/// A layer-backed view that animates the state dot purely in Core Animation.
/// `.plain` is a static center dot plus an expanding/fading ring; `.claude`
/// cycles six pre-rendered glyph images via a discrete keyframe animation.
final class StateDotNSView: NSView {
    private static let glyphFrames = ["✶", "✳", "✢", "✻", "✽", "✺"]
    private static let glyphInterval: TimeInterval = 0.15
    /// Rendered glyph frames keyed by color+scale. Rows are re-created on
    /// every carousel rotation, so re-rasterising six glyphs per row each time
    /// showed up as the top app-side cost. Only a handful of state colors
    /// exist, so this stays tiny.
    @MainActor private static var glyphCache: [String: [CGImage]] = [:]

    private var lastColor: NSColor?
    private var lastStyle: BubbleSettings.DotStyle?
    private var builtScale: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Idempotent: rebuilds sublayers + re-adds animations only when `color` or
    /// `style` changed since the last call. SwiftUI re-renders of the parent
    /// therefore never churn the running CAAnimations.
    func configure(color: Color, style: BubbleSettings.DotStyle) {
        let nsColor = NSColor(color)
        if let lastColor, let lastStyle,
           lastColor == nsColor, lastStyle == style {
            return  // nothing relevant changed — leave the animation running.
        }
        lastColor = nsColor
        lastStyle = style
        rebuild(nsColor: nsColor, style: style)
    }

    private var currentScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func rebuild(nsColor: NSColor, style: BubbleSettings.DotStyle) {
        builtScale = currentScale
        let host = layer ?? CALayer()
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        host.removeAllAnimations()
        switch style {
        case .plain:
            buildPlain(on: host, nsColor: nsColor)
        case .claude:
            buildClaude(on: host, nsColor: nsColor)
        }
    }

    /// Center dot (8×8, static) + an expanding/fading ring (8×8) that scales
    /// 1→2.4 while fading 0.55→0, repeating forever — the bloom, with no blur
    /// and no per-frame SwiftUI/CPU cost.
    private func buildPlain(on host: CALayer, nsColor: NSColor) {
        let scale = currentScale
        let dotRect = centeredRect(side: 8)

        let ring = CALayer()
        ring.frame = dotRect
        ring.backgroundColor = nsColor.cgColor
        ring.cornerRadius = 4
        ring.contentsScale = scale
        ring.opacity = 0  // resting value once the animation completes
        host.addSublayer(ring)

        let center = CALayer()
        center.frame = dotRect
        center.backgroundColor = nsColor.cgColor
        center.cornerRadius = 4
        center.contentsScale = scale
        host.addSublayer(center)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 2.4
        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0.55
        opacityAnim.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = 1.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "bloom")
    }

    /// A single 14×14 content layer whose `contents` cycles through the six
    /// pre-rendered glyph images via a discrete keyframe animation.
    private func buildClaude(on host: CALayer, nsColor: NSColor) {
        let scale = currentScale
        // Key on the sRGB components, not `description` (its text format is
        // not a stable identity and can differ for equal colors).
        let rgba = nsColor.usingColorSpace(.sRGB).map {
            [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent]
                .map { String(format: "%.4f", $0) }.joined(separator: ",")
        } ?? nsColor.description
        let cacheKey = "\(rgba)@\(scale)"
        let images: [CGImage]
        if let cached = Self.glyphCache[cacheKey] {
            images = cached
        } else {
            images = Self.glyphFrames.compactMap { glyphImage($0, color: nsColor, scale: scale) }
            Self.glyphCache[cacheKey] = images
        }

        let content = CALayer()
        content.frame = bounds
        content.contentsGravity = .center
        content.contentsScale = scale
        content.contents = images.first
        host.addSublayer(content)

        guard images.count > 1 else { return }
        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.calculationMode = .discrete
        anim.values = images
        anim.duration = Self.glyphInterval * Double(images.count)
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        content.add(anim, forKey: "glyphCycle")
    }

    /// Renders one glyph as a `CGImage` at backing scale.
    private func glyphImage(_ s: String, color: NSColor, scale: CGFloat) -> CGImage? {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let glyphSize = str.size()
        let pointSize = NSSize(width: max(glyphSize.width.rounded(.up), 1),
                               height: max(glyphSize.height.rounded(.up), 1))
        let image = NSImage(size: pointSize)
        image.lockFocus()
        str.draw(at: .zero)
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func centeredRect(side: CGFloat) -> CGRect {
        CGRect(x: (bounds.width - side) / 2,
               y: (bounds.height - side) / 2,
               width: side, height: side)
    }

    override func layout() {
        super.layout()
        // Keep sublayer frames centered if the host bounds change. The SwiftUI
        // `.frame(width:14,height:14)` fixes the size, so this is mostly a
        // safety net for the initial layout pass.
        guard let sublayers = layer?.sublayers else { return }
        if lastStyle == .claude {
            sublayers.forEach { $0.frame = bounds }
        } else {
            let dotRect = centeredRect(side: 8)
            sublayers.forEach { $0.frame = dotRect }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Re-render at the new backing scale for crispness on display changes.
        // Skip when the scale is unchanged (e.g. the first attach to a window),
        // which otherwise rebuilt every freshly created dot a second time.
        let scale = currentScale
        if scale != builtScale, let style = lastStyle, let color = lastColor {
            rebuild(nsColor: color, style: style)
        }
    }

    /// Removes the running CAAnimations on teardown. Called from
    /// `StateDotLayer.dismantleNSView` (Swift 6 forbids touching this from a
    /// nonisolated `deinit`).
    func teardown() {
        layer?.removeAllAnimations()
        layer?.sublayers?.forEach { $0.removeAllAnimations() }
    }
}

// MARK: - Waiting text flash

/// Gently pulses row text opacity when waiting for input (no strikethrough).
/// Implemented as a short eased toggle on a timer rather than a SwiftUI
/// `repeatForever` animation: the latter re-renders the bubble at display rate
/// for as long as a session waits (often minutes), which was a steady CPU and
/// WindowServer cost. Here SwiftUI only animates ~30% of each cycle.
struct WaitingTextFlash: ViewModifier {
    let active: Bool
    private static let cycle: TimeInterval = 1.0
    private static let fade: TimeInterval = 0.3
    @State private var generation = InteractionGeneration()
    @State private var dimmed = false
    @State private var timer: Timer?

    func body(content: Content) -> some View {
        content
            .opacity(active ? (dimmed ? 0.65 : 1.0) : 1.0)
            .onAppear { sync() }
            .onChange(of: active) { _ in sync() }
            .onDisappear { stop() }
    }

    private func sync() {
        stop()
        if active {
            let token = generation.token
            let t = Timer(timeInterval: Self.cycle, repeats: true) { _ in
                Task { @MainActor in
                    guard generation.accepts(token) else { return }
                    withAnimation(.easeInOut(duration: Self.fade)) { dimmed.toggle() }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func stop() {
        generation.renew()
        timer?.invalidate()
        timer = nil
        dimmed = false
    }
}

/// Timeline for the elapsed-time token: one entry per second while the label
/// shows seconds, then one per whole minute since `since`.
struct ElapsedSchedule: TimelineSchedule {
    let since: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        let since = since
        return AnyIterator {
            let current = next
            let elapsed = max(0, current.timeIntervalSince(since))
            if elapsed < Double(ELAPSED_SECONDS_LIMIT - 1) {
                next = current.addingTimeInterval(1)
            } else {
                let intoMinute = elapsed.truncatingRemainder(dividingBy: 60)
                next = current.addingTimeInterval(60 - intoMinute)
            }
            return current
        }
    }
}

struct BubblePointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
