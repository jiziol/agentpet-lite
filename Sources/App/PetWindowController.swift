import AppKit
import SwiftUI
import Combine
import AgentPetCore

/// The visible tuck state of one window. `frame` is the cropped peek content
/// rectangle; `visible` is the screen area used for bubbles and recovery.
private struct PetEdgePresentation: Equatable {
    var side: PetEdgeSide
    var frame: NSRect
    var visible: NSRect
}

/// Owns the floating pet panels. A registry keyed by group key ("default" or a
/// project path): each entry is one borderless, always-on-top, draggable
/// `NSPanel` hosting a `FloatingPetView(model:)`. Single-pet mode is just N=1
/// (one "default" window); Split mode spawns one window per active project.
@MainActor
final class PetWindowController: ObservableObject {
    static let shared = PetWindowController()

    @Published var isVisible: Bool = true {
        didSet { applyVisibility(isVisible) }
    }

    /// One managed panel + its per-window model and observers/measurement state.
    @MainActor
    private final class ManagedPetWindow {
        let panel: NSPanel
        let model: PetWindowModel
        var taskPanel: NSPanel?
        var taskHost: ClickThroughHostingView<PetTaskPanelView>?
        var speechPanel: NSPanel?
        var speechObservation: AnyCancellable?
        var settingsObservation: AnyCancellable?
        var speechSize: CGSize = .zero
        var companionLayoutScheduled = false
        var lastTaskFrame: NSRect?
        var moveObserver: Any?
        var occlusionObserver: Any?

        /// Independent static peek panel and its presentation state.
        var peekPanel: NSPanel?
        var peekHost: ClickThroughHostingView<EdgePeekView>?
        let peekState = EdgePeekState()
        var edge: PetEdgePresentation?
        var edgeTransition: PetEdgeTransition?
        var isEdgeTransitioning = false
        /// Expansion uses a child overlay of the body so it follows the cursor.
        var expandTransition: PetEdgeTransition?
        var isExpandTransitioning = false
        /// Latest off-main actual-frame sample prepared during a drag.
        var preparedSnapshot: PetEdgeSnapshot?
        var pendingExpansionImage: CGImage?
        var pendingExpansionSide: PetEdgeSide?
        var expansionRequestedAt: TimeInterval = 0
        var lastSnapshotRequestAt: TimeInterval = 0
        var snapshotTimer: Timer?
        var snapshotGeneration: UInt64 = 0
        var snapshotTask: Task<Void, Never>?
        var suppressSnapOnEnd = false
        var dragMoved = false
        /// Keeps routing a drag that started on the collapse overlay even after
        /// the overlay is cancelled/ordered out.
        var transitionRoutePanel: NSPanel?
        /// Fences late collapse/expand completions after a fast drag/up.
        var edgeGeneration: UInt64 = 0
        var pendingEdgeRestore: PetEdgeSide?
        var didAttemptEdgeRestore = false

        /// One controller owns body, peek and transition mouse sequences.
        /// Explicit lifecycle callbacks used by non-mouse callers do not move
        /// from a mouse anchor until a threshold-crossing event claims it.
        var isDragging = false
        var mouseDragActive = false
        var dragStartMouse: NSPoint = .zero
        var dragStartOrigin: NSPoint = .zero

        /// Screen position of the pet's bottom-center; kept stable across resizes.
        var placement = PetWindowPlacement()
        var isApplyingLayout = false
        var lastContentSize: CGSize = .zero
        var resizeDebounce: DispatchWorkItem?
        /// Re-fits the window onto the pet's screen once a drag settles.
        var relayoutDebounce: DispatchWorkItem?

        /// Per-window left-click disambiguation. `awaitingSingle` means the
        /// first click has ended and its single-click action is still inside
        /// the system double-click window. A queued callback is fenced by
        /// `generation` even after cancellation.
        struct ClickState {
            var awaitingSingle = false
            var count = 0
            /// Screen-space cursor position at the down event. Window-relative
            /// points are unusable here: the SwiftUI drag moves the window with
            /// the cursor, so its local point stays nearly constant.
            var downScreenPoint: NSPoint?
            var generation: UInt64 = 0
        }
        var click = ClickState()
        var pendingSingleClick: DispatchWorkItem?

        init(panel: NSPanel, model: PetWindowModel) {
            self.panel = panel
            self.model = model
        }
    }

    /// All live pet panels, keyed by spec key.
    private var windows: [String: ManagedPetWindow] = [:]

    private var sizeCancellable: AnyCancellable?
    private var chatLineCancellable: AnyCancellable?
    private var rightClickMonitor: Any?
    /// Observes only this app's mouse events. It never consumes them, so the
    /// SwiftUI drag gesture still moves the pet; it decides click business
    /// from the system clickCount instead of custom timing/coordinates.
    private var petClickMonitor: Any?
    private var screenObserver: Any?
    private var sleepObservers: [Any] = []
    /// True while displays sleep or the session is locked/switched away.
    private var screensAsleep = false

    private let positionStore = PetWindowPositionStore()
    private let edgeStore = PetEdgeStateStore()
    private var packsCancellable: AnyCancellable?
    private let refreshStatsUsage: () -> Void

    init(refreshStatsUsage: @escaping () -> Void = { NativeUsageProbe.shared.poll(); OpenUsageClient.shared.poll() }) {
        self.refreshStatsUsage = refreshStatsUsage
    }

