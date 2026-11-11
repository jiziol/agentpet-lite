import Foundation

/// One user-controlled timer, with explicit phase changes and deterministic time.
struct PomodoroClock: Codable, Equatable {
    enum Phase: String, Codable { case focus, rest }
    enum Status: String, Codable { case idle, running, paused, finished }
    private(set) var phase: Phase = .focus
    private(set) var status: Status = .idle
    private(set) var deadline: Date?
    private(set) var savedRemaining: TimeInterval = 0

    func remaining(at now: Date) -> TimeInterval {
        status == .running ? max(0, (deadline ?? now).timeIntervalSince(now)) : savedRemaining
    }

    mutating func startNext(focus: TimeInterval, rest: TimeInterval, now: Date) {
        guard status == .idle || status == .finished else { return }
        let next: Phase = status == .finished && phase == .focus ? .rest : .focus
        let duration = next == .focus ? focus : rest
        guard duration.isFinite, duration > 0, duration <= 86400 else { return }
        phase = next; status = .running; savedRemaining = duration
        deadline = now.addingTimeInterval(duration)
    }

    /// Returns true exactly once for each completed phase.
    @discardableResult mutating func advance(now: Date) -> Bool {
        guard status == .running, let deadline, now >= deadline else { return false }
        status = .finished; self.deadline = nil; savedRemaining = 0
        return true
    }

    @discardableResult mutating func pause(now: Date) -> Bool {
        if advance(now: now) { return true }
        guard status == .running else { return false }
        savedRemaining = remaining(at: now); deadline = nil; status = .paused
        return false
    }

    mutating func resume(now: Date) {
        guard status == .paused, savedRemaining > 0 else { return }
        deadline = now.addingTimeInterval(savedRemaining); status = .running
    }

    mutating func end() { self = PomodoroClock() }

    func snapshot(now: Date) -> Self {
        var copy = self; copy.savedRemaining = remaining(at: now); return copy
    }

    static func restored(_ data: Data?) -> Self {
        guard let data, data.count <= 2048, var value = try? JSONDecoder().decode(Self.self, from: data),
              value.savedRemaining.isFinite, (0...86400).contains(value.savedRemaining),
              value.deadline?.timeIntervalSince1970.isFinite != false else { return Self() }
        if value.status == .running { value.status = .paused }
        value.deadline = nil
        if value.status == .paused && value.savedRemaining == 0 { value.status = .finished }
        return value
    }
}
