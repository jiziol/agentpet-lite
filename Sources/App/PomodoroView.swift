import SwiftUI

/// Two quiet wheels at rest; split-flap digits while running or paused.
/// All actions use the existing timer; phase changes remain user-controlled.
struct PomodoroView: View {
    @ObservedObject private var timer = PomodoroController.shared
    @ObservedObject private var pet = PetController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var busy: Bool { timer.clock.status == .running || timer.clock.status == .paused }
    private var nextIsRest: Bool { timer.clock.status == .finished && timer.clock.phase == .focus }
    private var focusColor: Color { Color(red: 0.50, green: 0.44, blue: 0.74) }
    private var restColor: Color { Color(red: 0.25, green: 0.62, blue: 0.40) }
    private var phaseColor: Color { timer.clock.phase == .focus ? focusColor : restColor }
    private var animate: Bool { pet.animationsEnabled && !reduceMotion && timer.clock.status == .running }
    private var progress: Double {
        let total = Double(timer.clock.phase == .focus ? timer.focusMinutes : timer.restMinutes) * 60
        return min(1, max(0, 1 - timer.clock.remaining(at: timer.now) / total))
    }
    var body: some View {
        Group {
            if busy { countdown } else { setup }
        }
        .frame(maxWidth: .infinity).frame(height: 176)
        .textSelection(.disabled)
    }
    private var setup: some View {
        HStack(spacing: 0) {
            PomodoroMinuteWheel(value: $timer.focusMinutes, range: 1...240, label: "Focus",
                accessibilityLabel: "Focus minutes", identifier: "pomodoro-focus-duration",
                accent: nextIsRest ? .secondary : focusColor)
            VStack(spacing: 10) {
                Rectangle().fill(.primary.opacity(0.10)).frame(width: 1, height: 30)
                iconButton("play.fill", label: nextIsRest ? "Start break" : "Start focus", id: "pomodoro-start",
                    tint: nextIsRest ? restColor : focusColor, action: timer.startNext)
                Rectangle().fill(.primary.opacity(0.10)).frame(width: 1, height: 30)
                if timer.clock.status == .finished {
                    iconButton("arrow.counterclockwise", label: "End", id: "pomodoro-end", small: true, action: timer.end)
                }
            }.frame(width: 60)
            PomodoroMinuteWheel(value: $timer.restMinutes, range: 1...120, label: "Break",
                accessibilityLabel: "Break minutes", identifier: "pomodoro-rest-duration",
                accent: nextIsRest ? restColor : .secondary)
        }
    }
    private var countdown: some View {
        let pieces = timer.remainingText.split(separator: ":").map(String.init)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                PomodoroFlipTile(value: pieces.first ?? "00", animate: animate)
                VStack(spacing: 12) {
                    Circle().frame(width: 4, height: 4)
                    Circle().frame(width: 4, height: 4)
                }.foregroundStyle(.secondary)
                PomodoroFlipTile(value: pieces.last ?? "00", animate: animate)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LocalizedStringKey(timer.clock.phase == .focus ? "Focus" : "Break"))
            .accessibilityValue(timer.remainingText)
            .accessibilityIdentifier("pomodoro-remaining")
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.09))
                    Capsule().fill(phaseColor).frame(width: proxy.size.width * progress)
                }
            }.frame(width: 248, height: 4)
                .accessibilityLabel("Progress").accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
            HStack(spacing: 18) {
                Image(systemName: timer.clock.phase == .focus ? "circle.fill" : "leaf.fill")
                    .font(.system(size: 11)).foregroundStyle(phaseColor)
                    .help(LocalizedStringKey(timer.clock.phase == .focus ? "Focus" : "Break"))
                if timer.clock.status == .running {
                    iconButton("pause.fill", label: "Pause", id: "pomodoro-pause", small: true, action: timer.pause)
                } else {
                    iconButton("play.fill", label: "Resume", id: "pomodoro-resume", small: true, tint: phaseColor, action: timer.resume)
                }
                iconButton("stop.fill", label: "End", id: "pomodoro-end", small: true, action: timer.end)
            }
        }
    }
    private func iconButton(_ icon: String, label: String, id: String, small: Bool = false,
                            tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: small ? 14 : 18, weight: .semibold))
                .foregroundStyle(tint).frame(width: small ? 34 : 46, height: small ? 34 : 46)
                .background(Circle().fill(.primary.opacity(small ? 0.025 : 0.035)))
                .overlay(Circle().strokeBorder(.primary.opacity(small ? 0.06 : 0.12), lineWidth: 0.7))
        }
        .buttonStyle(.plain).help(LocalizedStringKey(label)).accessibilityLabel(LocalizedStringKey(label))
        .accessibilityIdentifier(id)
    }
}
