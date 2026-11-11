import AppKit
import SwiftUI

/// The task bubble's effective pointer behavior. The saved preference is
/// separate: a displayed approval/waiting/failure row temporarily restores
/// interaction without mutating that preference.
enum TaskBubbleClickThroughStatus: Equatable {
    case off
    case active
    case suspended

    var accessibilityLabel: String {
        switch self {
        case .off:
            return ""
        case .active:
            return NSLocalizedString("Task bubble click-through is on", comment: "click-through badge")
        case .suspended:
            return NSLocalizedString("Task bubble click-through is on but paused while a task needs attention",
                                     comment: "click-through badge")
        }
    }
}

enum TaskBubbleClickThroughPolicy {
    enum Feedback: Equatable { case enabled, disabled, suspended }

    /// `.off` also covers "preference on, but no task bubble is visible"; there
    /// is no window to pass clicks through in that state.
    static func status(preferenceEnabled: Bool, bubbleVisible: Bool,
                       requiresManualHandling: Bool) -> TaskBubbleClickThroughStatus {
        guard preferenceEnabled else { return .off }
        guard bubbleVisible else { return .off }
        return requiresManualHandling ? .suspended : .active
    }

    /// Feedback follows the saved preference and the currently displayed
    /// manual item; it deliberately does not claim pass-through when the
    /// window is still interactive.
    static func feedback(preferenceEnabled: Bool, requiresManualHandling: Bool) -> Feedback {
        guard preferenceEnabled else { return .disabled }
        return requiresManualHandling ? .suspended : .enabled
    }

    /// Uses the same grouped rows the bubble draws, so an item hidden by the
    /// display cap cannot keep an invisible window interactive.
    static func requiresManualHandling(_ groups: [GroupedSession]) -> Bool {
        groups.contains { group in
            BubblePresentation.Row(session: group.session, team: group.team).requiresManualHandling
        }
    }
}

/// A small, pointer-transparent mark on the pet showing the task bubble's
/// effective state (not just the saved preference).
struct TaskBubbleClickThroughBadge: View {
    let status: TaskBubbleClickThroughStatus

    @ViewBuilder
    var body: some View {
        if status != .off {
            Image(systemName: status == .active ? "cursorarrow" : "hand.raised.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(status == .active ? Color.white : Color.orange)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.black.opacity(0.58)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(status.accessibilityLabel))
                .allowsHitTesting(false)
        }
    }
}
