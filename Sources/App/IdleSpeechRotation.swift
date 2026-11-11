import Foundation

/// A single main-run-loop timer. Blocked chatter starts a fresh interval,
/// never accumulates missed lines or races a cancelled callback.
@MainActor
final class IdleSpeechRotation {
    static let interval: TimeInterval = 20
    private let delay: TimeInterval
    private let eligible: () -> Bool
    private let advance: () -> Void
    private var timer: Timer?
    private(set) var generation: UUID?
    private(set) var isRunning = false

    init(delay: TimeInterval = IdleSpeechRotation.interval,
         eligible: @escaping () -> Bool, advance: @escaping () -> Void) {
        self.delay = delay.isFinite ? max(0.1, delay) : Self.interval
        self.eligible = eligible
        self.advance = advance
    }

    func start() { isRunning = true; reconcile() }
    func stop() { isRunning = false; cancel() }

    func reconcile() {
        guard isRunning, eligible() else { cancel(); return }
        guard timer == nil else { return }
        let token = UUID()
        generation = token
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fire(token) }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    func fire(_ token: UUID) {
        guard isRunning, generation == token else { return }
        cancel()
        guard eligible() else { return }
        advance()
        reconcile()
    }

    private func cancel() {
        timer?.invalidate(); timer = nil; generation = nil
    }
}
