import AppKit

/// One reaction owner per pet window, with an explicit teardown boundary.
@MainActor
final class PetReactionController {
    struct State: Equatable { var isPetted = false; var line = ""; var tapCount = 0 }
    private(set) var state = State()
    private let changed: (State) -> Void
    private let pickLine: () -> String
    private let sound: () -> Void
    private let lineDuration: TimeInterval
    private let generation = InteractionGeneration()
    private var bounce: Timer?
    private var line: Timer?
    /// Fences an already-enqueued tap-line callback; bounce/cooldown continue
    /// using the existing `generation` token untouched.
    private var lineToken: UInt64 = 0
    private var cooldownWork: DispatchWorkItem?
    private var cooldown = false
    init(pickLine: @escaping () -> String = { IdleSpeechSettings.shared.pick() },
         sound: @escaping () -> Void = { NSSound(named: "Pop")?.play() },
         lineDuration: TimeInterval = 2.0,
         changed: @escaping (State) -> Void) {
        self.pickLine = pickLine; self.sound = sound
        self.lineDuration = lineDuration; self.changed = changed
    }
    func tap() {
        guard !cooldown else { return }
        cooldown = true
        let lineText = pickLine()
        state.line = lineText
        state.tapCount += 1; state.isPetted = true; changed(state)
        let token = generation.renew()
        lineToken &+= 1
        let currentLineToken = lineToken
        bounce?.invalidate(); line?.invalidate(); cooldownWork?.cancel()
        bounce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation.accepts(token) else { return }
                self.state.isPetted = false; self.changed(self.state)
            }
        }
        line = Timer.scheduledTimer(withTimeInterval: lineDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.lineToken == currentLineToken,
                      self.generation.accepts(token), self.state.line == lineText else { return }
                self.state.line = ""; self.changed(self.state)
            }
        }
        sound()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation.accepts(token) else { return }
            self.cooldown = false
        }
        cooldownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    func stop() {
        generation.renew(); bounce?.invalidate(); bounce = nil; line?.invalidate(); line = nil; lineToken &+= 1
        cooldownWork?.cancel(); cooldownWork = nil; cooldown = false
        state.isPetted = false; state.line = ""; changed(state)
    }
}
