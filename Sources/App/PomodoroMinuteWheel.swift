import AppKit
import SwiftUI

struct PomodoroMinuteWheel: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String
    let accessibilityLabel: String
    let identifier: String
    let accent: Color
    var body: some View {
        VStack(spacing: 8) {
            Text(LocalizedStringKey(label)).font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
            VStack(spacing: 0) {
                number(value - 1, selected: false)
                number(value, selected: true)
                    .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5) }
                    .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5) }
                number(value + 1, selected: false)
            }
            .accessibilityHidden(true)
            .overlay {
                PomodoroWheelInput(value: $value, range: range, label: accessibilityLabel, identifier: identifier)
            }
        }
        .frame(maxWidth: .infinity)
    }
    private func number(_ number: Int, selected: Bool) -> some View {
        Text(range.contains(number) ? String(number) : "—")
            .font(.system(size: selected ? 36 : 22, weight: selected ? .medium : .regular, design: .monospaced))
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.20))
            .frame(width: 88, height: 38)
    }
}

private struct PomodoroWheelInput: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String
    let identifier: String
    func makeNSView(context: Context) -> PomodoroWheelNSView { PomodoroWheelNSView() }
    func updateNSView(_ view: PomodoroWheelNSView, context: Context) {
        view.value = value; view.range = range; view.changed = { value = $0 }
        view.setAccessibilityLabel(NSLocalizedString(label, comment: "Pomodoro wheel"))
        view.setAccessibilityIdentifier(identifier)
    }
}

/// Handles only the wheel under the pointer, so Status itself remains scrollable.
private final class PomodoroWheelNSView: NSView {
    var value = 1
    var range = 1...240
    var changed: ((Int) -> Void)?
    private var remainder: CGFloat = 0
    private var dragY: CGFloat?
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: range.lowerBound) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: range.upperBound) }
    override func setAccessibilityValue(_ newValue: Any?) {
        if let n = newValue as? NSNumber { select(n.intValue) }
        else if let s = newValue as? String, let n = Int(s) { select(n) }
    }
    override func accessibilityPerformIncrement() -> Bool { select(value + 1); return true }
    override func accessibilityPerformDecrement() -> Bool { select(value - 1); return true }
    private func select(_ next: Int) {
        let bounded = min(range.upperBound, max(range.lowerBound, next))
        guard bounded != value else { return }
        value = bounded; changed?(bounded)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .began { remainder = 0 }
        if event.hasPreciseScrollingDeltas {
            remainder += event.scrollingDeltaY
            let steps = min(6, max(-6, Int(remainder / 12)))
            if steps != 0 { select(value - steps); remainder -= CGFloat(steps) * 12 }
        } else if event.scrollingDeltaY != 0 { select(value + (event.scrollingDeltaY > 0 ? -1 : 1)) }
        if event.phase == .ended || event.phase == .cancelled { remainder = 0 }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); dragY = event.locationInWindow.y
        let y = convert(event.locationInWindow, from: nil).y
        if y > bounds.height * 2 / 3 { select(value - 1) }
        else if y < bounds.height / 3 { select(value + 1) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragY else { return }
        let steps = Int((event.locationInWindow.y - origin) / 12)
        if steps != 0 { select(value + steps); dragY = event.locationInWindow.y }
    }
    override func mouseUp(with event: NSEvent) { dragY = nil }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: select(value + 1)
        case 125: select(value - 1)
        default: super.keyDown(with: event)
        }
    }
}
