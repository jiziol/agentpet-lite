import SwiftUI
import AgentPetCore

/// The approved Demo 2 + 4 surface. Task contrast is independent of the app
/// theme, while the existing background and text sliders keep separate roles.
enum TaskBubbleStyle {
    static let ink = Color(red: 0.035, green: 0.05, blue: 0.09)
    static let fill = Color(red: 0.047, green: 0.067, blue: 0.114)
    static let foreground = Color(red: 0.973, green: 0.98, blue: 0.988)
    static let secondary = Color(red: 0.81, green: 0.86, blue: 0.93)
    static let waiting = Color(red: 1, green: 0.78, blue: 0.36)
    static let effectInset: CGFloat = 24

    static func shadowWeight(_ backgroundOpacity: Double) -> Double {
        max(0.3, 1 - backgroundOpacity * 0.7)
    }

    /// Ink shadow intensity relative to the glyph's own opacity. The glyph fades
    /// linearly with the text slider while the neutral halo fades faster
    /// (`t^1.6`), so low values read as a clean fade instead of a dominant
    /// blur. The exponent and the radius narrowing below were selected by curve
    /// probes on the transparent layer (t^1.35, t^1.6, t^2.0; numbers and logs
    /// in the private evidence `text-opacity-shadow-20261019`): t^1.35 left
    /// roughly twice the low-opacity ink, t^2.0 erased the faint grounding ink
    /// entirely. The 54-combination composited matrix is separate visual/validity
    /// evidence and did not choose the curve.
    static func shadowFade(_ textOpacity: Double) -> Double {
        pow(min(max(textOpacity, 0), 1), 1.6)
    }

    /// Slightly narrower ink radii at low text opacity, keeping whatever ink
    /// remains close to the glyphs. Exactly 1 at full opacity, so the 100%
    /// appearance is unchanged.
    static func shadowRadiusScale(_ textOpacity: Double) -> Double {
        0.7 + 0.3 * min(max(textOpacity, 0), 1)
    }

    /// Colors identify the Agent, independently of the task's status lamp.
    static func modelColor(for kind: AgentKind) -> Color {
        switch kind {
        case .dsh: return Color(red: 0.753, green: 0.518, blue: 0.988)
        case .antigravity: return Color(red: 0.204, green: 0.827, blue: 0.6)
        case .opencode: return Color(red: 0.984, green: 0.749, blue: 0.141)
        default: return Color(red: 0.22, green: 0.741, blue: 0.973)
        }
    }
}

struct TaskBubbleScrim: View {
    let backgroundOpacity: Double
    var body: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(RadialGradient(colors: [TaskBubbleStyle.ink.opacity(0.18),
                TaskBubbleStyle.ink.opacity(0.06), .clear],
                center: .center, startRadius: 18, endRadius: 230))
            .padding(.horizontal, -9).padding(.vertical, -6)
            .blur(radius: 6)
            .opacity(backgroundOpacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct TaskBubbleText: ViewModifier {
    let backgroundOpacity: Double
    let textOpacity: Double
    func body(content: Content) -> some View {
        let weight = TaskBubbleStyle.shadowWeight(backgroundOpacity)
        let fade = TaskBubbleStyle.shadowFade(textOpacity)
        let scale = TaskBubbleStyle.shadowRadiusScale(textOpacity)
        content
            .shadow(color: TaskBubbleStyle.ink.opacity(0.94 * weight * fade), radius: 0.6 * scale)
            .shadow(color: TaskBubbleStyle.ink.opacity(0.84 * weight * fade), radius: 1.3 * scale)
            .shadow(color: TaskBubbleStyle.ink.opacity(0.4 * weight * backgroundOpacity * fade), radius: 3 * scale, y: 1)
            .opacity(textOpacity)
    }
}

extension View {
    func taskBubbleText(backgroundOpacity: Double, textOpacity: Double) -> some View {
        modifier(TaskBubbleText(backgroundOpacity: backgroundOpacity, textOpacity: textOpacity))
    }
}

struct TaskBubbleModelTag: View {
    let text: String
    let kind: AgentKind
    let fontSize: CGFloat
    let backgroundOpacity: Double
    let textOpacity: Double
    var body: some View {
        let color = TaskBubbleStyle.modelColor(for: kind)
        let fade = TaskBubbleStyle.shadowFade(textOpacity)
        let scale = TaskBubbleStyle.shadowRadiusScale(textOpacity)
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.18 * TaskBubbleStyle.shadowWeight(backgroundOpacity) * backgroundOpacity * fade), radius: 4 * scale)
            .shadow(color: TaskBubbleStyle.ink.opacity(0.96 * fade), radius: 0.55 * scale)
            .shadow(color: TaskBubbleStyle.ink.opacity(0.75 * fade), radius: 1.15 * scale)
            .opacity(textOpacity)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
