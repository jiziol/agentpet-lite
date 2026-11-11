import SwiftUI

/// A small speech bubble with an upward tail, dropped from the menu bar icon.
struct MenuBarChatBubble: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(.regularMaterial)
                .frame(width: 14, height: 7)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
        }
        .appAppearance()
        .padding(6)
        .fixedSize()
    }
}

/// Upward-pointing triangle (apex at top).
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
