import AppKit
import QuartzCore
import OSLog
import AgentPetCore

/// Fixed live card; the shared Genie renderer serializes message/status swaps.
@MainActor
final class PetStatsPanelController {
    enum Phase { case hidden, hidingMessages, openingStatus, shown, closingStatus, openingMessages }
    private final class Panel: NSPanel {
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }
    private var panel: Panel?
    private var petBody: (() -> NSView?)?
    private var onClose: (() -> Void)?
    private var visibilityChanged: ((Bool) -> Void)?
    private var restoreMessages: ((@escaping (PetBubbleSnapshot?) -> Void) -> Void)?
    private var animated = true
    private var wantsKey = false
    private var openingEvent: NSEvent?
    private static let logger = Logger(subsystem: AgentPetPaths.bundleIdentifier, category: "bubble-transition")
    private var localClick: Any?
    private var globalClick: Any?
    private var menuObserver: Any?
    private var deactivationObserver: Any?
    private let genie = PetGenieTransition()
    private let statusDuration: TimeInterval
    private let messageDuration: TimeInterval
    init(statusDuration: TimeInterval = 0.50, messageDuration: TimeInterval = 0.30) {
        self.statusDuration = statusDuration
        self.messageDuration = messageDuration
    }
    private var generation = UUID()
    private(set) var phase = Phase.hidden {
        didSet {
            visibilityChanged?(phase == .shown)
            #if AGENTPET_LOCAL
            Self.logger.notice("phase \(String(describing: self.phase), privacy: .public)")
            #endif
        }
    }
    var isShown: Bool { panel?.isVisible == true }
    var isPresented: Bool { phase != .hidden }
    var currentFrame: NSRect? { panel?.frame }
    static func frame(anchor: NSRect, contentSize: NSSize, visible: NSRect) -> NSRect {
        let margin = min(CGFloat(8), min(visible.width, visible.height) / 4)
        let area = visible.insetBy(dx: margin, dy: margin)
        let size = NSSize(width: min(contentSize.width, area.width),
                          height: min(contentSize.height, area.height))
        let above = anchor.maxY + 8
        let below = anchor.minY - 8 - size.height
        let preferredY = above + size.height <= area.maxY ? above : below
        return NSRect(x: min(max(anchor.midX - size.width / 2, area.minX), area.maxX - size.width),
                      y: min(max(preferredY, area.minY), area.maxY - size.height),
                      width: size.width, height: size.height)
    }

    // Kept for the established geometry/rendering regression fixtures.
    static func genieStrips(card: NSRect, pet: NSRect?, progress: CGFloat, count: Int = 256) -> [NSRect] {
        PetGenieTransition.genieStrips(card: card, pet: pet, progress: progress, count: count)
    }
    static func snapshotLayers(image: CGImage, cardSize: NSSize, frames: [NSRect], origin: NSPoint) -> [CALayer] {
        PetGenieTransition.snapshotLayers(image: image, cardSize: cardSize, frames: frames, origin: origin)
    }

    func show(content: NSView, frame: NSRect, petBody: @escaping () -> NSView?, animated: Bool = true,
              openingEvent: NSEvent? = nil, messages: PetBubbleSnapshot? = nil, hideMessages: () -> Void = {},
              restoreMessages: ((@escaping (PetBubbleSnapshot?) -> Void) -> Void)? = nil,
              visibilityChanged: @escaping (Bool) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        dismissImmediately()
        let panel = Panel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel
        self.petBody = petBody
        self.onClose = onClose
        self.visibilityChanged = visibilityChanged
        self.restoreMessages = restoreMessages
        self.animated = animated
        self.openingEvent = openingEvent
        installDismissalMonitors()
        let target = petFrame()
        hideMessages()
        if animated, let messages {
            phase = .hidingMessages
            let generation = self.generation
            genie.animate(messages, pet: target, opening: false, duration: messageDuration) { [weak self] in
                guard let self, self.generation == generation else { return }
                self.openStatus()
            }
        } else {
            openStatus()
        }
    }

    private func openStatus() {
        guard let panel else { return }
        phase = .openingStatus
        panel.orderFront(nil)
        if wantsKey { panel.makeKey() }
        if animated, let view = panel.contentView,
           let snapshot = PetBubbleSnapshot.capture(view: view, rect: view.bounds, frame: panel.frame) {
            panel.alphaValue = 0
            let generation = self.generation
            genie.animate(snapshot, pet: petFrame(), opening: true, duration: statusDuration) { [weak self, weak panel] in
                guard let self, self.generation == generation else { return }
                panel?.alphaValue = 1
                self.phase = .shown
            }
        } else {
            panel.alphaValue = 1
            phase = .shown
        }
    }