    func start() {
        // Create the default ("home") window up front so the pet appears at
        // launch, before the daemon's first session update arrives.
        _ = ensureWindow(for: PetWindowPlanner.defaultKey)
        applyVisibility(isVisible)

        // On pet-size change, re-measure every window after SwiftUI relayouts.
        sizeCancellable = PetController.shared.$petPoint.sink { [weak self] _ in
            self?.remeasureAll()
        }

        // On agent rows added/removed, re-measure after SwiftUI relayouts.
        chatLineCancellable = PetController.shared.$chatLineCount.sink { [weak self] _ in
            self?.remeasureAll()
        }

        // Restore a persisted tuck once its pack is actually loaded, and recover
        // if a pack reload removes the peek art.
        packsCancellable = ImagePetStore.shared.$packs.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.packsDidChange() }
        }

        // If displays change (e.g. a monitor is unplugged), keep every pet on screen.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.statsPanel.dismissImmediately()
                self?.ensureAllOnScreen()
            }
        }

        // Pause animations while nobody can see the pets: displays asleep,
        // screen locked / fast user switch. Occlusion (covered, hidden) is
        // tracked per panel in `ensureWindow`.
        let ws = NSWorkspace.shared.notificationCenter
        let pauses: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.sessionDidResignActiveNotification, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        sleepObservers = pauses.map { name, asleep in
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.screensAsleep = asleep
                    for managed in self.windows.values { self.updateOnScreen(managed); self.layoutSpeech(managed) }
                }
            }
        }

        // Right-click a pet to show ITS stats card (info only — controls stay in
        // the menu bar popover and Settings). Bubbles share the panel but must
        // not trigger this shortcut; match the pet's actual layout region.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handlePetRightClickEvent(event) == true }
            return handled ? nil : event
        }

        // One local monitor moves every pet presentation, so SwiftUI playback
        // rebuilds cannot drop the active gesture. Click business still waits
        // for the native double-click window and uses event.clickCount. Events
        // remain unconsumed for normal AppKit dispatch; no global event tap.
        petClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        ) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated { self.handlePetClickEvent(event) }
            return event
        }
    }

    func stop() {
        statsPanel.dismissImmediately()
        for key in Array(windows.keys) { teardownWindow(forKey: key) }
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor); self.rightClickMonitor = nil }
        if let petClickMonitor { NSEvent.removeMonitor(petClickMonitor); self.petClickMonitor = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        for token in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        sleepObservers.removeAll()
        sizeCancellable = nil
        chatLineCancellable = nil
        packsCancellable = nil
    }

    // MARK: - Multi-window sync

    /// The per-window state the coordinator resolves for a spec: the displayed
    /// mood (may differ from `spec.mood` — e.g. a transient celebrate burst),
    /// the structured sessions for the bubble, the petID (after the missing-pet
    /// fallback), and the chat line. Built by `PetController` from the existing
    /// chat / celebrate logic.
    struct WindowState {
        var petID: String?
        var mood: PetMood
        var sessions: [AgentSession]
        var count: Int
        var chatLine: String
        var animationContext = PetAnimationContext()
        var quotaText = ""
        var speechRows: [PetSpeechState.Row] = []
        var idleText = ""
    }

    /// Reconciles the live panels with the planned specs. Existing keys update
    /// their model in place (no new panel); new keys create a panel; keys absent
    /// from `specs` are torn down. `stateFor` supplies the resolved per-window
    /// state for each spec (computed by the coordinator from the existing chat /
    /// celebrate logic).
    func sync(specs: [PetWindowSpec], noticeSource: SystemNoticeCenter? = nil, stateFor: (PetWindowSpec) -> WindowState) {
        let wanted = Set(specs.map(\.key))

        // Tear down windows whose group disappeared.
        for key in windows.keys where !wanted.contains(key) {
            teardownWindow(forKey: key)
        }

        for (index, spec) in specs.enumerated() {
            let managed = windows[spec.key] ?? createWindow(
                key: spec.key, petID: spec.petID, mood: spec.mood,
                projectName: spec.projectName, count: spec.count, index: index)
            managed.model.noticeSource = noticeSource
            apply(stateFor(spec), to: managed.model)
            restoreEdgeIfNeeded(managed)
            if isVisible {
                if managed.isEdgeTransitioning {
                    // The transition overlay owns the visual for a moment.
                } else if managed.edge != nil {
                    managed.peekPanel?.orderFrontRegardless()
                } else if !managed.isDragging {
                    managed.panel.orderFrontRegardless()
                }
            }
        }
    }

    /// Pushes resolved state into a window's model. Keeps the `key` (immutable)
    /// and only mutates the per-window published state.
    private func apply(_ state: WindowState, to model: PetWindowModel) {
        model.petID = state.petID
        model.mood = state.mood
        model.sessions = state.sessions
        model.count = state.count
        model.chatLine = state.chatLine
        model.idleText = state.idleText
        if model.animationContext != state.animationContext { model.animationContext = state.animationContext }
        model.quotaText = state.quotaText
        if model.speechRows != state.speechRows { model.speechRows = state.speechRows }
    }

    // MARK: - Window lifecycle

    /// Returns the window for `key`, creating a bare default-anchored one if absent.
    @discardableResult
    private func ensureWindow(for key: String) -> ManagedPetWindow {
        if let existing = windows[key] { return existing }
        return createWindow(key: key, petID: PetController.shared.selectedPetID,
                            mood: .idle, projectName: nil, count: 0, index: windows.count)
    }

    /// Builds a panel for a window key, positions it (saved position or
    /// auto-offset), wires its move observer, registers it, and seeds its model.
    /// The model's `sessions`/`chatLine` are filled immediately after by `sync`.
    @discardableResult
    private func createWindow(key: String, petID: String?, mood: PetMood,
                              projectName: String?, count: Int, index: Int) -> ManagedPetWindow {
        let pet = PetController.shared.petPoint
        let size = CGSize(width: pet + 24, height: pet + 24)
        let model = PetWindowModel(key: key, petID: petID, mood: mood,
                                   projectName: projectName, count: count)
        let panel = makePanel(size: size, model: model)
        let managed = ManagedPetWindow(panel: panel, model: model)
        windows[key] = managed
        let speechPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        speechPanel.title = "AgentPet Lite Pet Messages"
        speechPanel.level = .floating; speechPanel.isOpaque = false
        speechPanel.backgroundColor = .clear; speechPanel.hasShadow = false
        speechPanel.ignoresMouseEvents = true
        speechPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        speechPanel.contentView = ClickThroughHostingView(rootView: PetSpeechView(model: model, measured: { [weak self] size in
            guard let self, let managed = self.windows[key] else { return }
            managed.speechSize = size
            self.layoutSpeech(managed)
        }))
        managed.speechPanel = speechPanel
        let taskPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        taskPanel.title = "AgentPet Lite Tasks"
        taskPanel.level = .floating; taskPanel.isOpaque = false
        taskPanel.backgroundColor = .clear; taskPanel.hasShadow = false
        taskPanel.becomesKeyOnlyIfNeeded = true
        taskPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let taskHost = ClickThroughHostingView(rootView: PetTaskPanelView(model: model, measured: { [weak self] _ in
            self?.scheduleCompanionLayout(key: key)
        }))
        taskHost.autoresizingMask = []
        let taskScroll = NSScrollView(frame: .zero)
        taskScroll.drawsBackground = false
        taskScroll.contentView.drawsBackground = false
        taskScroll.automaticallyAdjustsContentInsets = false
        taskScroll.hasVerticalScroller = true
        taskScroll.hasHorizontalScroller = false
        taskScroll.autohidesScrollers = true
        taskScroll.scrollerStyle = .overlay
        taskScroll.documentView = taskHost
        taskPanel.contentView = taskScroll
        managed.taskHost = taskHost
        managed.taskPanel = taskPanel

        // Independent, content-sized peek panel. It has no transparent margin of
        // its own: the frame is the alpha-cropped character content.
        let peekPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        peekPanel.title = "AgentPet Lite Edge Peek"
        peekPanel.level = .floating
        peekPanel.isOpaque = false
        peekPanel.backgroundColor = .clear
        peekPanel.hasShadow = false
        peekPanel.becomesKeyOnlyIfNeeded = true
        peekPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        peekPanel.contentView = ClickThroughHostingView(rootView: EdgePeekView(state: managed.peekState))
        managed.peekHost = peekPanel.contentView as? ClickThroughHostingView<EdgePeekView>
        managed.peekPanel = peekPanel

        managed.speechObservation = model.objectWillChange.sink { [weak self] _ in
            self?.scheduleCompanionLayout(key: key)
        }
        managed.settingsObservation = BubbleSettings.shared.objectWillChange.sink { [weak self] _ in
            self?.scheduleCompanionLayout(key: key)
        }

        // Save position whenever the user drags this specific panel. Capture the
        // Sendable `key` (not the non-Sendable `managed`) and re-resolve on the
        // main actor to satisfy Swift 6 concurrency.
        managed.moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self, key] _ in
            MainActor.assumeIsolated {
                guard let self, let managed = self.windows[key] else { return }
                guard !managed.isApplyingLayout,
                      managed.placement.recordUserMove(frame: managed.panel.frame,
                                                       petOffset: managed.model.petOffset) else { return }
                self.savePosition(managed)
                self.layoutSpeech(managed)
                if !managed.isDragging { self.scheduleRelayout(managed) }
            }
        }
        managed.occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self, key] _ in
            MainActor.assumeIsolated {
                guard let self, let managed = self.windows[key] else { return }
                self.updateOnScreen(managed)
            }
        }

        placeWindow(managed, size: size, index: index)
        savePosition(managed)
        return managed
    }

    /// Recomputes whether a pet can be seen; only publishes on change so
    /// SwiftUI is not invalidated by redundant occlusion callbacks.
    private func updateOnScreen(_ managed: ManagedPetWindow) {
        // The peek image is static and does not need the body's animation
        // clock. Pausing the hidden movie here prevents it from running while
        // tucked; a drag sets `isDragging` and `isOnScreen` before restarting
        // the drag movie from frame 0.
        let visible = !screensAsleep
            && (managed.isDragging || managed.panel.occlusionState.contains(.visible))
        if managed.model.isOnScreen != visible { managed.model.isOnScreen = visible }
    }

    /// Factory: a borderless, non-activating, floating, click-through panel.
    private func makePanel(size: CGSize, model: PetWindowModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "AgentPet Lite Body"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Native background/titlebar dragging is deliberately disabled: it can
        // race the controller's screen-delta drag and lets macOS apply its own
        // window snapping/tiling. The local monitor is the only mouse mover.
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let interaction = PetWindowInteraction(
            resize: { [weak self, weak model] size in
                guard let self, let model, self.windows[model.key]?.model === model else { return }
                self.resizeToContent(size, forKey: model.key)
            }, dragBegan: { [weak self, weak model] in
                guard let self, let model, let managed = self.windows[model.key],
                      managed.model === model else { return }
                self.beginPetDrag(managed)
            }, dragEnded: { [weak self, weak model] in
                guard let self, let model, let managed = self.windows[model.key],
                      managed.model === model else { return }
                self.endPetDrag(managed)
            })
        panel.contentView = ClickThroughHostingView(rootView: FloatingPetView(model: model, windowInteraction: interaction))
        return panel
    }

    /// Loads a saved position for this window's key, else places it at the
    /// bottom-right anchor shifted left by `index` so windows don't stack.
    private func placeWindow(_ managed: ManagedPetWindow, size: CGSize, index: Int) {
        managed.pendingEdgeRestore = edgeStore.side(forKey: managed.model.key)
        if let anchor = positionStore.anchor(forKey: managed.model.key, legacyWindowWidth: size.width) {
            // Clamp the restored position onto a live screen: a coordinate saved
            // on a larger/other display can land off-screen after a resolution or
            // monitor change, hiding the pet forever otherwise (issue #47).
            managed.placement.anchor = anchor
            fitAnchorOnScreen(managed)
            resizeInPlace(managed, to: size)
            return
        }
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let step = PetController.shared.petPoint + 40
        let origin = NSPoint(
            x: visible.maxX - size.width - 16 - CGFloat(index) * step,
            y: visible.minY + 24
        )
        managed.placement.anchor = NSPoint(x: origin.x + size.width / 2, y: origin.y)
        fitAnchorOnScreen(managed)
        resizeInPlace(managed, to: size)
    }

    private func teardownWindow(forKey key: String) {
        guard let managed = windows.removeValue(forKey: key) else { return }
        if statsModel === managed.model { statsPanel.dismissImmediately(); messageRestoration.cancel() }
        cancelClickSequence(managed)
        managed.edgeTransition?.cancel()
        managed.edgeTransition = nil
        managed.edgeGeneration &+= 1
        managed.isEdgeTransitioning = false
        managed.expandTransition?.cancel()
        managed.expandTransition = nil
        managed.isExpandTransitioning = false
        managed.pendingExpansionImage = nil
        managed.pendingExpansionSide = nil
        managed.snapshotTimer?.invalidate()
        managed.snapshotTimer = nil
        managed.snapshotTask?.cancel()
        managed.snapshotTask = nil
        managed.snapshotGeneration &+= 1
        managed.model.stopInteraction()
        managed.resizeDebounce?.cancel()
        managed.relayoutDebounce?.cancel()
        if let obs = managed.moveObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = managed.occlusionObserver { NotificationCenter.default.removeObserver(obs) }
        managed.speechObservation = nil; managed.settingsObservation = nil
        managed.peekPanel?.orderOut(nil)
        managed.peekPanel?.close()
        managed.peekPanel = nil
        managed.peekHost = nil
        managed.peekState.asset = nil
        managed.edge = nil
        managed.speechPanel?.orderOut(nil)
        managed.speechPanel?.close()
        managed.speechPanel = nil
        managed.taskPanel?.orderOut(nil)
        managed.taskPanel?.close()
        managed.taskPanel = nil
        managed.taskHost = nil
        managed.panel.orderOut(nil)
    }

    // MARK: - Position persistence (agentpet.petAnchors.v1)

    private func savePosition(_ managed: ManagedPetWindow) {
        guard let anchor = managed.placement.anchor else { return }
        positionStore.save(anchor, forKey: managed.model.key)
    }

    // MARK: - Drag to move (pet body)

    /// Current on-screen origin of a window, so a pet-body drag can anchor from it.
    func windowOrigin(forKey key: String) -> NSPoint? {
        windows[key]?.panel.frame.origin
    }

    /// Moves a window during a pet-body drag. `didMoveNotification` fires, which
    /// re-anchors and persists the position exactly like a window-background drag.
    func moveWindow(forKey key: String, to origin: NSPoint) {
        windows[key]?.panel.setFrameOrigin(origin)
    }

    // MARK: - Stats popover (per window)

    /// A screen-positioned status card, independent of the pet's hover layout.
    private let statsPanel = PetStatsPanelController()
    private let messageRestoration = PetMessageLayoutRestoration()
    private weak var statsModel: PetWindowModel?
    private var statsHost: NSHostingView<AnyView>?
    private var statsNoticeID: String?

    var hasVisibleIdleChatter: Bool {
        guard isVisible, !screensAsleep else { return false }
        return windows.values.contains { managed in
            let model = managed.model
            return !model.isShowingStats && !model.messagesTransitionHidden
                && !model.idleText.isEmpty && model.speechRows.isEmpty
                && PetSpeechView.notice(model).isEmpty && !PetMessagesView.hasContent(model)
                && managed.speechPanel?.isVisible == true
        }
    }

    func isSystemNoticeVisible(id: String) -> Bool {
        guard isVisible, !screensAsleep else { return false }
        for managed in windows.values {
            let model = managed.model
            guard model.noticeSource?.current?.id == id, !model.quotaText.isEmpty else { continue }
            if model.isShowingStats {
                guard statsModel === model, statsPanel.phase == .shown,
                      let marker = model.statusNoticeMarker, marker.noticeID == id,
                      marker.window?.isVisible == true, marker.window?.alphaValue == 1,
                      marker.bounds.width > 0, marker.bounds.height > 0 else { continue }
                let visible = marker.visibleRect.intersection(marker.bounds)
                if visible.width >= marker.bounds.width - 0.5 && visible.height >= marker.bounds.height - 0.5 { return true }
            } else if !model.messagesTransitionHidden, let panel = managed.speechPanel, panel.isVisible,
                      panel.frame.height >= managed.speechSize.height - 0.5 {
                return true
            }
        }
        return false
    }

    private func statsView(for model: PetWindowModel, showNotice: Bool = true) -> PetStatsView {
        PetStatsView(petID: model.petID, noticeSource: model.noticeSource ?? PetController.shared.systemNotices,
                     noticeModel: model, showSystemNotice: showNotice, refreshUsage: refreshStatsUsage)
    }
    private func statsContent(for model: PetWindowModel, size: NSSize) -> AnyView {
        AnyView(VStack(spacing: 0) {
            if BubbleSettings.shared.superchatEnabled, let source = model.noticeSource, let notice = source.current {
                SystemNoticeView(source: source, notice: notice, width: min(272, max(1, size.width - 28)))
                    .background(SystemNoticeMarker(model: model, id: notice.id))
                    .padding(.horizontal, 14).padding(.top, 14)
            }
            ScrollView(.vertical) { statsView(for: model, showNotice: false) }
        }
            .frame(width: size.width, height: size.height)
            .background(StatusHUDStyle.background).clipShape(RoundedRectangle(cornerRadius: 12)))
    }
    private func statsNaturalSize(for model: PetWindowModel) -> NSSize {
        var size = NSHostingView(rootView: statsView(for: model, showNotice: false)).fittingSize
        if BubbleSettings.shared.superchatEnabled, let source = model.noticeSource, let notice = source.current {
            size.height += NSHostingView(rootView: SystemNoticeView(source: source, notice: notice, width: 272)).fittingSize.height + 14
        }
        return size
    }
    private func refreshStatsNoticeLayout(_ model: PetWindowModel) {
        guard statsModel === model, statsPanel.phase == .shown, let host = statsHost,
              statsNoticeID != model.noticeSource?.current?.id,
              let anchor = presentationPetFrame(for: model) else { return }
        guard let visible = screen(containing: NSPoint(x: anchor.midX, y: anchor.midY), fallback: anchor)?.visibleFrame else { return }
        let measured = statsNaturalSize(for: model)
        let frame = PetStatsPanelController.frame(anchor: anchor, contentSize: measured, visible: visible)
        statsNoticeID = model.noticeSource?.current?.id
        host.rootView = statsContent(for: model, size: frame.size)
        statsPanel.resize(frame: frame)
    }

    func closeStatsPopover() { statsPanel.close() }

    func showStatsPopover(of view: NSView, model: PetWindowModel, openingEvent: NSEvent) {
        guard let window = view.window, !view.bounds.isEmpty else { return }
        if statsPanel.isPresented && statsModel === model { return }
        statsPanel.dismissImmediately()
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        guard let visible = screen(containing: NSPoint(x: anchor.midX, y: anchor.midY),
                                   fallback: anchor)?.visibleFrame else { return }
        let natural = statsNaturalSize(for: model)
        let frame = PetStatsPanelController.frame(anchor: anchor, contentSize: natural, visible: visible)
        let host = NSHostingView(rootView: statsContent(for: model, size: frame.size))
        statsHost = host; statsNoticeID = model.noticeSource?.current?.id
        statsModel = model
        let messages = messageSnapshot(model, live: true)
        statsPanel.show(content: host, frame: frame, petBody: { [weak view] in view },
            openingEvent: openingEvent, messages: messages, hideMessages: { [weak model] in
                model?.isShowingStats = true
            }, restoreMessages: { [weak self, weak model] completion in
                guard let self, let model else { completion(nil); return }
                self.messageRestoration.begin(model: model, hasContent: PetMessagesView.hasContent(model),
                    capture: { [weak self, weak model] in
                        guard let self, let model, self.statsModel === model,
                              let marker = model.messageBubbleView, let window = marker.window,
                              marker.bounds.width > 0, marker.bounds.height > 0 else { return nil }
                        if let content = window.contentView {
                            content.layoutSubtreeIfNeeded()
                            if let managed = self.windows[model.key] { self.layoutSpeech(managed) }
                            content.layoutSubtreeIfNeeded()
                        }
                        return self.messageSnapshot(model, live: false)
                    }, completion: completion)
            }, visibilityChanged: { [weak self, weak model] _ in
                guard let self, let model else { return }
                self.refreshStatsNoticeLayout(model)
            }, onClose: { [weak self, weak model] in
                self?.statsHost = nil; self?.statsNoticeID = nil
                self?.messageRestoration.cancel()
                model?.onMessageLayoutReady = nil
                model?.messagesTransitionHidden = false
                model?.isShowingStats = false
            })
        NSApp.activate(ignoringOtherApps: true)
        statsPanel.makeKey()
    }

    private func messageSnapshot(_ model: PetWindowModel, live: Bool) -> PetBubbleSnapshot? {
        guard PetMessagesView.hasContent(model), let marker = model.messageBubbleView,
              let window = marker.window, let content = window.contentView,
              marker.bounds.width > 0, marker.bounds.height > 0 else { return nil }
        let rect = content.convert(marker.bounds, from: marker)
        let frame = window.convertToScreen(content.convert(rect, to: nil))
        if live { return PetBubbleSnapshot.capture(view: content, rect: rect, frame: frame) }
        return PetBubbleSnapshot.messages(model: model, frame: frame)
    }

    // MARK: - Resize (per window)

    /// Sizes the panel hosting `key` to hug the pet + bubble content.
    func resizeToContent(_ size: CGSize, forKey key: String) {
        guard size.width > 0, size.height > 0, let managed = windows[key] else { return }
        ResizeMetrics.log("content", size)

        managed.resizeDebounce?.cancel()
        // Growing content is drawn clipped until the window catches up, so
        // widen/heighten right away (never shrinking in this step). The exact
        // fit, including any shrink, still waits for the debounce so a burst
        // of intermediate sizes (spring animations) doesn't jitter the window.
        let current = managed.panel.frame.size
        let target = Self.padded(size)
        if target.width > current.width + 1 || target.height > current.height + 1 {
            resizeIfChanged(managed, to: CGSize(width: max(target.width, current.width),
                                                height: max(target.height, current.height)))
        }
        let work = DispatchWorkItem { [weak self, weak managed] in
            guard let self, let managed, self.windows[key] === managed else { return }
            self.resizeIfChanged(managed, to: Self.padded(size))
        }
        managed.resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Window size for measured content: a small margin on every side.
    private static func padded(_ content: CGSize) -> CGSize {
        CGSize(width: content.width + 4, height: content.height + 4)
    }

    /// Resizes to `padded` unless it is within 1pt of the last applied size.
    private func resizeIfChanged(_ managed: ManagedPetWindow, to padded: CGSize) {
        let dw = abs(padded.width - managed.lastContentSize.width)
        let dh = abs(padded.height - managed.lastContentSize.height)
        guard dw > 1 || dh > 1 || managed.lastContentSize == .zero else { return }
        managed.lastContentSize = padded
        resizeInPlace(managed, to: padded)
    }

    private func remeasureAll() {
        for managed in windows.values { remeasureContent(managed) }
    }

    private func remeasureContent(_ managed: ManagedPetWindow) {
        let key = managed.model.key
        DispatchQueue.main.async { [weak self, weak managed] in
            guard let self, let managed, self.windows[key] === managed,
                  let host = managed.panel.contentView as? ClickThroughHostingView<FloatingPetView> else { return }
            host.invalidateIntrinsicContentSize()
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            guard size.width > 0, size.height > 0 else { return }
            self.resizeToContent(size, forKey: key)
        }
    }

    /// Resizes around a fixed bottom-center anchor so the pet doesn't drift.
    /// The window is kept inside the visible frame of the pet's screen so a wide
    /// bubble never spills onto a neighbouring display; when that pushes the
    /// window sideways, the pet (and the bubble's tail) is offset inside the
    /// window by the same amount, so the pet itself stays put on screen.
    private func resizeInPlace(_ managed: ManagedPetWindow, to size: CGSize) {
        guard let anchor = managed.placement.anchor else { return }
        let probe = NSRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height)
        let visible = screen(containing: anchor, fallback: probe)?.visibleFrame
        guard let layout = managed.placement.layout(size: size, petWidth: PetController.shared.petPoint,
                                                    visible: visible) else { return }
        let petOffset = layout.petOffset
        managed.isApplyingLayout = true
        defer { managed.isApplyingLayout = false }
        if managed.model.petOffset != petOffset || managed.model.windowWidth != size.width {
            managed.model.petOffset = petOffset
            managed.model.windowWidth = size.width
            // Flush the new offset into the hosting view now, so the window
            // move and the pet's counter-shift land in the same frame
            // (otherwise the pet flashes at the old spot for one frame).
            managed.panel.contentView?.layoutSubtreeIfNeeded()
        }
        managed.panel.setFrame(layout.frame, display: true, animate: false)
        if managed.edge != nil { layoutEdgePanel(managed) }
        layoutSpeech(managed)
        ResizeMetrics.log("window", size)
    }

    private func scheduleCompanionLayout(key: String) {
        guard let managed = windows[key], !managed.companionLayoutScheduled else { return }
        managed.companionLayoutScheduled = true
        DispatchQueue.main.async { [weak self, weak managed] in
            guard let self, let managed, self.windows[key] === managed else { return }
            managed.companionLayoutScheduled = false
            self.layoutSpeech(managed)
        }
    }

    private func layoutSpeech(_ managed: ManagedPetWindow) {
        if let edge = managed.edge {
            layoutEdgeCompanions(managed, edge: edge)
            return
        }
        defer {
            layoutTask(managed)
            PetController.shared.reconcileIdleChatter()
        }
        refreshStatsNoticeLayout(managed.model)
        guard let panel = managed.speechPanel, let anchor = managed.placement.anchor else { return }
        panel.ignoresMouseEvents = managed.model.noticeSource?.current?.requiresAcknowledgment != true
            || managed.model.quotaText.isEmpty
        let showing = isVisible && !screensAsleep && !managed.model.isShowingStats
            && !managed.model.messagesTransitionHidden && PetSpeechView.hasContent(managed.model)
        if !PetSpeechView.hasContent(managed.model) {
            panel.orderOut(nil)
            if managed.model.speechHeight != 0 { managed.model.speechHeight = 0; remeasureContent(managed) }
            return
        }
        let available = screen(containing: anchor, fallback: managed.panel.frame)?.visibleFrame
        let noticeWidth = max(1, min(380, (available?.width ?? 392) - 12))
        if managed.model.noticeWidth != noticeWidth { managed.model.noticeWidth = noticeWidth }
        panel.contentView?.layoutSubtreeIfNeeded()
        let natural = panel.contentView?.fittingSize ?? managed.speechSize
        let frame = PetSpeechPanelGeometry.frame(anchor: anchor, petSize: PetController.shared.petPoint,
            content: natural, visible: screen(containing: anchor, fallback: managed.panel.frame)?.visibleFrame,
            important: !managed.model.quotaText.isEmpty && managed.model.noticeSource?.current != nil)
        guard frame.height > 0 else { panel.orderOut(nil); return }
        panel.setFrame(frame, display: true, animate: false)
        if abs(managed.model.speechHeight - frame.height) > 0.5 {
            managed.model.speechHeight = frame.height
            remeasureContent(managed)
        }
        if showing { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    private func layoutTask(_ managed: ManagedPetWindow) {
        if managed.edge != nil {
            // The peek path lays speech and task out together in
            // `layoutEdgeCompanions`; never place a second, overlapping stack.
            return
        }
        guard let panel = managed.taskPanel else {
            applyTaskBubbleClickThrough(managed, bubbleVisible: false)
            return
        }
        guard let anchor = managed.placement.anchor else {
            applyTaskBubbleClickThrough(managed, bubbleVisible: false)
            panel.orderOut(nil)
            return
        }
        guard isVisible && !screensAsleep && !managed.model.isShowingStats
            && !managed.model.messagesTransitionHidden
            && PetMessagesView.hasContent(managed.model) else {
            applyTaskBubbleClickThrough(managed, bubbleVisible: false)
            panel.orderOut(nil); return
        }
        guard let host = managed.taskHost else {
            applyTaskBubbleClickThrough(managed, bubbleVisible: false)
            panel.orderOut(nil); return
        }
        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else {
            applyTaskBubbleClickThrough(managed, bubbleVisible: false)
            panel.orderOut(nil); return
        }
        if managed.model.taskContentSize != size { managed.model.taskContentSize = size }
        if host.frame.size != size { host.setFrameSize(size) }
        let y = anchor.y + PetController.shared.petPoint + 4 + managed.model.speechHeight
        let visible = screen(containing: anchor, fallback: managed.panel.frame)?.visibleFrame
        let screenLimit = max(0, (visible?.maxY ?? y + size.height) - y)
        // Keep the existing expanded-list cap (260pt plus bubble chrome), with
        // one native viewport handling both this cap and the screen edge.
        let limit = managed.model.messageListExpanded ? min(screenLimit, 293) : screenLimit
        if managed.model.taskHeightLimit != limit { managed.model.taskHeightLimit = limit }
        let width = min(size.width, visible?.width ?? size.width)
        var x = anchor.x + PetController.shared.petPoint / 2 - width
        if let visible { x = max(visible.minX, min(x, visible.maxX - width)) }
        let height = min(size.height, limit)
        guard height > 0 else {
            applyTaskBubbleClickThrough(managed, bubbleVisible: false)
            panel.orderOut(nil); return
        }
        let offset = anchor.x - (x + width / 2)
        if managed.model.taskWindowWidth != width { managed.model.taskWindowWidth = width }
        if managed.model.taskPetOffset != offset { managed.model.taskPetOffset = offset }
        // Recompute on every layout: the saved preference may be unchanged
        // while the displayed approval/waiting/failure rows appear or clear.
        applyTaskBubbleClickThrough(managed, bubbleVisible: true)
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if managed.lastTaskFrame != frame {
            managed.lastTaskFrame = frame
            // SwiftUI switches the content size immediately. Interpolating the
            // native viewport size clips that new content until the animation
            // finishes (especially on hover). Only animate positional changes.
            if panel.frame.size == frame.size && panel.isVisible
                && PetController.shared.animationsEnabled && !managed.model.isAnimationDragging
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !managed.model.messagesTransitionHidden {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    panel.animator().setFrame(frame, display: true)
                }
            } else { panel.setFrame(frame, display: true, animate: false) }
        }
        if managed.model.messagesTransitionHidden { panel.orderOut(nil) }
        else { panel.orderFrontRegardless() }
    }

    // MARK: - Edge peek

    private func edgeScreens() -> [PetEdgeScreen] {
        NSScreen.screens.map {
            PetEdgeScreen(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
    }

    private func peekAsset(for managed: ManagedPetWindow) -> EdgePeekAsset? {
        if let override = peekAssetOverride { return override(managed.model.petID ?? "") }
        guard let id = managed.model.petID else { return nil }
        return ImagePetStore.shared.pack(id: id)?.effectivePeekAsset
    }

    private func packsDidChange() {
        for managed in windows.values {
            if managed.edge != nil {
                if peekAsset(for: managed) != nil {
                    layoutEdgePanel(managed)
                    layoutSpeech(managed)
                } else {
                    recoverFromMissingPeek(managed)
                }
            } else {
                restoreEdgeIfNeeded(managed)
            }
        }
    }

    private func recoverFromMissingPeek(_ managed: ManagedPetWindow) {
        guard managed.edge != nil else { return }
        exitEdge(managed, persist: false)
        edgeStore.clear(forKey: managed.model.key)
        managed.pendingEdgeRestore = nil
        managed.didAttemptEdgeRestore = true
        fitAnchorOnScreen(managed)
        resizeInPlace(managed, to: managed.panel.frame.size)
        savePosition(managed)
        if isVisible && !screensAsleep { managed.panel.orderFrontRegardless() }
        layoutSpeech(managed)
        NSLog("AgentPet Lite: edge peek unavailable; restored the ordinary pet")
    }

    /// Attempts a persisted tuck once the pet's pack is loaded. Retries on pack
    /// changes instead of clearing a valid preference because of startup order.
    private func restoreEdgeIfNeeded(_ managed: ManagedPetWindow) {
        guard let side = managed.pendingEdgeRestore,
              !managed.didAttemptEdgeRestore else { return }
        guard let id = managed.model.petID else { return }
        let asset: EdgePeekAsset?
        if let override = peekAssetOverride {
            asset = override(id)
        } else if let pack = ImagePetStore.shared.pack(id: id) {
            asset = pack.effectivePeekAsset
        } else {
            return
        }
        managed.didAttemptEdgeRestore = true
        guard let asset else {
            managed.pendingEdgeRestore = nil
            edgeStore.clear(forKey: managed.model.key)
            fitAnchorOnScreen(managed)
            resizeInPlace(managed, to: managed.panel.frame.size)
            savePosition(managed)
            return
        }
        guard let anchor = managed.placement.anchor,
              let restored = PetEdgeGeometry.restoration(
                side: side, anchor: anchor, petSize: CGFloat(PetController.shared.petPoint),
                screens: edgeScreens()) else {
            managed.pendingEdgeRestore = nil
            edgeStore.clear(forKey: managed.model.key)
            fitAnchorOnScreen(managed)
            resizeInPlace(managed, to: managed.panel.frame.size)
            savePosition(managed)
            return
        }
        managed.pendingEdgeRestore = nil
        managed.placement.anchor = restored.anchor
        if !enterEdge(managed, side: restored.side, visible: restored.visibleFrame,
                      asset: asset, anchorY: restored.anchor.y, animated: false, persist: false) {
            edgeStore.clear(forKey: managed.model.key)
            fitAnchorOnScreen(managed)
            resizeInPlace(managed, to: managed.panel.frame.size)
        }
        savePosition(managed)
    }

    @discardableResult
    private func enterEdge(_ managed: ManagedPetWindow, side: PetEdgeSide, visible: NSRect,
                           asset: EdgePeekAsset, anchorY: CGFloat, animated: Bool,
                           persist: Bool, visibleSnapshot: PetEdgeSnapshot? = nil) -> Bool {
        let petSize = CGFloat(PetController.shared.petPoint)
        let maxY = max(visible.minY, visible.maxY - petSize)
        let anchor = NSPoint(x: side == .left ? visible.minX : visible.maxX,
                             y: min(max(anchorY, visible.minY), maxY))
        guard let layout = PetEdgeGeometry.peekLayout(
            anchor: anchor, petSize: petSize, contentSize: asset.contentSize,
            visible: visible, side: side) else { return false }
        let animatedVisual = animated && PetController.shared.animationsEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A collapse without a trustworthy visible source would have to hide the
        // body first; keep the ordinary pet instead of a blank/faded gap.
        let snapshot = animatedVisual
            ? (visibleSnapshot ?? PetEdgeSnapshotter.rebased(managed.preparedSnapshot, model: managed.model,
                                          dragSession: managed.model.animationDragSession)
                ?? (forceStaticSnapshotFailureForTesting
                    ? nil : PetEdgeSnapshotter.captureStatic(model: managed.model)))
            : nil
        if animatedVisual, snapshot == nil { return false }
        lastCollapseSourceFrameForTesting = snapshot?.frame
        managed.preparedSnapshot = nil

        cancelClickSequence(managed)
        managed.edgeTransition?.cancel()
        managed.edgeTransition = nil
        managed.edgeGeneration &+= 1
        let generation = managed.edgeGeneration
        managed.placement.anchor = anchor
        managed.edge = PetEdgePresentation(side: side, frame: layout.frame, visible: visible)
        managed.model.messageHoverExpansionEnabled = false
        managed.peekState.update(asset: asset, side: side,
                                 cropsInnerSide: layout.cropsInnerSide)
        managed.peekPanel?.setFrame(layout.frame, display: false, animate: false)
        managed.panel.orderOut(nil)
        managed.model.isOnScreen = true
        if persist {
            savePosition(managed)
            edgeStore.save(side, forKey: managed.model.key)
        }
        if animatedVisual, let snapshot {
            managed.isEdgeTransitioning = true
            // The final peek target is visible during the crossfade, while the
            // interactive funnel overlay below owns down/up/drag.
            managed.peekPanel?.alphaValue = 0
            if isVisible && !screensAsleep { managed.peekPanel?.orderFrontRegardless() }
            let transition = PetEdgeTransition()
            managed.edgeTransition = transition
            let duration = PetEdgeTransition.collapseDuration
            transition.animate(snapshot: snapshot, to: layout.frame, side: side,
                               collapsing: true, duration: duration,
                               interactive: true, holdAtEnd: true) { [weak self, weak managed] in
                MainActor.assumeIsolated {
                    guard let self, let managed, self.windows[managed.model.key] === managed,
                          managed.edgeGeneration == generation, managed.edge != nil,
                          let transition = managed.edgeTransition else { return }
                    self.beginPeekCrossfade(managed, transition: transition, generation: generation)
                }
            }
            scheduleEdgeTransitionFallback(managed, generation: generation,
                                           after: duration + 0.25)
        } else {
            showPeek(managed)
        }
        layoutSpeech(managed)
        return true
    }

    private func scheduleEdgeTransitionFallback(_ managed: ManagedPetWindow,
                                                generation: UInt64,
                                                after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak managed] in
            guard let self, let managed, self.windows[managed.model.key] === managed,
                  managed.isEdgeTransitioning, managed.edgeGeneration == generation,
                  managed.edge != nil else { return }
            if let transition = managed.edgeTransition {
                self.beginPeekCrossfade(managed, transition: transition, generation: generation)
            } else {
                managed.isEdgeTransitioning = false
                self.showPeek(managed)
            }
        }
    }

    /// Replaces the final funnel mesh with the static peek over a short fade so
    /// completion does not hard-cut from the compressed movie frame to another
    /// face. The mesh is already cropped to its alpha content by the snapshotter.
    private func beginPeekCrossfade(_ managed: ManagedPetWindow,
                                    transition: PetEdgeTransition,
                                    generation: UInt64) {
        guard let panel = managed.peekPanel, let edge = managed.edge,
              managed.edgeGeneration == generation else { return }
        panel.setFrame(edge.frame, display: false, animate: false)
        panel.alphaValue = 0
        if isVisible && !screensAsleep { panel.orderFrontRegardless() }
        guard let image = managed.peekState.asset?.presentationImage(size: edge.frame.size,
              side: edge.side, cropsInnerSide: managed.peekState.cropsInnerSide) else {
            managed.isEdgeTransitioning = false
            showPeek(managed)
            return
        }
        transition.crossfade(to: PetEdgeSnapshot(image: image, frame: edge.frame), duration: 0.08) { [weak self, weak managed] in
            guard let self, let managed, self.windows[managed.model.key] === managed,
                  managed.edgeGeneration == generation, managed.edge != nil else { return }
            managed.isEdgeTransitioning = false
            managed.edgeTransition = nil
            self.showPeek(managed)
        }
    }

    private func showPeek(_ managed: ManagedPetWindow) {
        guard let panel = managed.peekPanel, let edge = managed.edge else { return }
        panel.setFrame(edge.frame, display: false, animate: false)
        panel.alphaValue = 1
        managed.edgeTransition?.cancel()
        managed.edgeTransition = nil
        if isVisible && !screensAsleep { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        updateOnScreen(managed)
        layoutSpeech(managed)
    }

    /// Removes the visual tuck. Position/anchor ownership stays with the caller
    /// so a drag can anchor the expanded pet before this is called.
    private func exitEdge(_ managed: ManagedPetWindow, persist: Bool) {
        managed.edgeTransition?.cancel()
        managed.edgeTransition = nil
        managed.edgeGeneration &+= 1
        managed.isEdgeTransitioning = false
        managed.expandTransition?.cancel()
        managed.expandTransition = nil
        managed.isExpandTransitioning = false
        managed.pendingExpansionImage = nil
        managed.pendingExpansionSide = nil
        managed.edge = nil
        managed.peekState.asset = nil
        managed.model.messageHoverExpansionEnabled = true
        managed.peekPanel?.alphaValue = 1
        managed.peekPanel?.orderOut(nil)
        managed.pendingEdgeRestore = nil
        managed.didAttemptEdgeRestore = true
        if persist { edgeStore.clear(forKey: managed.model.key) }
        if isVisible && !screensAsleep { managed.panel.orderFrontRegardless() }
        managed.model.isOnScreen = true
        updateOnScreen(managed)
    }

    private func layoutEdgePanel(_ managed: ManagedPetWindow) {
        guard let edge = managed.edge, let asset = peekAsset(for: managed),
              let anchor = managed.placement.anchor,
              let layout = PetEdgeGeometry.peekLayout(
                anchor: anchor, petSize: CGFloat(PetController.shared.petPoint),
                contentSize: asset.contentSize, visible: edge.visible, side: edge.side) else {
            return
        }
        if managed.edge != PetEdgePresentation(side: edge.side, frame: layout.frame, visible: edge.visible) {
            managed.edge = PetEdgePresentation(side: edge.side, frame: layout.frame, visible: edge.visible)
        }
        managed.peekState.update(asset: asset, side: edge.side,
                                 cropsInnerSide: layout.cropsInnerSide)
        managed.peekPanel?.setFrame(layout.frame, display: false, animate: false)
        if !managed.isEdgeTransitioning {
            if isVisible && !screensAsleep { managed.peekPanel?.orderFrontRegardless() }
            else { managed.peekPanel?.orderOut(nil) }
        }
    }

    /// The pet rectangle actually visible/interactive: the peek content while
    /// tucked, otherwise the body marker (not the transparent panel padding).
    private func presentationPetFrame(_ managed: ManagedPetWindow) -> NSRect {
        if let edge = managed.edge { return edge.frame }
        if let body = managed.model.petBodyView, let window = body.window,
           body.bounds.width > 0, body.bounds.height > 0 {
            return window.convertToScreen(body.convert(body.bounds, to: nil))
        }
        let size = CGFloat(PetController.shared.petPoint)
        let anchor = managed.placement.anchor ?? NSPoint(x: managed.panel.frame.midX,
                                                         y: managed.panel.frame.minY)
        return NSRect(x: anchor.x - size / 2, y: anchor.y, width: size, height: size)
    }

    private func presentationPetFrame(for model: PetWindowModel) -> NSRect? {
        guard let managed = windows.values.first(where: { $0.model === model }) else { return nil }
        return presentationPetFrame(managed)
    }

    /// Lays out speech + task as one stack around the peek content. Normal
    /// bubbles deliberately keep their existing independent geometry.
    private func layoutEdgeCompanions(_ managed: ManagedPetWindow, edge: PetEdgePresentation) {
        defer { PetController.shared.reconcileIdleChatter() }
        refreshStatsNoticeLayout(managed.model)
        if let peek = managed.peekPanel {
            if !isVisible || screensAsleep { peek.orderOut(nil) }
            else if !managed.isEdgeTransitioning { peek.orderFrontRegardless() }
        }
        guard let speechPanel = managed.speechPanel, let taskPanel = managed.taskPanel else { return }
        let available = edge.visible
        let margin: CGFloat = 8
        let showing = isVisible && !screensAsleep && !managed.model.isShowingStats
            && !managed.model.messagesTransitionHidden
        let hasSpeech = showing && PetSpeechView.hasContent(managed.model)
        let hasTask = showing && PetMessagesView.hasContent(managed.model)

        speechPanel.ignoresMouseEvents = managed.model.noticeSource?.current?.requiresAcknowledgment != true
            || managed.model.quotaText.isEmpty
        var speechSize = CGSize.zero
        if hasSpeech {
            let noticeWidth = max(1, min(380, available.width - margin * 2))
            if managed.model.noticeWidth != noticeWidth { managed.model.noticeWidth = noticeWidth }
            speechPanel.contentView?.layoutSubtreeIfNeeded()
            speechSize = speechPanel.contentView?.fittingSize ?? managed.speechSize
        } else {
            speechPanel.orderOut(nil)
            if managed.model.speechHeight != 0 { managed.model.speechHeight = 0 }
        }

        var taskSize = CGSize.zero
        if hasTask, let host = managed.taskHost {
            host.invalidateIntrinsicContentSize()
            host.layoutSubtreeIfNeeded()
            taskSize = host.fittingSize
            if managed.model.taskContentSize != taskSize { managed.model.taskContentSize = taskSize }
        }

        let stack = PetEdgeGeometry.bubbleStack(
            petFrame: edge.frame, speechSize: speechSize, taskSize: taskSize,
            visible: available, margin: margin, gap: 6, stackGap: 4)

        if let frame = stack.speechFrame {
            speechPanel.setFrame(frame, display: false, animate: false)
            if abs(managed.model.speechHeight - frame.height) > 0.5 {
                managed.model.speechHeight = frame.height
            }
            speechPanel.orderFrontRegardless()
        } else {
            speechPanel.orderOut(nil)
            if managed.model.speechHeight != 0 { managed.model.speechHeight = 0 }
        }

        guard hasTask, let host = managed.taskHost else {
            applyTaskBubbleClickThrough(managed, bubbleVisible: false)
            taskPanel.orderOut(nil)
            return
        }
        guard let frame = stack.taskFrame, frame.height >= 1, frame.width >= 1 else {
            applyTaskBubbleClickThrough(managed, bubbleVisible: false)
            taskPanel.orderOut(nil)
            return
        }
        if host.frame.size != taskSize { host.setFrameSize(taskSize) }
        let width = min(taskSize.width, max(1, available.width - margin * 2))
        if managed.model.taskWindowWidth != width { managed.model.taskWindowWidth = width }
        let offset = edge.frame.midX - (frame.minX + width / 2)
        if managed.model.taskPetOffset != offset { managed.model.taskPetOffset = offset }
        let height = min(taskSize.height, frame.height)
        if managed.model.taskHeightLimit != height { managed.model.taskHeightLimit = height }
        applyTaskBubbleClickThrough(managed, bubbleVisible: true)
        let target = NSRect(x: frame.minX, y: frame.minY, width: width, height: height)
        if managed.lastTaskFrame != target {
            managed.lastTaskFrame = target
            taskPanel.setFrame(target, display: true, animate: false)
        }
        taskPanel.orderFrontRegardless()
    }

    /// Samples the actual movie frame off the main thread while a drag is
    /// active. Release uses the latest ready sample; a short drag falls back to
    /// the visible poster/static capture without ever blocking on video decode.
    private func startSnapshotSampling(_ managed: ManagedPetWindow) {
        stopSnapshotSampling(managed, keepPrepared: false)
        sampleSnapshot(managed)
        managed.lastSnapshotRequestAt = 0
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self, weak managed] _ in
            Task { @MainActor [weak self, weak managed] in
                guard let self, let managed, self.windows[managed.model.key] === managed,
                      managed.isDragging else { return }
                self.sampleSnapshot(managed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        managed.snapshotTimer = timer
    }

    private func stopSnapshotSampling(_ managed: ManagedPetWindow, keepPrepared: Bool) {
        managed.snapshotTimer?.invalidate()
        managed.snapshotTimer = nil
        managed.snapshotGeneration &+= 1
        managed.snapshotTask?.cancel()
        managed.snapshotTask = nil
        if !keepPrepared { managed.preparedSnapshot = nil }
    }

    private func sampleSnapshot(_ managed: ManagedPetWindow) {
        startPendingExpansion(managed)
        guard managed.snapshotTask == nil,
              ProcessInfo.processInfo.systemUptime - managed.lastSnapshotRequestAt >= 0.15 else { return }
        managed.snapshotGeneration &+= 1
        let generation = managed.snapshotGeneration
        let task = PetEdgeSnapshotter.sampleAsync(model: managed.model,
            dragSession: managed.model.animationDragSession) { [weak self, weak managed] snapshot in
            guard let self, let managed, self.windows[managed.model.key] === managed,
                  managed.snapshotGeneration == generation else { return }
            managed.snapshotTask = nil
            if let snapshot {
                managed.preparedSnapshot = snapshot
                if let current = PetEdgeSnapshotter.rebased(snapshot, model: managed.model,
                    dragSession: managed.model.animationDragSession) {
                    managed.expandTransition?.updateExpansionBody(current)
                }
            }
        }
        managed.snapshotTask = task
        if task != nil { managed.lastSnapshotRequestAt = ProcessInfo.processInfo.systemUptime }
        if task == nil { managed.snapshotTask = nil }
    }

    private func settleAfterDrag(_ managed: ManagedPetWindow, visibleSnapshot: PetEdgeSnapshot? = nil) {
        let bodyFrame = presentationPetFrame(managed)
        // A movie's canvas can be much wider than its visible character. Reuse
        // the same alpha-cropped source as the collapse, rebased after movement.
        // If no trustworthy content is ready, keep the ordinary body instead of
        // attracting it early from an invisible canvas edge.
        let source = visibleSnapshot ?? PetEdgeSnapshotter.rebased(managed.preparedSnapshot,
            model: managed.model, dragSession: managed.model.animationDragSession)
            ?? (forceStaticSnapshotFailureForTesting ? nil : PetEdgeSnapshotter.captureStatic(model: managed.model))
        let snapDistance: CGFloat = 10
        let suppressSnap = managed.suppressSnapOnEnd && !managed.dragMoved
        managed.suppressSnapOnEnd = false
        if !suppressSnap, let source,
           let snap = PetEdgeGeometry.snap(petFrame: source.frame, screens: edgeScreens(),
                                           snapDistance: snapDistance),
           let asset = peekAsset(for: managed),
           enterEdge(managed, side: snap.side, visible: snap.visibleFrame, asset: asset,
                     anchorY: bodyFrame.minY, animated: true, persist: true,
                     visibleSnapshot: source) {
            return
        }
        managed.preparedSnapshot = nil
        fitAnchorOnScreen(managed)
        resizeInPlace(managed, to: managed.panel.frame.size)
        savePosition(managed)
        layoutSpeech(managed)
    }

    private func beginPetDrag(_ managed: ManagedPetWindow) {
        guard !managed.isDragging else { return }
        managed.isDragging = true
        managed.mouseDragActive = false
        managed.dragMoved = false
        managed.suppressSnapOnEnd = false
        managed.relayoutDebounce?.cancel()
        managed.model.animationDragSession &+= 1
        managed.model.isAnimationDragging = true
        managed.model.isOnScreen = true
        updateOnScreen(managed)
        startSnapshotSampling(managed)
    }

    private func endPetDrag(_ managed: ManagedPetWindow) {
        guard managed.isDragging else { return }
        cancelClickSequence(managed)
        let visibleSnapshot = managed.expandTransition?.visibleExpansionSnapshot()
        managed.isDragging = false
        managed.mouseDragActive = false
        managed.model.isAnimationDragging = false
        managed.transitionRoutePanel = nil
        managed.expandTransition?.cancel()
        managed.expandTransition = nil
        managed.isExpandTransitioning = false
        managed.pendingExpansionImage = nil
        managed.pendingExpansionSide = nil
        managed.relayoutDebounce?.cancel()
        stopSnapshotSampling(managed, keepPrepared: true)
        updateOnScreen(managed)
        settleAfterDrag(managed, visibleSnapshot: visibleSnapshot)
    }

    /// A real drag from the peek immediately restores the full body at the edge,
    /// starts the drag movie at frame 0 and follows the cursor from that point.
    private func beginDragFromPeek(_ managed: ManagedPetWindow, at screenPoint: NSPoint,
                                   visibleSnapshot: PetEdgeSnapshot? = nil) {
        guard let edge = managed.edge else { return }
        let visible = edge.visible
        let side = edge.side
        let peekFrame = visibleSnapshot?.frame ?? edge.frame
        let peekImage = visibleSnapshot?.image
            ?? (managed.peekState.asset ?? peekAsset(for: managed))?
                .presentationImage(size: peekFrame.size, side: side,
                                   cropsInnerSide: managed.peekState.cropsInnerSide)
        let petSize = CGFloat(PetController.shared.petPoint)
        let petCenterX = side == .right ? visible.maxX - petSize / 2 : visible.minX + petSize / 2
        let maxY = max(visible.minY, visible.maxY - petSize)
        let petBottomY = min(max(peekFrame.midY - petSize / 2, visible.minY), maxY)
        managed.placement.anchor = NSPoint(x: petCenterX, y: petBottomY)
        exitEdge(managed, persist: true)
        let size = managed.panel.frame.size.width > 0 ? managed.panel.frame.size
            : CGSize(width: petSize + 24, height: petSize + 24)
        resizeInPlace(managed, to: size)
        managed.panel.orderFrontRegardless()
        managed.model.isOnScreen = true
        managed.panel.contentView?.layoutSubtreeIfNeeded()
        managed.dragStartOrigin = managed.panel.frame.origin
        managed.dragStartMouse = screenPoint
        managed.isDragging = true
        managed.mouseDragActive = true
        managed.dragMoved = false
        managed.suppressSnapOnEnd = false
        managed.model.animationDragSession &+= 1
        managed.model.isAnimationDragging = true
        updateOnScreen(managed)
        if let peekImage, PetController.shared.animationsEnabled,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = PetEdgeTransition()
            managed.expandTransition = transition
            managed.isExpandTransitioning = true
            managed.pendingExpansionImage = peekImage
            managed.pendingExpansionSide = side
            managed.expansionRequestedAt = ProcessInfo.processInfo.systemUptime
            transition.holdExpansion(snapshot: PetEdgeSnapshot(image: peekImage, frame: peekFrame),
                                     in: managed.panel)
        }
        startSnapshotSampling(managed)
        savePosition(managed)
        layoutSpeech(managed)
    }

    /// Do not choose a target from the pre-drag SwiftUI hierarchy. The tiny
    /// held peek already follows the pointer while the requested selection lands.
    private func startPendingExpansion(_ managed: ManagedPetWindow) {
        guard managed.isDragging, let transition = managed.expandTransition,
              let image = managed.pendingExpansionImage,
              let side = managed.pendingExpansionSide,
              let sourceFrame = transition.expandPanel?.frame else { return }
        let body: PetEdgeSnapshot?
        if PetEdgeSnapshotter.videoView(model: managed.model) != nil {
            body = PetEdgeSnapshotter.rebased(managed.preparedSnapshot, model: managed.model,
                        dragSession: managed.model.animationDragSession)
                ?? PetEdgeSnapshotter.dragPoster(model: managed.model,
                                                dragSession: managed.model.animationDragSession)
        } else {
            body = PetEdgeSnapshotter.captureStatic(model: managed.model)
        }
        let target = body?.frame
        let timedOut = ProcessInfo.processInfo.systemUptime - managed.expansionRequestedAt > 0.25
        guard let target = target ?? (timedOut ? presentationPetFrame(managed) : nil) else { return }
        lastExpansionIdentityForTesting = PetEdgeSnapshotter.videoView(model: managed.model)?.frameIdentity
        managed.pendingExpansionImage = nil
        managed.pendingExpansionSide = nil
        let session = managed.model.animationDragSession
        let liveSnapshot: (() -> PetEdgeSnapshot?)? = PetEdgeSnapshotter.videoView(model: managed.model) == nil
            ? nil : { [weak managed] in
                guard let managed, managed.model.animationDragSession == session else { return nil }
                return PetEdgeSnapshotter.rebased(managed.preparedSnapshot, model: managed.model,
                    dragSession: session) ?? PetEdgeSnapshotter.dragPoster(model: managed.model,
                                                                         dragSession: session)
            }
        transition.animateExpand(snapshot: PetEdgeSnapshot(image: image, frame: sourceFrame),
            to: target, side: side, in: managed.panel,
            duration: PetEdgeTransition.expandDuration, body: body, liveSnapshot: liveSnapshot) { [weak self, weak managed] in
                guard let self, let managed, self.windows[managed.model.key] === managed,
                      managed.model.animationDragSession == session,
                      managed.expandTransition === transition else { return }
                managed.isExpandTransitioning = false
                managed.expandTransition = nil
            }
    }

    private func moveActiveDrag(_ managed: ManagedPetWindow, to screenPoint: NSPoint) {
        guard managed.isDragging else { return }
        let dx = screenPoint.x - managed.dragStartMouse.x
        let dy = screenPoint.y - managed.dragStartMouse.y
        if abs(dx) >= 0.5 || abs(dy) >= 0.5 { managed.dragMoved = true }
        let origin = NSPoint(x: managed.dragStartOrigin.x + dx,
                             y: managed.dragStartOrigin.y + dy)
        managed.panel.setFrameOrigin(origin)
    }

    private func transitionTarget(for window: NSWindow?) -> ManagedPetWindow? {
        guard let window else { return nil }
        for managed in windows.values {
            if managed.edgeTransition?.interactivePanel === window { return managed }
            if managed.transitionRoutePanel === window { return managed }
        }
        return nil
    }

    /// An interrupted funnel uses the same 5pt drag threshold and click
    /// disambiguation as a body/peek. A mere press is never a new drag.
    private func handleEdgeTransitionEvent(_ managed: ManagedPetWindow, event: NSEvent) {
        let point = event.locationInWindow
        let screenPoint = event.window?.convertPoint(toScreen: point) ?? .zero
        switch event.type {
        case .leftMouseDown:
            managed.transitionRoutePanel = event.window as? NSPanel
            beginClick(managed, clickCount: event.clickCount, at: screenPoint)
        case .leftMouseDragged:
            if managed.isDragging {
                moveActiveDrag(managed, to: screenPoint)
            } else if let down = managed.click.downScreenPoint, dragMoved(from: down, to: screenPoint) {
                let visible = managed.edgeTransition?.visibleCollapseSnapshot()
                cancelClickSequence(managed)
                beginDragFromPeek(managed, at: screenPoint, visibleSnapshot: visible)
                managed.suppressSnapOnEnd = true
            }
        case .leftMouseUp:
            if managed.isDragging {
                moveActiveDrag(managed, to: screenPoint)
                endPetDrag(managed)
            } else {
                finishClick(managed)
                managed.transitionRoutePanel = nil
            }
        default:
            break
        }
    }

    private func target(for window: NSWindow?) -> (ManagedPetWindow, Bool)? {
        guard let window else { return nil }
        for managed in windows.values {
            if managed.panel === window { return (managed, false) }
            if managed.peekPanel === window { return (managed, true) }
        }
        return nil
    }

    // MARK: - Pet click disambiguation

    /// Right-click keeps the existing stats behavior and cancels any pending
    /// left single, so the two button gestures never both produce pet output.
    func handlePetRightClickEvent(_ event: NSEvent) -> Bool {
        guard let (managed, isPeek) = target(for: event.window) else { return false }
        let hitView: NSView?
        if isPeek {
            hitView = managed.peekHost
        } else {
            hitView = managed.model.petBodyView
        }
        guard let view = hitView, view.window === event.window,
              view.bounds.width > 0, view.bounds.height > 0,
              view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return false }
        cancelClickSequence(managed)
        showStatsPopover(of: view, model: managed.model, openingEvent: event)
        return true
    }

    /// Owns the same local mouse sequence in every presentation. It never
    /// consumes events; click business alone is deferred for native clickCount.
    /// Movement has no SwiftUI gesture state or dependency on view lifetime.
    func handlePetClickEvent(_ event: NSEvent) {
        if let managed = transitionTarget(for: event.window) {
            handleEdgeTransitionEvent(managed, event: event)
            return
        }
        guard let (managed, isPeek) = target(for: event.window) else { return }
        let point = event.locationInWindow
        let screenPoint = event.window?.convertPoint(toScreen: point) ?? .zero
        let inPet: Bool
        if isPeek {
            inPet = managed.peekHost.map { host in
                host.window === event.window && host.bounds.width > 0 && host.bounds.height > 0
                    && host.bounds.contains(host.convert(point, from: nil))
            } ?? false
        } else {
            inPet = managed.model.petBodyView.flatMap { petBody -> Bool in
                petBody.window === managed.panel &&
                    petBody.bounds.contains(petBody.convert(point, from: nil))
            } ?? false
        }

        switch event.type {
        case .leftMouseDown:
            guard inPet else {
                cancelClickSequence(managed)
                return
            }
            if isPeek, managed.isEdgeTransitioning {
                managed.edgeTransition?.cancel()
                managed.edgeTransition = nil
                managed.edgeGeneration &+= 1
                managed.isEdgeTransitioning = false
                showPeek(managed)
            }
            managed.dragStartOrigin = managed.panel.frame.origin
            managed.dragStartMouse = screenPoint
            beginClick(managed, clickCount: event.clickCount, at: screenPoint)
        case .leftMouseDragged:
            if managed.isDragging, managed.mouseDragActive {
                moveActiveDrag(managed, to: screenPoint)
                return
            }
            guard let down = managed.click.downScreenPoint else { return }
            if dragMoved(from: down, to: screenPoint) {
                cancelClickSequence(managed)
                if isPeek {
                    beginDragFromPeek(managed, at: screenPoint)
                } else {
                    beginPetDrag(managed)
                    managed.mouseDragActive = true
                }
                moveActiveDrag(managed, to: screenPoint)
            }
        case .leftMouseUp:
            if managed.isDragging {
                if managed.mouseDragActive { moveActiveDrag(managed, to: screenPoint) }
                endPetDrag(managed)
                return
            }
            if isPeek {
                guard let down = managed.click.downScreenPoint else { return }
                if !inPet || dragMoved(from: down, to: screenPoint) {
                    cancelClickSequence(managed)
                    return
                }
                finishClick(managed)
                return
            }
            guard let down = managed.click.downScreenPoint else { return }
            let dragged = !inPet || dragMoved(from: down, to: screenPoint)
            if dragged {
                cancelClickSequence(managed)
                return
            }
            finishClick(managed)
        default:
            break
        }
    }

    /// Keep the existing axis threshold: either axis reaching 5pt starts a
    /// drag. Screen coordinates are deliberate: the window follows
    /// the cursor, so window-relative points barely change during a slow drag.
    private func dragMoved(from down: NSPoint, to current: NSPoint) -> Bool {
        abs(current.x - down.x) >= 5 || abs(current.y - down.y) >= 5
    }

    private func beginClick(_ managed: ManagedPetWindow, clickCount: Int, at screenPoint: NSPoint) {
        switch clickCount {
        case 1:
            // The system says this is a fresh single click, so a previous
            // still-pending single has already completed its window.
            if managed.click.awaitingSingle { flushPendingSingle(managed) }
            managed.click.count = 1
        case 2:
            if managed.click.awaitingSingle {
                // The first click belongs to this double; suppress its single.
                cancelClickSequence(managed)
                managed.click.count = 2
            } else {
                // No same-window first click (e.g. a cross-window click).
                // It cannot toggle this pet; treat it as one ordinary click.
                managed.click.count = 1
            }
        default:
            // clickCount 3/4: part of a longer native sequence; never toggle.
            if managed.click.awaitingSingle { cancelClickSequence(managed) }
            managed.click.count = clickCount
        }
        managed.click.downScreenPoint = screenPoint
    }

    private func finishClick(_ managed: ManagedPetWindow) {
        let count = managed.click.count
        managed.click.count = 0
        managed.click.downScreenPoint = nil
        switch count {
        case 1:
            scheduleSingleClick(managed)
        case 2:
            managed.click.awaitingSingle = false
            managed.pendingSingleClick?.cancel()
            managed.pendingSingleClick = nil
            toggleTaskBubbleClickThrough(forKey: managed.model.key)
        default:
            managed.click.awaitingSingle = false
            managed.pendingSingleClick?.cancel()
            managed.pendingSingleClick = nil
        }
    }

    /// Defers the original pet reaction until the system double-click window
    /// has elapsed. The token is checked again when an already-enqueued
    /// work item runs, so cancellation cannot leak a late pet.
    private func scheduleSingleClick(_ managed: ManagedPetWindow) {
        managed.click.generation &+= 1
        let token = managed.click.generation
        let key = managed.model.key
        managed.click.awaitingSingle = true
        let work = DispatchWorkItem { [weak self, weak managed] in
            MainActor.assumeIsolated {
                guard let self, let managed, self.windows[key] === managed,
                      managed.click.generation == token,
                      managed.click.awaitingSingle else { return }
                managed.click.awaitingSingle = false
                managed.pendingSingleClick = nil
                managed.model.petTap()
            }
        }
        managed.pendingSingleClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// A new system-single click while an older single is still waiting makes
    /// the older click final immediately; it must not be lost.
    private func flushPendingSingle(_ managed: ManagedPetWindow) {
        guard managed.click.awaitingSingle else { return }
        managed.click.generation &+= 1
        managed.pendingSingleClick?.cancel()
        managed.pendingSingleClick = nil
        managed.click.awaitingSingle = false
        managed.model.petTap()
    }

    private func cancelClickSequence(_ managed: ManagedPetWindow) {
        managed.click.generation &+= 1
        managed.pendingSingleClick?.cancel()
        managed.pendingSingleClick = nil
        managed.click.awaitingSingle = false
        managed.click.count = 0
        managed.click.downScreenPoint = nil
    }

    // MARK: - Task bubble click-through

    /// Flips the saved preference and posts one passive Superchat operation result.
    /// The feedback distinguishes a suspended window from a genuinely
    /// pass-through one while leaving the preference itself untouched.
    func toggleTaskBubbleClickThrough(forKey key: String) {
        guard let managed = windows[key] else { return }
        let settings = BubbleSettings.shared
        settings.taskBubbleClickThrough.toggle()
        applyTaskBubbleClickThrough(managed)
        let feedback = TaskBubbleClickThroughPolicy.feedback(
            preferenceEnabled: settings.taskBubbleClickThrough,
            requiresManualHandling: taskBubbleRequiresManualHandling(managed.model)
        )
        switch feedback {
        case .disabled:
            PetController.shared.showClickThroughFeedback(enabled: false, suspended: false)
        case .suspended:
            PetController.shared.showClickThroughFeedback(enabled: true, suspended: true)
        case .enabled:
            PetController.shared.showClickThroughFeedback(enabled: true, suspended: false)
        }
    }

    /// Derives the window's actual pointer behavior from the saved preference
    /// and the rows the shared bubble would draw now. Never writes the
    /// preference, so a manual item appearing/clearing cannot lose the user's
    /// latest choice.
    private func applyTaskBubbleClickThrough(_ managed: ManagedPetWindow, bubbleVisible: Bool? = nil) {
        let visible = bubbleVisible ?? (isVisible && !screensAsleep && !managed.model.isShowingStats
            && !managed.model.messagesTransitionHidden && PetMessagesView.hasContent(managed.model))
        let status = TaskBubbleClickThroughPolicy.status(
            preferenceEnabled: BubbleSettings.shared.taskBubbleClickThrough,
            bubbleVisible: visible,
            requiresManualHandling: taskBubbleRequiresManualHandling(managed.model)
        )
        let wasActive = managed.model.taskBubbleClickThroughStatus == .active
        if managed.model.taskBubbleClickThroughStatus != status {
            managed.model.taskBubbleClickThroughStatus = status
        }
        managed.taskPanel?.ignoresMouseEvents = status == .active
        // Entering pass-through means the bubble can no longer receive the
        // hover-exit that normally collapses it. Clear that one stale hover.
        if status == .active, !wasActive { managed.model.hoverTask(false) }
    }

    private func taskBubbleRequiresManualHandling(_ model: PetWindowModel) -> Bool {
        let groups = BubblePresentation.groups(
            model.sessions,
            settings: BubbleSettings.shared.presentationConfiguration,
            expanded: model.messageListExpanded
        )
        return TaskBubbleClickThroughPolicy.requiresManualHandling(groups)
    }

    /// Test seam for the defensive no-anchor layout path. Normal placement
    /// always supplies an anchor; keeping this separate avoids changing the
    /// production window lifecycle just to exercise the recovery branch.
    func clearTaskBubbleAnchorForTesting(key: String) {
        guard let managed = windows[key] else { return }
        managed.placement.anchor = nil
        layoutSpeech(managed)
    }

    /// Test seams for the edge peek. They use the same production layout and
    /// state transitions, but do not depend on an installed user pet folder.
    var peekAssetOverride: ((String) -> EdgePeekAsset?)?
    var forceStaticSnapshotFailureForTesting = false
    private(set) var lastCollapseSourceFrameForTesting: NSRect?
    private(set) var lastExpansionIdentityForTesting: PetVideoFrameIdentity?
    func preparedSnapshotForTesting(key: String) -> PetEdgeSnapshot? { windows[key]?.preparedSnapshot }

    func enterEdgePeekForTesting(key: String, side: PetEdgeSide,
                                 persist: Bool = false, animated: Bool = false) -> Bool {
        guard let managed = windows[key], let asset = peekAsset(for: managed),
              let anchor = managed.placement.anchor ?? Optional(NSPoint(x: managed.panel.frame.midX,
                                                                        y: managed.panel.frame.minY)),
              let visible = screen(containing: anchor, fallback: managed.panel.frame)?.visibleFrame
        else { return false }
        return enterEdge(managed, side: side, visible: visible, asset: asset,
                         anchorY: anchor.y, animated: animated, persist: persist)
    }

    func isEdgePeekedForTesting(key: String) -> Bool {
        windows[key]?.edge != nil
    }

    func peekPanelForTesting(key: String) -> NSPanel? {
        windows[key]?.peekPanel
    }

    func peekHostForTesting(key: String) -> NSView? {
        windows[key]?.peekHost
    }

    func bodyPanelForTesting(key: String) -> NSPanel? {
        windows[key]?.panel
    }

    func isExpandTransitioningForTesting(key: String) -> Bool {
        windows[key]?.isExpandTransitioning == true
    }

    func expandOverlayPanelForTesting(key: String) -> NSPanel? {
        windows[key]?.expandTransition?.expandPanel
    }

    func edgeTransitionPanelForTesting(key: String) -> NSPanel? {
        windows[key]?.edgeTransition?.interactivePanel
    }

    /// Starts the same interactive collapse overlay with synthetic source art so
    /// event routing can be tested without a live movie decode.
    func startEdgeTransitionForTesting(key: String, duration: TimeInterval = 0.5) -> NSPanel? {
        guard let managed = windows[key], let edge = managed.edge,
              let asset = peekAsset(for: managed) else { return nil }
        managed.edgeGeneration &+= 1
        let generation = managed.edgeGeneration
        let transition = PetEdgeTransition()
        managed.edgeTransition = transition
        managed.isEdgeTransitioning = true
        managed.panel.orderOut(nil)
        managed.peekPanel?.alphaValue = 0
        if isVisible && !screensAsleep { managed.peekPanel?.orderFrontRegardless() }
        transition.animate(snapshot: PetEdgeSnapshot(image: asset.image, frame: edge.frame),
                           to: edge.frame, side: edge.side,
                           collapsing: true, duration: duration,
                           interactive: true, holdAtEnd: true) { [weak self, weak managed] in
            MainActor.assumeIsolated {
                guard let self, let managed, self.windows[managed.model.key] === managed,
                      managed.edgeGeneration == generation, managed.edge != nil,
                      let transition = managed.edgeTransition else { return }
                self.beginPeekCrossfade(managed, transition: transition, generation: generation)
            }
        }
        return transition.interactivePanel
    }

    var isStatsPresentedForTesting: Bool { statsPanel.isPresented }
    var statsFrameForTesting: NSRect? { statsPanel.currentFrame }

    /// After the user drags a pet (window or pet body), re-fit it onto the
    /// pet's screen once the mouse is released. Waiting for release keeps the
    /// pet-body drag math (start origin + mouse delta) consistent mid-drag.
    private func scheduleRelayout(_ managed: ManagedPetWindow) {
        managed.relayoutDebounce?.cancel()
        let key = managed.model.key
        let work = DispatchWorkItem { [weak self, weak managed] in
            guard let self, let managed, self.windows[key] === managed else { return }
            if managed.edge != nil || managed.isEdgeTransitioning { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { self.scheduleRelayout(managed); return }
            self.settleAfterDrag(managed)
        }
        managed.relayoutDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// The screen holding the pet's bottom-center (so a wide window is fitted
    /// to the display the pet is on), else the one holding the window center.
    private func screen(containing anchor: NSPoint, fallback frame: NSRect) -> NSScreen? {
        let p = NSPoint(x: anchor.x, y: anchor.y + 1)
        let screens = NSScreen.screens
        if let hit = screens.first(where: { NSPointInRect(p, $0.frame) }) { return hit }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let hit = screens.first(where: { NSPointInRect(center, $0.frame) }) { return hit }
        // A monitor was unplugged or the pet was dragged beyond every display:
        // prefer the display whose frame is actually nearest, not NSScreen.main.
        let models = screens.map { PetEdgeScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        return PetEdgeGeometry.nearestScreenIndex(for: frame, screens: models).map { screens[$0] }
    }

    /// Keeps every pet visible after a display configuration change: if a pet's
    /// screen vanished (unplugged), move it onto the main screen.
    private func ensureAllOnScreen() {
        for managed in windows.values { ensureOnScreen(managed) }
    }

    private func ensureOnScreen(_ managed: ManagedPetWindow) {
        if let edge = managed.edge, let asset = peekAsset(for: managed) {
            if let anchor = managed.placement.anchor,
               let restored = PetEdgeGeometry.restoration(
                    side: edge.side, anchor: anchor, petSize: CGFloat(PetController.shared.petPoint),
                    screens: edgeScreens()) {
                managed.placement.anchor = restored.anchor
                if enterEdge(managed, side: restored.side, visible: restored.visibleFrame,
                             asset: asset, anchorY: restored.anchor.y, animated: false, persist: false) {
                    savePosition(managed)
                    return
                }
                recoverFromMissingPeek(managed)
                return
            }
            // The saved side became a seam or the display vanished without a
            // usable replacement: show the ordinary pet again, never hide it.
            recoverFromMissingPeek(managed)
            return
        }
        fitAnchorOnScreen(managed)
        resizeInPlace(managed, to: managed.panel.frame.size)
        savePosition(managed)
    }

    private func fitAnchorOnScreen(_ managed: ManagedPetWindow) {
        guard let anchor = managed.placement.anchor,
              let visible = (screen(containing: anchor, fallback: managed.panel.frame) ?? NSScreen.main)?.visibleFrame
        else { return }
        let petSize = PetController.shared.petPoint + 24
        managed.placement.fitAnchor(petSize: CGSize(width: petSize, height: petSize), visible: visible)
    }

    private func applyVisibility(_ visible: Bool) {
        if !visible { statsPanel.dismissImmediately() }
        for managed in windows.values {
            if visible {
                if managed.isEdgeTransitioning {
                    // Leave the transition overlay alone; completion shows peek.
                } else if managed.edge != nil {
                    managed.peekPanel?.orderFrontRegardless()
                    managed.panel.orderOut(nil)
                } else if !managed.isDragging {
                    managed.panel.orderFrontRegardless()
                }
            } else {
                managed.expandTransition?.cancel()
                managed.expandTransition = nil
                managed.isExpandTransitioning = false
                managed.pendingExpansionImage = nil
                managed.pendingExpansionSide = nil
                managed.edgeTransition?.cancel()
                managed.edgeTransition = nil
                managed.edgeGeneration &+= 1
                managed.isEdgeTransitioning = false
                managed.panel.orderOut(nil)
                managed.peekPanel?.orderOut(nil)
                if managed.edge != nil {
                    // The transition was interrupted by hiding; make the next
                    // show deterministic without dropping the saved tuck.
                    managed.peekPanel?.alphaValue = 1
                }
            }
            layoutSpeech(managed)
        }
    }
}
