import AppKit
import SwiftUI

/// A multiline text editor that grows with its content and has no scroll view
/// of its own, so scrolling never chains into the surrounding form.
struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> AutoTextView {
        let view = AutoTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.font = .preferredFont(forTextStyle: .callout)
        view.textColor = .labelColor
        view.alignment = .left
        view.defaultParagraphStyle = Self.leftStyle   // never justify (emoji lines stretched words)
        view.typingAttributes[.paragraphStyle] = Self.leftStyle
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 2
        return view
    }

    /// Forced left, non-justified. Setting `.string` can drop the alignment, so
    /// we re-stamp this paragraph style on the whole content after every update.
    static let leftStyle: NSParagraphStyle = {
        let s = NSMutableParagraphStyle()
        s.alignment = .left
        s.lineBreakMode = .byWordWrapping
        return s
    }()

    func updateNSView(_ view: AutoTextView, context: Context) {
        if view.string != text {
            view.string = text
            view.invalidateIntrinsicContentSize()
        }
        view.alignment = .left
        view.textStorage?.addAttribute(
            .paragraphStyle, value: Self.leftStyle,
            range: NSRange(location: 0, length: (view.string as NSString).length))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// NSTextView that reports its content height so SwiftUI can size it to fit.
final class AutoTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 40))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}
