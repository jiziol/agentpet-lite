import AppKit
import SwiftUI

/// Read the installed bundle's icon directly so in-app branding matches ICNS.
struct ApplicationIconView: View {
    let size: CGFloat
    private static let artwork: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let image = Self.artwork {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "pawprint.fill").resizable().scaledToFit()
                    .foregroundStyle(Color.systemAccent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("AgentPet Lite")
    }
}
