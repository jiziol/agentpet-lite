import SwiftUI
import AppKit
import AgentPetCore

/// Layout width of the pet's speech bubble (widest one while two cross-fade).
private struct BubbleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Shared live/snapshot content keeps incoming messages current during status.
struct PetMessagesView: View {
    @ObservedObject var model: PetWindowModel
    var expanded = false
    var interactionOverride: BubbleInteraction? = nil
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var bubbleSettings = BubbleSettings.shared

    static func hasContent(_ model: PetWindowModel) -> Bool {
        model.petID != nil && !BubblePresentation.visible(model.sessions,
            settings: BubbleSettings.shared.presentationConfiguration).isEmpty
    }

    var body: some View {
        VStack(spacing: 2) {
            if model.petID != nil {
                // Gate on the sessions the bubble will actually show: if the
                // state/kind filters hide all of them, drawing AgentBubble
                // would leave an empty (off-centre, contentless) bubble.
                if bubbleSettings.structuredTasksEnabled
                    && !AgentBubble.visible(model.sessions, settings: bubbleSettings).isEmpty {
                    alignedToPet(AgentBubble(sessions: model.sessions, expanded: expanded,
                                            usesExternalScrollViewport: true,
                                            interactionOverride: interactionOverride))
                }
            }

        }
        .fixedSize(horizontal: true, vertical: true)
        .onPreferenceChange(BubbleWidthKey.self) { bubbleWidth = $0 }
    }

    // Layout width of the bubble incl. padding (unaffected by offset/scale, so
    // no feedback loop with the shifts below).
    @State private var bubbleWidth: CGFloat = 0

    /// Horizontal padding around the pet's bubble.
    private static let bubblePadding = TaskBubbleStyle.effectInset
    /// Min distance from the tail to the bubble's edge (corner radius + half tail).
    private static let tailClearance: CGFloat = 20

    private func alignedToPet<B: View>(_ bubble: B) -> some View {
        let layout = PetWindowGeometry.bubbleLayout(
            petOffset: model.taskPetOffset, windowWidth: model.taskWindowWidth, bubbleWidth: bubbleWidth,
            bubbleInset: Self.bubblePadding, tailClearance: Self.tailClearance)
        return bubble
            .padding(.horizontal, Self.bubblePadding).padding(.vertical, TaskBubbleStyle.effectInset)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: BubbleWidthKey.self, value: proxy.size.width)
            })
            .environment(\.bubbleTailOffset, layout.tailShift)
            .offset(x: layout.bubbleShift)
            .animation(nil, value: layout.bubbleShift)
            .transition(AnyTransition.scale(scale: 0.6).combined(with: .opacity))
    }

}

/// Tap reactions reserve their full text and shadow space in the speech panel.
struct PetReactionBubble: View {
    let text: String
    var readingWidth = false
    @ObservedObject private var settings = BubbleSettings.shared
    private var wraps: Bool {
        readingWidth || text.contains("\n") || (text as NSString).size(withAttributes:
            [.font: NSFont.systemFont(ofSize: settings.fontSize.primaryPt + 1, weight: .medium)]).width > 260
    }

    private var fill: Color {
        switch settings.theme {
        case .light: return Color.white.opacity(settings.opacity)
        case .dark: return Theme.card.opacity(settings.opacity)
        case .system: return Color(nsColor: .textBackgroundColor).opacity(settings.opacity)
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: settings.fontSize.primaryPt + 1, weight: .medium))
            .lineLimit(2)
            .foregroundStyle(.primary.opacity(0.85))
            .opacity(settings.textOpacity)
            // Propose the reading width before measuring multiline height.
            // A capsule is unsuitable for paragraphs: its curved top/bottom
            // leave rectangular text corners outside the background.
            .frame(width: wraps ? 260 : nil, alignment: .leading)
            .fixedSize(horizontal: !wraps, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // Plain alpha fill: material would still blur the content behind it.
            .background(RoundedRectangle(cornerRadius: 12).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08 * settings.opacity), lineWidth: 1))
            .shadow(color: .black.opacity(0.15 * settings.opacity), radius: 4, y: 2)
            .fixedSize(horizontal: true, vertical: true)
    }
}
