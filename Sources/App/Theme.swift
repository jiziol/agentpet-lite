import SwiftUI
import AppKit

extension Color {
    /// The system accent stays saturated when the window is not key.
    static var systemAccent: Color { Color(nsColor: .controlAccentColor) }
}

/// Neutral surfaces shared by Settings, sheets and floating panels.
/// Dynamic NSColors also follow macOS changes while the app is in System mode.
enum Theme {
    static let accent = Color(red: 0.20, green: 0.60, blue: 1.0)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x181818)
    static let card = adaptive(light: 0xF7F7F7, dark: 0x232323)
    static let input = adaptive(light: 0xFFFFFF, dark: 0x181818)
    static let cardStroke = adaptive(light: 0xE5E5E5, dark: 0x363636)
    static let foreground = adaptive(light: 0x1A1C1D, dark: 0xFFFFFF)
    static let muted = adaptive(light: 0x63666A, dark: 0xABABAB)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }

    static var background: some View { surface.ignoresSafeArea() }
}

/// Keep independently hosted SwiftUI roots in the same theme as AppKit chrome.
private struct AppAppearanceModifier: ViewModifier {
    @ObservedObject private var settings = BubbleSettings.shared
    @Environment(\.colorScheme) private var inheritedScheme

    func body(content: Content) -> some View {
        // AppKit owns window appearance. A SwiftUI window preference can linger
        // after dark -> nil; override only this subtree, inheriting System live.
        content.environment(\.colorScheme, settings.theme.colorScheme ?? inheritedScheme)
    }
}

struct EyebrowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(Theme.muted)
    }
}

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

extension View {
    func themedCard() -> some View { modifier(CardModifier()) }
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
}

/// Status-only palette: the shared Settings theme and its controls stay intact.
enum StatusHUDStyle {
    static let background = adaptive(0xF6F6F7, 0x242426)
    static let card = adaptive(0xFFFFFF, 0x2C2C2F)
    static let inset = adaptive(0xF7F8FA, 0x333336)
    static let line = adaptive(0xE5E6E8, 0x414145)
    static let secondary = adaptive(0x63666D, 0xB5B5BD)
    static let tertiary = adaptive(0x777B83, 0xA0A0AA)
    static let green = adaptive(0x05966B, 0x50D8AE)
    static let amber = adaptive(0xAF6307, 0xF2B655)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let v = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((v >> 16) & 255) / 255,
                           green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func statusHUDSection() -> some View {
        self.padding(.horizontal, 2).padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(StatusHUDStyle.line).frame(height: 0.5) }
    }
}
