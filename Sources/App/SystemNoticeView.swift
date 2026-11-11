import AppKit
import SwiftUI

struct SystemNoticeView: View {
    @ObservedObject var source: SystemNoticeCenter
    let notice: SystemNotice
    var width: CGFloat = 380
    @ObservedObject private var settings = BubbleSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var pet = PetController.shared


    // `width` is the available width, not a fixed card width. Select the
    // existing compact typography from that constraint, never from the
    // measured result (which would cause width/text oscillation).
    private var compact: Bool { width < 320 }
    private var pointSize: CGFloat { settings.fontSize.primaryPt + (compact ? 0 : 2) }
    private var spacing: CGFloat { compact ? 9 : 14 }
    private var showsIcon: Bool { !notice.kind.isClickThroughFeedback }
    private var title: String { compact ? notice.shortTitle : notice.title }
    private var message: String { compact ? (notice.shortBody ?? notice.body) : notice.body }
    private var contentWidth: CGFloat {
        // Measure the exact SwiftUI text run: AppKit's NSString font fallback
        // can differ for CJK/localized glyphs and wrap a supposedly fitted line.
        let textWidth = NSHostingView(rootView: noticeText.fixedSize()).fittingSize.width
        let controls: CGFloat = 38 + (showsIcon ? 22 + spacing : 0) + (notice.requiresAcknowledgment ? 22 + spacing : 0)
        return min(max(1, width), max(100, ceil(textWidth + controls + 2)))
    }

    private var noticeText: some View {
        (Text(title).fontWeight(.semibold) + Text(message))
            .font(.system(size: pointSize))
    }

    private var accent: Color {
        let rgb = notice.accentRGB
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
    private var dark: Bool { settings.theme == .dark || (settings.theme == .system && colorScheme == .dark) }
    private var base: Color { dark ? Color(red: 0.15, green: 0.14, blue: 0.17) : .white }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: spacing) {
                if showsIcon {
                    icon.frame(width: 22, height: 22)
                }
                noticeText
                    .foregroundStyle(dark ? Color.white : Color(red: 0.22, green: 0.19, blue: 0.23))
                    .opacity(settings.textOpacity)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if notice.requiresAcknowledgment {
                    Button { source.confirmPomodoro(id: notice.id) } label: {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent).frame(width: 22, height: 22)
                            .background(Circle().fill(accent.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .help(LocalizedStringKey(notice.confirmationLabel ?? "Got it"))
                    .accessibilityLabel(LocalizedStringKey(notice.confirmationLabel ?? "Got it"))
                    .accessibilityIdentifier("pomodoro-notice-confirm")
                }
            }
            .frame(minHeight: 22)
            .padding(.vertical, 14).padding(.leading, 18).padding(.trailing, 20)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    accent.opacity(0.18)
                    accent.frame(width: proxy.size.width * source.fractionRemaining)
                }
            }.frame(height: 3)
        }
        .frame(width: contentWidth)
        .background { ZStack { base; accent.opacity(dark ? 0.18 : 0.12) }.opacity(settings.opacity) }
        .overlay(alignment: .leading) { accent.frame(width: 5) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.10 * settings.opacity), radius: 8, y: 3)
        .opacity(notice.requiresAcknowledgment || reduceMotion || !pet.animationsEnabled ? 1 : min(1, source.fractionRemaining * 40))
        .animation(reduceMotion || !pet.animationsEnabled ? nil : .linear(duration: 0.1), value: source.fractionRemaining)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.title + notice.body)
        .accessibilityIdentifier("pet-system-notice")
    }
    @ViewBuilder private var icon: some View {
        if notice.kind == .lowQuota {
            ZStack { Circle().fill(accent); Text("!").font(.system(size: 17, weight: .bold)).foregroundStyle(.white) }
        } else {
            Image(systemName: iconName)
                .resizable().scaledToFit().foregroundStyle(accent)
        }
    }

    private var iconName: String {
        switch notice.kind {
        case .pomodoro: return "clock"
        case .clickThroughOn: return "cursorarrow"
        case .clickThroughOff: return "minus.circle"
        case .clickThroughPaused: return "pause.circle"
        default: return "checkmark.circle"
        }
    }
}

/// The native clip rectangle tells the countdown whether the Status banner is
/// actually visible, including scrolling and the existing Genie transition.
final class SystemNoticeMarkerView: NSView {
    var noticeID = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
struct SystemNoticeMarker: NSViewRepresentable {
    let model: PetWindowModel?
    let id: String
    func makeNSView(context: Context) -> SystemNoticeMarkerView {
        let view = SystemNoticeMarkerView(); view.noticeID = id
        model?.statusNoticeMarker = view; return view
    }
    func updateNSView(_ view: SystemNoticeMarkerView, context: Context) {
        view.noticeID = id; model?.statusNoticeMarker = view
    }
}
