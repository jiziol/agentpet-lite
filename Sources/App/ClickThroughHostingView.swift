import AppKit
import SwiftUI

/// A hosting view whose controls respond on the first click even when its
/// window is not key. Lets non-activating panels stay interactive without ever
/// stealing keyboard focus from the user's current app.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension View {
    /// Removes the blue keyboard focus ring from controls within.
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}
