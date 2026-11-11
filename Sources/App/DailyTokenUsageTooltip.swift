import AppKit
import SwiftUI
import AgentPetCore

/// A compact daily total and one row per Agent.
struct DailyTokenUsageTipView: View {
    let day: TokenUsageDay
    var pinned = false
    var bundle: Bundle = .main
    var width: CGFloat = 246
    @Environment(\.colorScheme) private var colorScheme

    private var hasAmounts: Bool {
        day.coverage != .notStarted && (day.total > 0 || day.coverage == .complete)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                (Text(day.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                    + Text(" ") + Text("usage.dayDetail", bundle: bundle))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 2)
                if pinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
            }
            .lineLimit(1).foregroundStyle(.secondary)
            .padding(.bottom, 13)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: hasAmounts ? day.total.formatted() : "—").font(.system(size: 23, weight: .semibold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                Text("usage.tokens", bundle: bundle).font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(.bottom, hasAmounts && day.total > 0 ? 15 : 0)
            if hasAmounts {
                VStack(spacing: 0) {
                    ForEach(TokenAgent.allCases, id: \.rawValue) { agent in
                        if let amount = day.byAgent[agent]?.total, amount > 0 {
                            HStack(spacing: 6) {
                                Circle().fill(DailyTokenUsagePresentation.color(agent)).frame(width: 5, height: 5)
                                Text(verbatim: agent.name).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(verbatim: amount.formatted()).fontWeight(.medium).monospacedDigit()
                            }.font(.system(size: 10)).frame(height: 19)
                        }
                    }
                }
            }
        }
        .padding(14).frame(width: width)
        .background(colorScheme == .dark ? Color(red: 0.19, green: 0.20, blue: 0.22) : Color.white,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
        .accessibilityIdentifier("usage-day-tooltip")
    }
}

/// A non-activating child card, so opening a hover tip cannot steal the pointer
/// or dismiss the status window. AppKit screen coordinates may be negative.
@MainActor
final class DailyTokenUsageTipController {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var panel: Panel?
    private var host: NSHostingView<AnyView>?
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []
    var onDismiss: () -> Void = {}
    private(set) var displayedDate: Date?
    var isVisible: Bool { panel?.isVisible == true }
    var currentFrame: NSRect? { isVisible ? panel?.frame : nil }

    static func frame(column: NSRect, chart: NSRect, parent: NSRect, size: NSSize, visible: NSRect) -> NSRect {
        let area = visible.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(size.width, area.width), height: min(size.height, area.height))
        let x: CGFloat
        let y: CGFloat
        if parent.maxX + 12 + size.width <= area.maxX {
            x = parent.maxX + 12; y = column.midY - size.height / 2
        } else if parent.minX - 12 - size.width >= area.minX {
            x = parent.minX - 12 - size.width; y = column.midY - size.height / 2
        } else {
            x = column.midX - size.width / 2
            y = chart.minY - 12 - size.height >= area.minY ? chart.minY - 12 - size.height : chart.maxY + 12
        }
        return NSRect(x: min(max(x, area.minX), area.maxX - size.width),
                      y: min(max(y, area.minY), area.maxY - size.height), width: size.width, height: size.height)
    }

    func show(day: TokenUsageDay, pinned: Bool, bundle: Bundle, scheme: ColorScheme,
              anchor: NSView, index: Int, count: Int) {
        guard let window = anchor.window, window.isVisible, anchor.bounds.width > 0,
              let visible = window.screen?.visibleFrame else { hide(); return }
        if parent !== window {
            hide()
            parent = window
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hide(); self?.onDismiss() }
                })
            }
        }
        if panel == nil {
            let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.ignoresMouseEvents = true
            // The host can remain visible while another app is active. Follow
            // the parent window's lifetime, without activating AgentPet.
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            panel.contentView = host; self.panel = panel; self.host = host
        }
        guard let panel, let host else { return }
        panel.ignoresMouseEvents = !pinned
        let width = min(CGFloat(246), max(1, visible.width - 16))
        let tip = DailyTokenUsageTipView(day: day, pinned: pinned, bundle: bundle, width: width).environment(\.colorScheme, scheme)
        host.rootView = AnyView(tip)
        let height = host.fittingSize.height
        if height > visible.height - 16 {
            host.rootView = AnyView(ScrollView { tip }.frame(width: width, height: max(1, visible.height - 16)))
        }
        let chart = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let pitch = (chart.width + 2) / CGFloat(max(1, count))
        let column = NSRect(x: chart.minX + CGFloat(index) * pitch, y: chart.minY,
                            width: max(1, pitch - 2), height: chart.height)
        let frame = Self.frame(column: column, chart: chart, parent: window.frame,
                               size: NSSize(width: width, height: height), visible: visible)
        panel.level = window.level
        panel.setFrame(frame, display: false)
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        displayedDate = day.date
    }

    func hide() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        parent = nil; displayedDate = nil
    }

    func dispose() { hide(); panel?.close(); panel = nil; host = nil }
}

@MainActor
struct DailyTokenUsagePointer: NSViewRepresentable {
    enum Command: Equatable { case left, right, first, last, activate, dismiss }
    let days: [TokenUsageDay]
    let focusedDay: TokenUsageDay?
    let pinned: Bool
    let bundle: Bundle
    let scheme: ColorScheme
    let onHover: (Int?) -> Void
    let onSelect: (Int) -> Void
    let onCommand: (Command) -> Void