    private func installDismissalMonitors() {
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.consumeOpeningEvent(event) { return }
                if !self.contains(window: event.window) && !Self.isPetClick(event, petBody: self.petBody?()) {
                    #if AGENTPET_LOCAL
                    Self.logger.notice("dismiss local mouse")
                    #endif
                    self.close()
                }
            }
            return event
        }
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.consumeOpeningEvent(event) else { return }
                #if AGENTPET_LOCAL
                Self.logger.notice("dismiss global mouse")
                #endif
                self.close()
            }
        }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApplication.shared, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // An outside click can start closing before app deactivation.
                // Let that snapshot animation and message restoration finish.
                switch self.phase {
                case .closingStatus, .openingMessages, .hidden: break
                case .shown, .hidingMessages, .openingStatus:
                    // AppKit can hide the live panel without a closing click.
                    self.dismissImmediately()
                }
            }
        }
    }

    /// SwiftUI popovers have their own AppKit window. Mouse-down in an owned
    /// child must reach its controls before any outside-click dismissal.
    private func contains(window: NSWindow?) -> Bool {
        var current = window
        while let window = current {
            if window === panel { return true }
            current = window.parent
        }
        return false
    }

    /// Layout changes can move the pet region while AppKit is still delivering
    /// the initiating click. That same click cannot also dismiss the new card.
    private func consumeOpeningEvent(_ event: NSEvent) -> Bool {
        guard let openingEvent else { return false }
        self.openingEvent = nil
        return Self.isSameMouseEvent(event, openingEvent)
    }
    static func isSameMouseEvent(_ a: NSEvent, _ b: NSEvent) -> Bool {
        a.type == b.type && a.eventNumber == b.eventNumber && a.timestamp == b.timestamp
    }

    private func removeDismissalMonitors() {
        if let localClick { NSEvent.removeMonitor(localClick); self.localClick = nil }
        if let globalClick { NSEvent.removeMonitor(globalClick); self.globalClick = nil }
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver); self.menuObserver = nil }
    }

    func makeKey() { wantsKey = true; if isShown { panel?.makeKey() } }
    func resize(frame: NSRect) {
        guard phase == .shown else { return }
        panel?.setFrame(frame, display: true, animate: false)
    }
    static func isPetClick(_ event: NSEvent, petBody: NSView?) -> Bool {
        guard let petBody, let window = petBody.window, event.window === window else { return false }
        return petBody.bounds.contains(petBody.convert(event.locationInWindow, from: nil))
    }
    private func petFrame() -> NSRect? {
        guard let body = petBody?(), let window = body.window else { return nil }
        return window.convertToScreen(body.convert(body.bounds, to: nil))
    }

    func close() {
        guard isPresented, phase != .closingStatus, phase != .openingMessages else { return }
        generation = UUID()
        genie.cancel()
        removeDismissalMonitors()
        let snapshot: PetBubbleSnapshot?
        if let panel, panel.isVisible, let view = panel.contentView {
            snapshot = PetBubbleSnapshot.capture(view: view, rect: view.bounds, frame: panel.frame)
        } else { snapshot = nil }
        panel?.onCancel = nil
        panel?.orderOut(nil)
        phase = .closingStatus
        let generation = self.generation
        if animated, let snapshot {
            genie.animate(snapshot, pet: petFrame(), opening: false, duration: statusDuration) { [weak self] in
                guard let self, self.generation == generation else { return }
                self.openMessages()
            }
        } else {
            openMessages()
        }
    }

    private func openMessages() {
        phase = .openingMessages
        let generation = self.generation
        guard let restoreMessages else { finish(); return }
        restoreMessages { [weak self] snapshot in
            guard let self, self.generation == generation else { return }
            if self.animated, let snapshot {
                self.genie.animate(snapshot, pet: self.petFrame(), opening: true, duration: self.messageDuration) { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.finish()
                }
            } else { self.finish() }
        }
    }

    private func finish() {
        // Observe until completion; closing/restoration retain their own cleanup.
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        petBody = nil
        restoreMessages = nil
        wantsKey = false
        openingEvent = nil
        phase = .hidden
        visibilityChanged = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    func dismissImmediately() {
        generation = UUID()
        genie.cancel()
        removeDismissalMonitors()
        panel?.onCancel = nil
        finish()
    }
}
