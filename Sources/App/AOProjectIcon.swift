import AppKit
import SwiftUI

/// Unmodified official AO artwork, pinned to upstream v0.14.6 / e424538.
/// Source and license: THIRD_PARTY_NOTICES.md.
@MainActor
struct AOProjectIcon: View {
    let size: CGFloat

    static let image = loadImage()

    static func loadImage(in application: Bundle = .main) -> NSImage? {
        AppResources.bundle(in: application)?
            .url(forResource: "AgentOrchestrator", withExtension: "svg", subdirectory: "Icons")
            .flatMap { NSImage(contentsOf: $0) }
    }

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("AO").font(.system(size: size * 0.65, weight: .bold))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Agent Orchestrator")
    }
}
