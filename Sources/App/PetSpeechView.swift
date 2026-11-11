import AppKit
import SwiftUI
import AgentPetCore

/// Separately hosted in a passive panel. Row removal is immediate so a retiring
/// view never occupies a seventh visible slot; surviving rows animate upward.
struct PetSpeechView: View {
    @ObservedObject var model: PetWindowModel
    var measured: (CGSize) -> Void = { _ in }
    @ObservedObject private var settings = BubbleSettings.shared
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var appLang = AppLanguage.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func notice(_ model: PetWindowModel) -> String {
        if let notice = activeNotice(model), notice.kind.isClickThroughFeedback {
            return model.petReactionLine
        }
        return BubbleSettings.shared.superchatEnabled && !model.quotaText.isEmpty ? model.quotaText : model.petReactionLine
    }
    static func activeNotice(_ model: PetWindowModel) -> SystemNotice? {
        guard BubbleSettings.shared.superchatEnabled, !model.quotaText.isEmpty else { return nil }
        return model.noticeSource?.current
    }
    static func hasContent(_ model: PetWindowModel) -> Bool {
        activeNotice(model) != nil || !notice(model).isEmpty || !model.speechRows.isEmpty || !model.idleText.isEmpty
    }
    private var fill: Color {
        switch settings.theme {
        case .light: return .white.opacity(settings.opacity)
        case .dark: return Theme.card.opacity(settings.opacity)
        case .system: return Color(nsColor: .textBackgroundColor).opacity(settings.opacity)
        }
    }
    private func color(_ kind: AgentKind) -> Color {
        switch kind {
        case .codex: return Color(red: 0.27, green: 0.48, blue: 0.91)
        case .opencode: return Color(red: 0.45, green: 0.36, blue: 0.78)
        case .antigravity: return Color(red: 0.12, green: 0.60, blue: 0.67)
        default: return .indigo
        }
    }
    private var width: CGFloat {
        model.speechRows.map { row in
            let label = (row.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: settings.fontSize.primaryPt, weight: .semibold)]).width
            let body = (row.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: settings.fontSize.primaryPt + 1, weight: .medium)]).width
            return min(280, label + body + 42)
        }.max() ?? 280
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            if settings.agentMessagesEnabled {
                if let source = model.noticeSource, let notice = Self.activeNotice(model) {
                    SystemNoticeView(source: source, notice: notice, width: model.noticeWidth)
                }
                if Self.activeNotice(model)?.kind.isPriority != true {
                    ordinaryContent
                }
            }
        }
        .padding(6)
        .fixedSize(horizontal: true, vertical: true)
        .clipped()
        .animation(pet.animationsEnabled && model.isOnScreen && !model.isShowingStats && !reduceMotion ? .easeOut(duration: 0.18) : nil,
                   value: model.speechRows.map(\.id))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SpeechSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(SpeechSizeKey.self, perform: measured)
        .appAppearance()
        .environment(\.locale, appLang.locale)
    }

    @ViewBuilder private var ordinaryContent: some View {
        if !Self.notice(model).isEmpty {
            PetReactionBubble(text: Self.notice(model), readingWidth: true)
                .accessibilityIdentifier("pet-important-or-reaction")
        } else {
            if model.speechRows.isEmpty && !model.idleText.isEmpty {
                PetReactionBubble(text: model.idleText)
                    .accessibilityIdentifier("pet-idle-chatter")
            }
            ForEach(model.speechRows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.label)
                        .font(.system(size: settings.fontSize.primaryPt, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(settings.textOpacity)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(color(row.session.kind)))
                        .fixedSize()
                    Text(row.text)
                        .font(.system(size: settings.fontSize.primaryPt + 1, weight: .medium))
                        .foregroundStyle(.primary)
                        .opacity(settings.textOpacity)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(width: width, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08 * settings.opacity)))
                .shadow(color: .black.opacity(0.15 * settings.opacity), radius: 4, y: 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.label)：\(row.text)")
                .accessibilityIdentifier("pet-message-\(row.id)")
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .identity))
            }
        }
    }
}

private struct SpeechSizeKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Independent placement never writes the persisted pet anchor.
struct PetSpeechPanelGeometry {
    static func frame(anchor: CGPoint, petSize: CGFloat, content: CGSize, visible: CGRect?, important: Bool = false) -> CGRect {
        var width = min(important ? 392 : 292, content.width)
        if let visible { width = min(width, visible.width) }
        var x = anchor.x + petSize / 2 - width
        var y = anchor.y + petSize + 4
        var height = content.height
        if let visible {
            if important, y + height > visible.maxY {
                height = min(height, visible.height)
                y = max(visible.minY, min(anchor.y - height - 4, visible.maxY - height))
            }
            x = max(visible.minX, min(x, visible.maxX - width))
            height = min(height, max(0, visible.maxY - y))
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Natural task content. AppKit owns the scroll viewport independently, so a
/// previously measured width/height cannot constrain the next measurement.
struct PetTaskPanelView: View {
    @ObservedObject var model: PetWindowModel
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var appLang = AppLanguage.shared
    var measured: (CGSize) -> Void
    var body: some View {
        PetMessagesView(model: model, expanded: model.messageListExpanded)
            .fixedSize(horizontal: true, vertical: true)
            .background(PetMessageHitRegion(model: model))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SpeechSizeKey.self, value: proxy.size)
            })
            .onPreferenceChange(SpeechSizeKey.self, perform: measured)
            .onHover { model.hoverTask($0) }
            .onDisappear { model.hoverTask(false) }
            .appAppearance()
            .environment(\.locale, appLang.locale)
            .environment(\.animationsEnabled, pet.animationsEnabled && model.isOnScreen)
    }
}
