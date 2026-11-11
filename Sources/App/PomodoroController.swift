import AppKit
import OSLog
import AgentPetCore

@MainActor
final class PomodoroController: ObservableObject {
    static let shared: PomodoroController = PomodoroController(defaults: .standard, clearNotice: {
        PetController.shared.systemNotices.dismissPomodoro()
    }) { phase in
        PetController.shared.showPomodoroFinished(phase: phase,
            focusMinutes: PomodoroController.shared.focusMinutes, restMinutes: PomodoroController.shared.restMinutes,
            onConfirmed: PomodoroController.shared.nextPhaseAction())
    }
    static let clockKey = "agentpet.pomodoro.clock.v1"
    static let focusKey = "agentpet.pomodoro.focusMinutes"
    static let restKey = "agentpet.pomodoro.restMinutes"
    @Published private(set) var clock: PomodoroClock
    @Published private(set) var now = Date()
    @Published var focusMinutes: Int {
        didSet {
            let value = min(240, max(1, focusMinutes))
            if value != focusMinutes { focusMinutes = value }
            defaults.set(value, forKey: Self.focusKey)
        }
    }
    @Published var restMinutes: Int {
        didSet {
            let value = min(120, max(1, restMinutes))
            if value != restMinutes { restMinutes = value }
            defaults.set(value, forKey: Self.restKey)
        }
    }
    private let defaults: UserDefaults
    private let notify: (PomodoroClock.Phase) -> Void
    private let clearNotice: () -> Void
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var lastSaved = Date.distantPast
    private var phaseID = UUID()

    init(defaults: UserDefaults, clearNotice: @escaping () -> Void = {}, notify: @escaping (PomodoroClock.Phase) -> Void) {
        self.defaults = defaults; self.notify = notify; self.clearNotice = clearNotice
        focusMinutes = min(240, max(1, (defaults.object(forKey: Self.focusKey) as? Int) ?? 25))
        restMinutes = min(120, max(1, (defaults.object(forKey: Self.restKey) as? Int) ?? 5))
        clock = PomodoroClock.restored(defaults.data(forKey: Self.clockKey))
        save()
    }

    func activate() {
        guard sleepObserver == nil else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pause() }
            }
    }

    var remainingText: String {
        let seconds = max(0, Int(ceil(clock.remaining(at: now))))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func startNext() {
        guard clock.status == .idle || clock.status == .finished else { return }
        phaseID = UUID()
        clearNotice()
        now = Date(); clock.startNext(focus: Double(focusMinutes) * 60, rest: Double(restMinutes) * 60, now: now)
        save(); schedule()
    }
    func pause() {
        now = Date(); let completed = clock.pause(now: now)
        save(); schedule(); if completed { notify(clock.phase) }
    }
    func resume() { now = Date(); clock.resume(now: now); save(); schedule() }
    func end() { phaseID = UUID(); now = Date(); clock.end(); clearNotice(); save(); schedule() }

    /// Bind the confirmation to this exact completed phase, never a later cycle.
    func nextPhaseAction() -> () -> Void {
        let id = phaseID
        return { [weak self] in
            guard let self, self.phaseID == id, self.clock.status == .finished else { return }
            self.startNext()
        }
    }

    func prepareForTermination() {
        pause()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
    }

    func tick(at date: Date = Date()) {
        now = date
        let completed = clock.advance(now: now)
        #if AGENTPET_LOCAL
        if completed {
            Logger(subsystem: AgentPetPaths.bundleIdentifier, category: "pomodoro-notice").notice("timer completed phase=\(self.clock.phase.rawValue, privacy: .public)")
        }
        #endif
        if completed || now.timeIntervalSince(lastSaved) >= 30 { save() }
        if completed { schedule(); notify(clock.phase) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(clock.snapshot(now: now)) {
            defaults.set(data, forKey: Self.clockKey); lastSaved = now
        }
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard clock.status == .running else { return }
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer = tick; RunLoop.main.add(tick, forMode: .common)
    }
}
