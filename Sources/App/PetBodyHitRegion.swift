import AppKit
import SwiftUI

/// Tracks the pet's actual AppKit region without intercepting taps or drags.
/// Bubble growth, sprite scaling and screen-edge offsets are handled by layout.
@MainActor
struct PetBodyHitRegion: NSViewRepresentable {
    let model: PetWindowModel

    func makeNSView(context: Context) -> HitRegionView {
        let view = HitRegionView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: HitRegionView, context: Context) {
        if nsView.model !== model, nsView.model?.petBodyView === nsView {
            nsView.model?.petBodyView = nil
        }
        nsView.model = model
        nsView.registerIfMounted()
    }

    final class HitRegionView: NSView {
        weak var model: PetWindowModel?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { registerIfMounted() }
            else if model?.petBodyView === self { model?.petBodyView = nil }
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            registerIfMounted()
        }
        func registerIfMounted() {
            // SwiftUI may create detached views while measuring/rebuilding an
            // animated subtree. They must not replace the live panel's marker.
            guard window != nil else { return }
            model?.petBodyView = self
        }
    }
}

/// A non-interactive marker for the entire message region above the pet.
@MainActor
struct PetMessageHitRegion: NSViewRepresentable {
    let model: PetWindowModel
    func makeNSView(context: Context) -> NSView {
        let view = RegionView()
        view.model = model
        model.messageBubbleView = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        model.messageBubbleView = nsView
        (nsView as? RegionView)?.reportLayout()
    }
    private final class RegionView: NSView {
        weak var model: PetWindowModel?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reportLayout() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); reportLayout() }
        func reportLayout() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.bounds.width > 0, self.bounds.height > 0 else { return }
                self.model?.onMessageLayoutReady?()
            }
        }
    }
}
