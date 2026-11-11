import SwiftUI
import AppKit
import AgentPetCore

/// Timing for `AnimatedStatusText`'s erase/retype/ellipsis-cycle phases.
private let ERASE_INTERVAL: TimeInterval = 0.080
private let TYPE_INTERVAL: TimeInterval = 0.045
private let DOT_CYCLE_INTERVAL: TimeInterval = 0.400
/// A message that replaces one shown for less than this is swapped in
/// instantly instead of erase/retyped. Busy agents change the activity line
/// every second or two, and each typed character is a full SwiftUI re-render
/// of the bubble, so animating every change kept the app (and WindowServer)
/// busy continuously. The typewriter still plays for "calm" transitions.
private let SNAP_WINDOW: TimeInterval = 3.0
// MARK: - Animated status text

/// Renders a status message that erases-then-retypes on change, then settles
/// into either an ellipsis cycle (`Brewing…`) or a shimmer sweep (plain text).
///
/// Erase: drop the trailing word every `ERASE_INTERVAL` until empty.
/// Type: append one char of the new message every `TYPE_INTERVAL`.
/// Stable: ellipsis-suffixed messages cycle `.`/`..`/`...`; others shimmer.
struct AnimatedStatusText: View {
    let message: String
    let font: Font
    let color: Color
    /// When false, render the message plainly with no erase/retype, ellipsis
    /// cycle, or shimmer — used for terminal states like "Shipped!" where the
    /// dot alone should carry the motion.
    var animated: Bool = true

    private static let ellipsisFrames = [".", "..", "..."]

    @State private var displayed = ""
    /// Widest of the outgoing/incoming text — reserved (invisibly) so the
    /// erase/retype animation never shrinks or grows the bubble mid-flight.
    @State private var reserveText = ""
    @State private var baseText = ""
    @State private var hasEllipsis = false
    @State private var isStable = false
    @State private var dotFrame = 0

    @State private var typeTarget: [Character] = []
    @State private var typeIndex = 0
    @State private var lastRestart = Date.distantPast

    @State private var generation = InteractionGeneration()
    @State private var eraseTimer: Timer?
    @State private var typeTimer: Timer?
    @State private var dotTimer: Timer?

    var body: some View {
        if !animated {
            Text(message)
                .font(font)
                .foregroundStyle(color)
        } else {
            animatedBody
        }
    }

    private var animatedBody: some View {
        ZStack(alignment: .leading) {
            if !isStable {
                // Reserved-width ghost: holds the bubble at the wider of the
                // outgoing/incoming text for the whole erase→type transition.
                Text(reserveText).font(font).opacity(0)
            }
            content
        }
        // Appear shows the message at once: in carousel mode every rotation
        // (every few seconds) re-creates the row, and retyping it each time
        // was a steady stream of per-character re-renders. The typewriter is
        // kept for actual message changes.
        .onAppear { snap(to: message) }
        .onChange(of: message) { restart(to: $0) }
        .onDisappear { cancelAll() }
    }

    @ViewBuilder
    private var content: some View {
        if isStable && hasEllipsis {
            ZStack(alignment: .leading) {
                // Reserves width for the longest frame ("...") so the
                // cycling suffix never resizes the bubble.
                Text(baseText + "...").font(font).opacity(0)
                Text(baseText + Self.ellipsisFrames[dotFrame])
                    .font(font)
                    .foregroundStyle(color)
            }
        } else if isStable {
            Text(displayed).font(font).foregroundStyle(color)
        } else {
            Text(displayed)
                .font(font)
                .foregroundStyle(color)
        }
    }

    // MARK: Phase transitions

    private func restart(to newMessage: String) {
        let now = Date()
        let rapid = now.timeIntervalSince(lastRestart) < SNAP_WINDOW
        lastRestart = now
        if rapid && !displayed.isEmpty {
            snap(to: newMessage)
            return
        }
        reserveText = newMessage.count >= displayed.count ? newMessage : displayed
        cancelAll()
        isStable = false
        if displayed.isEmpty {
            startTyping(newMessage)
        } else {
            startErasing(to: newMessage)
        }
    }

    /// Shows `newMessage` immediately in its stable phase (no erase/retype).
    private func snap(to newMessage: String) {
        cancelAll()
        setTarget(newMessage)
        typeIndex = typeTarget.count
        displayed = String(typeTarget)
        enterStablePhase()
    }

    /// Splits off the trailing ellipsis and sets what the typewriter will type.
    private func setTarget(_ newMessage: String) {
        let stripped = Self.stripEllipsis(newMessage)
        baseText = stripped.text
        hasEllipsis = stripped.hasEllipsis
        typeTarget = Array(hasEllipsis ? stripped.text : newMessage)
    }

    private func startErasing(to newMessage: String) {
        let token = generation.renew()
        eraseTimer = Timer.scheduledTimer(withTimeInterval: ERASE_INTERVAL, repeats: true) { _ in
            Task { @MainActor in
                guard generation.accepts(token) else { return }
                eraseStep(to: newMessage)
            }
        }
    }

    private func eraseStep(to newMessage: String) {
        var words = displayed.split(separator: " ", omittingEmptySubsequences: false)
        words.removeLast()
        displayed = words.joined(separator: " ")
        if displayed.isEmpty {
            eraseTimer?.invalidate()
            eraseTimer = nil
            startTyping(newMessage)
        }
    }

    private func startTyping(_ newMessage: String) {
        setTarget(newMessage)
        typeIndex = 0
        displayed = ""
        let token = generation.renew()
        typeTimer = Timer.scheduledTimer(withTimeInterval: TYPE_INTERVAL, repeats: true) { _ in
            Task { @MainActor in
                guard generation.accepts(token) else { return }
                typeStep()
            }
        }
    }

    private func typeStep() {
        guard typeIndex < typeTarget.count else {
            typeTimer?.invalidate()
            typeTimer = nil
            enterStablePhase()
            return
        }
        displayed.append(typeTarget[typeIndex])
        typeIndex += 1
    }

    private func enterStablePhase() {
        let token = generation.renew()
        isStable = true
        guard hasEllipsis else { return }
        dotFrame = 0
        dotTimer = Timer.scheduledTimer(withTimeInterval: DOT_CYCLE_INTERVAL, repeats: true) { _ in
            Task { @MainActor in
                guard generation.accepts(token) else { return }
                dotFrame = (dotFrame + 1) % Self.ellipsisFrames.count
            }
        }
    }

    private func cancelAll() {
        generation.renew()
        eraseTimer?.invalidate(); eraseTimer = nil
        typeTimer?.invalidate(); typeTimer = nil
        dotTimer?.invalidate(); dotTimer = nil
    }

    private static func stripEllipsis(_ text: String) -> (text: String, hasEllipsis: Bool) {
        if text.hasSuffix("…") {
            return (String(text.dropLast()).trimmingCharacters(in: .whitespaces), true)
        }
        if text.hasSuffix("...") {
            return (String(text.dropLast(3)).trimmingCharacters(in: .whitespaces), true)
        }
        return (text, false)
    }
}


