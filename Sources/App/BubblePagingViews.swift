import SwiftUI
import AppKit
import AgentPetCore

// MARK: - Carousel (one agent at a time)

struct BubbleCarousel: View {
    let groups: [GroupedSession]
    var chatStyle: Bool = false
    @EnvironmentObject private var settings: BubbleSettings
    @Environment(\.petOnScreen) private var onScreen
    @State private var index = 0
    /// Live number of groups, refreshed on every render. The rotation timer's
    /// closure captures a copy of this view, so reading `groups.count` there
    /// sees the count from when the timer was armed (and each `step` re-arms
    /// it from that same stale copy). A reference box is shared by all copies.
    @State private var live = LiveCount()
    @State private var timer: Timer?
    @State private var dragOffset: CGFloat = 0

    private static let interval: TimeInterval = 3.0
    private static let swipeThreshold: CGFloat = 32

    /// `index` wrapped to the groups on screen now, so a render between a
    /// group dropping out and `onChange` resetting `index` never reads past
    /// the end (which drew an empty bubble).
    private var shownIndex: Int { CarouselIndex.shown(index, count: groups.count) }

    var body: some View {
        let _ = live.value = groups.count
        VStack(alignment: .leading, spacing: chatStyle ? 4 : 5) {
            Group {
                if let group = groups[safe: shownIndex] {
                    SessionBubbleRow(session: group.session, count: group.count, chatStyle: chatStyle, team: group.team)
                        .id(group.id)
                        .transition(.opacity)
                }
            }
            .offset(x: dragOffset)
            .animation(.easeInOut(duration: 0.35), value: shownIndex)
            .clipped()

            if groups.count > 1 {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    ForEach(0..<groups.count, id: \.self) { i in
                        Circle()
                            .fill(i == shownIndex ? dotActive : dotInactive)
                            .frame(width: 4, height: 4)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .contentShape(Rectangle())
        .background {
            if groups.count > 1 {
                HorizontalSwipeReader(
                    onSwipeLeft: { step(by: 1) },
                    onSwipeRight: { step(by: -1) }
                )
            }
        }
        .highPriorityGesture(swipeGesture)
        .onAppear { syncTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: onScreen) { _ in syncTimer() }
        .onChange(of: groups.map(\.id)) { _ in
            index = 0
            dragOffset = 0
            syncTimer()
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard groups.count > 1 else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                guard groups.count > 1 else {
                    dragOffset = 0
                    return
                }
                let tx = value.translation.width
                if tx <= -Self.swipeThreshold {
                    step(by: 1)
                } else if tx >= Self.swipeThreshold {
                    step(by: -1)
                }
                withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
            }
    }

    private var dotActive: Color { .white.opacity(0.7) }
    private var dotInactive: Color { .white.opacity(0.25) }

    private func step(by delta: Int) {
        let count = live.value
        guard count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            index = CarouselIndex.step(index, by: delta, count: count)
        }
        syncTimer()
    }

    private func syncTimer() {
        stopTimer()
        guard groups.count > 1, onScreen else { return }
        let token = live.generation.token
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in
                guard live.generation.accepts(token) else { return }
                step(by: 1)
            }
        }
    }

    private func stopTimer() {
        live.generation.renew()
        timer?.invalidate()
        timer = nil
    }
}

/// Mutable box so every copy of `BubbleCarousel` reads the same live value.
@MainActor
private final class LiveCount {
    var value = 0
    let generation = InteractionGeneration()
}

/// Carousel page arithmetic, kept pure so it can be unit tested.
enum CarouselIndex {
    /// The page to draw for a stored `index` that may be stale (past the end).
    static func shown(_ index: Int, count: Int) -> Int {
        count > 0 ? ((index % count) + count) % count : 0
    }

    /// The page after moving `delta` steps, wrapping within `count` pages.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return shown(index + delta, count: count)
    }
}

// MARK: - Trackpad horizontal swipe (scroll wheel)

/// Captures two-finger horizontal trackpad swipes inside the carousel bubble.
private struct HorizontalSwipeReader: NSViewRepresentable {
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    func makeNSView(context: Context) -> HorizontalSwipeNSView {
        let view = HorizontalSwipeNSView()
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        return view
    }

    static func dismantleNSView(_ nsView: HorizontalSwipeNSView, coordinator: ()) {
        nsView.onSwipeLeft = nil; nsView.onSwipeRight = nil
    }

    func updateNSView(_ nsView: HorizontalSwipeNSView, context: Context) {
        nsView.onSwipeLeft = onSwipeLeft
        nsView.onSwipeRight = onSwipeRight
    }
}

private final class HorizontalSwipeNSView: NSView {
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?
    private var accumulatedX: CGFloat = 0
    private var lastFireAt: TimeInterval = 0

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) else { return }

        accumulatedX += event.scrollingDeltaX
        let ended = event.phase == .ended || event.phase == .cancelled
            || event.momentumPhase == .ended || event.momentumPhase == .cancelled
        guard ended else { return }

        let threshold: CGFloat = 28
        if accumulatedX <= -threshold {
            fireSwipe(left: true)
        } else if accumulatedX >= threshold {
            fireSwipe(left: false)
        }
        accumulatedX = 0
    }

    private func fireSwipe(left: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFireAt > 0.35 else { return }
        lastFireAt = now
        Task { @MainActor in
            if left { onSwipeLeft?() } else { onSwipeRight?() }
        }
    }
}

// MARK: - Compact (summary header + 2 rows + fold)

struct BubbleCompactLayout: View {
    let groups: [GroupedSession]
    let totalCount: Int
    var chatStyle: Bool = false
    @EnvironmentObject private var settings: BubbleSettings
    @State private var expanded = false

    private let visibleRows = 2

    var body: some View {
        VStack(alignment: .leading, spacing: chatStyle ? 4 : 5) {
            Text(summaryLabel)
                .font(.system(size: settings.fontSize.secondaryPt, weight: .semibold))
                .foregroundStyle(TaskBubbleStyle.secondary)
                .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)

            ForEach(visibleGroups) { group in
                // Keep the same Team identity/leadless-unknown contract as the
                // list, carousel and expanded paths. Without it a leadless
                // carrier can render a member's Allow/Deny row while the
                // click-through policy sees an unknown Team row.
                SessionBubbleRow(session: group.session, count: group.count,
                                 chatStyle: chatStyle, team: group.team)
            }

            if hiddenCount > 0 {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                    Text(expanded ? "Show less" : "+\(hiddenCount) more")
                        .font(.system(size: settings.fontSize.secondaryPt, weight: .medium))
                        .foregroundStyle(TaskBubbleStyle.secondary)
                        .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: groups.map(\.id)) { _ in expanded = false }
    }

    private var summaryLabel: String {
        let n = totalCount
        let kinds = groups.count
        if kinds <= 1 {
            return "\(n) agent\(n == 1 ? "" : "s")"
        }
        return "\(n) agent\(n == 1 ? "" : "s") · \(kinds) kind\(kinds == 1 ? "" : "s")"
    }

    private var visibleGroups: [GroupedSession] {
        expanded ? groups : Array(groups.prefix(visibleRows))
    }

    private var hiddenCount: Int {
        max(0, groups.count - visibleRows)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