    func makeNSView(context: Context) -> DailyTokenUsagePointerView { DailyTokenUsagePointerView() }
    func updateNSView(_ view: DailyTokenUsagePointerView, context: Context) {
        let countChanged = view.configuration?.days.count != days.count
        view.configuration = self
        if countChanged { view.updateTrackingAreas() }
        view.refresh()
    }
    static func dismantleNSView(_ view: DailyTokenUsagePointerView, coordinator: ()) { view.dispose() }
}

/// Tracking cells include the narrow gaps, so crossing a gap cannot make the
/// tip flicker. The native overlay routes clicks; SwiftUI buttons retain AX.
@MainActor
final class DailyTokenUsagePointerView: NSView {
    private final class CellOwner: NSResponder {
        weak var view: DailyTokenUsagePointerView?
        let index: Int
        init(view: DailyTokenUsagePointerView, index: Int) { self.view = view; self.index = index; super.init() }
        required init?(coder: NSCoder) { nil }
        override func mouseEntered(with event: NSEvent) { view?.enterCell(index) }
        override func mouseExited(with event: NSEvent) { view?.exitCell(index) }
    }
    var configuration: DailyTokenUsagePointer?
    let tip = DailyTokenUsageTipController()
    private var keyMonitor: Any?
    private var pressedIndex: Int?
    private var trackedRect = NSRect.null
    private var trackedCount = -1
    // Keep one owner per date slot alive across geometry updates; tracking
    // events already queued by AppKit may still refer to the previous area.
    private var cellOwners: [Int: CellOwner] = [:]
    private var hoveredCell: Int?
    private var hoverGeneration = 0
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyMonitor()
        if window == nil { tip.hide(); return }
        refresh()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.tip.isVisible, event.window === self.window else { return false }
                guard event.keyCode == 53 || self.window?.firstResponder === self else { return false }
                let command: DailyTokenUsagePointer.Command
                switch event.keyCode {
                case 123: command = .left
                case 124: command = .right
                case 115: command = .first
                case 119: command = .last
                case 36, 76, 49: command = .activate
                case 53: command = .dismiss
                default: return false
                }
                if command == .dismiss { self.tip.hide() }
                self.configuration?.onCommand(command)
                return true
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let count = configuration?.days.count ?? 0
        let rect = bounds.intersection(visibleRect)
        guard trackedRect != rect || trackedCount != count else { return }
        trackedRect = rect; trackedCount = count
        trackingAreas.forEach(removeTrackingArea)
        guard count > 0, bounds.width > 0 else { return }
        let pitch = (bounds.width + 2) / CGFloat(count)
        for index in 0..<count {
            let left = max(0, CGFloat(index) * pitch - 1)
            let right = index == count - 1 ? bounds.width : min(bounds.width, CGFloat(index + 1) * pitch - 1)
            let cell = NSRect(x: left, y: 0, width: right - left, height: bounds.height).intersection(rect)
            guard !cell.isEmpty else { continue }
            let owner = cellOwners[index] ?? CellOwner(view: self, index: index)
            cellOwners[index] = owner
            addTrackingArea(NSTrackingArea(rect: cell,
                options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag], owner: owner, userInfo: ["index": index]))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { updateTrackingAreas(); refresh() }
    }

    func index(at point: NSPoint) -> Int? {
        let count = configuration?.days.count ?? 0
        guard count > 0, bounds.contains(point), bounds.width > 0 else { return nil }
        return min(count - 1, Int((point.x + 1) / ((bounds.width + 2) / CGFloat(count))))
    }
    private func enterCell(_ index: Int) {
        guard configuration?.days.indices.contains(index) == true else { return }
        hoverGeneration &+= 1
        hoveredCell = index
        configuration?.onHover(index)
    }
    private func exitCell(_ index: Int) {
        guard hoveredCell == index else { return }
        let generation = hoverGeneration
        // AppKit does not guarantee entered/exited ordering across areas.
        // A late exit cannot overwrite a newer entry or make cell gaps flicker.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hoverGeneration == generation, self.hoveredCell == index else { return }
            self.hoveredCell = nil
            self.configuration?.onHover(nil)
        }
    }
    override func mouseDown(with event: NSEvent) {
        pressedIndex = index(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
    }
    override func mouseUp(with event: NSEvent) {
        if let index = index(at: convert(event.locationInWindow, from: nil)), index == pressedIndex {
            configuration?.onSelect(index)
        }
        pressedIndex = nil
    }

    func refresh() {
        guard let configuration else { return }
        tip.onDismiss = { [weak self] in
            DispatchQueue.main.async { self?.configuration?.onCommand(.dismiss) }
        }
        guard let day = configuration.focusedDay, let index = configuration.days.firstIndex(where: { $0.id == day.id }) else {
            tip.hide(); removeKeyMonitor(); return
        }
        if window != nil { installKeyMonitor() }
        tip.show(day: day, pinned: configuration.pinned, bundle: configuration.bundle, scheme: configuration.scheme,
                 anchor: self, index: index, count: configuration.days.count)
    }

    func dispose() {
        hoverGeneration &+= 1; hoveredCell = nil
        trackingAreas.forEach(removeTrackingArea); cellOwners.removeAll()
        removeKeyMonitor()
        tip.dispose(); configuration = nil
    }
}
