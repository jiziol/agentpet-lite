import AppKit
import SwiftUI
import AgentPetCore

private struct PetDragPresentation: Hashable {
    let session: UInt64
    let dragging: Bool
}

/// The pet sprite alone (imported pack, reacting to mood). Shows a paw
/// placeholder if no pet is selected yet. The pet id and mood come from the
/// per-window model rather than the global `PetController`.
struct PetView: View {
    @ObservedObject var model: PetWindowModel
    var size: CGFloat = 120
    @ObservedObject private var imagePets = ImagePetStore.shared
    @ObservedObject private var pet = PetController.shared
    @StateObject private var animationPlayback = PetAnimationViewState()

    var body: some View {
        content
            .frame(height: size)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        if let id = model.petID, let pack = imagePets.pack(id: id) {
            PetAnimatedView(pack: pack, mood: model.mood, size: size,
                            dragging: model.isAnimationDragging, dragSession: model.animationDragSession,
                            tapRevision: model.petTapCount,
                            context: model.animationContext, state: animationPlayback)
                // Build each drag from its own frame-zero playback state, then
                // build mouse-up from the latest task context. This also fences
                // SwiftUI callbacks retained by the hidden pre-drag hierarchy.
                .id(PetDragPresentation(session: model.animationDragSession,
                                        dragging: model.isAnimationDragging))
        } else {
            Image(systemName: "pawprint.fill")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.secondary)
        }
    }
}

/// Reports the natural size of the body panel.
private struct PetContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

/// The floating body panel. Task and speech content live in companion panels.
/// Per-window fields (mood/petID/sessions/chatLine) come from `model`; global
/// appearance/animation flags still come from `PetController.shared`.
struct PetWindowInteraction {
    var resize: (CGSize) -> Void = { _ in }
    var dragBegan: () -> Void = {}
    var dragEnded: () -> Void = {}
}

struct FloatingPetView: View {
    @ObservedObject var model: PetWindowModel
    var windowInteraction = PetWindowInteraction()
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var bubbleSettings = BubbleSettings.shared
    @ObservedObject private var appLang = AppLanguage.shared

    var body: some View {
        VStack(spacing: 2) {
            PetView(model: model, size: pet.petPoint)
                .background(PetBodyHitRegion(model: model))
                .overlay(alignment: .bottomTrailing) {
                    TaskBubbleClickThroughBadge(status: model.taskBubbleClickThroughStatus)
                        .padding(4)
                }
                .overlay {
                    if model.petTapCount > 0 {
                        PetHearts(size: pet.petPoint)
                            .id(model.petTapCount)
                    }
                }
                .scaleEffect(
                    x: model.isPetted ? 1.12 : 1.0,
                    y: model.isPetted ? 0.82 : 1.0,
                    anchor: .bottom
                )
                .animation(.interpolatingSpring(stiffness: 300, damping: 8), value: model.isPetted)
                // Mouse sequences are owned by the controller's local monitor.
                // A playback/view rebuild must not replace the active drag.
                // Kept under its on-screen spot when the window is pushed back
                // onto the screen (offset doesn't change the measured size).
                .offset(x: model.petOffset)
                // The window jumps instantly, so the counter-shift must too:
                // animating it (outer spring on sessions.count) slid the pet
                // out of the window for a few frames.
                .animation(nil, value: model.petOffset)
        }
        .onHover { model.hoverBody($0) }
        .onDisappear { model.hoverBody(false) }
        .fixedSize(horizontal: true, vertical: true)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.petReactionLine)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PetContentSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(PetContentSizeKey.self) { size in
            windowInteraction.resize(size)
        }
        .animation(.easeInOut(duration: 0.22), value: model.chatLine)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.sessions.count)
        .animation(.easeInOut, value: pet.showChat)
        .animation(nil, value: model.isShowingStats)
        .animation(nil, value: model.messagesTransitionHidden)
        // Re-resolve bubble text when the app language changes at runtime.
        .environment(\.locale, appLang.locale)
        // An unseen pet runs no animation at all (sprite, dot, typewriter,
        // pulse, elapsed tick); it resumes as soon as the window is visible.
        .environment(\.animationsEnabled, pet.animationsEnabled && model.isOnScreen)
        .environment(\.petOnScreen, model.isOnScreen)
    }

}
