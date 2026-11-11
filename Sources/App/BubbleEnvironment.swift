import SwiftUI
import AppKit
import AgentPetCore

// MARK: - Animations environment key

private struct AnimationsEnabledKey: EnvironmentKey { static let defaultValue = true }
private struct PetOnScreenKey: EnvironmentKey { static let defaultValue = true }
private struct BubbleTailOffsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var animationsEnabled: Bool {
        get { self[AnimationsEnabledKey.self] }
        set { self[AnimationsEnabledKey.self] = newValue }
    }
    /// False while the pet window can't be seen (occluded, displays asleep).
    /// Pauses non-visual timers such as the carousel rotation.
    var petOnScreen: Bool {
        get { self[PetOnScreenKey.self] }
        set { self[PetOnScreenKey.self] = newValue }
    }
    /// Horizontal shift of a pet bubble's bottom tail so it points at the pet
    /// when the pet is offset inside its window.
    var bubbleTailOffset: CGFloat {
        get { self[BubbleTailOffsetKey.self] }
        set { self[BubbleTailOffsetKey.self] = newValue }
    }
}

/// Injected at the live bubble boundary; snapshot/preview consumers can be inert.
struct BubbleInteraction: Sendable {
    var navigationMessages: [String: String] = [:]
    var focus: @MainActor @Sendable (String) -> Void = { _ in }
    var focusAOProject: @MainActor @Sendable (String) -> Void = { _ in }
    var acknowledgeAO: @MainActor @Sendable (AOAttentionReceipt) -> Void = { _ in }
    var resolve: @MainActor @Sendable (String, String, ApprovalDecision) -> Void = { _, _, _ in }
    var clearEnded: @MainActor @Sendable (Set<String>) -> Void = { _ in }
}
private struct BubbleInteractionKey: EnvironmentKey { static let defaultValue = BubbleInteraction() }
extension EnvironmentValues {
    var bubbleInteraction: BubbleInteraction {
        get { self[BubbleInteractionKey.self] }
        set { self[BubbleInteractionKey.self] = newValue }
    }
}
