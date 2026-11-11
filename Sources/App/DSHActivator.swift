import AppKit
import os
import AgentPetCore

/// Structured reason for requesting one exact DSH instance's activation.
/// `.activated` only means the system allowed the request — the caller still
/// proves real frontmost state and re-validates the peer generation.
enum DSHActivationOutcome: Equatable {
    case activated
    case appMissing
    case bundleMismatch
    case terminated
    case requestRejected
    case selfActivationFailed
    case yieldRejected
    case cancelled
    /// The navigation target or token changed while activation was in flight;
    /// the target must not be (further) activated.
    case superseded
}

/// One resolved NSRunningApplication snapshot used for exact-instance checks
/// and minimal structured logging (no session content, no secrets).
struct DSHActivationTarget: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let isTerminated: Bool
    let activationPolicy: NSApplication.ActivationPolicy
}

/// The smallest injectable AppKit surface for the activation sequence.
@MainActor
protocol DSHActivationEnvironment: AnyObject {
    func target(pid: pid_t) -> DSHActivationTarget?
    func frontmostPID() -> pid_t?
    /// Direct request; `true` means the system allowed it (never "now active").
    func requestSystemActivation(pid: pid_t) -> Bool
    /// Ask our own app to become active (macOS 14+ cooperative prerequisite).
    func requestSelfActivation() -> Bool
    func isCurrentActive() -> Bool
    /// Yield our own active status to the target; only the active app can yield.
    func yieldActivation(toPID pid: pid_t) -> Bool
    /// Cooperative request: activate the target from our app (macOS 14+).
    func cooperativeActivation(ofPID pid: pid_t) -> Bool
    /// Whether the cooperative API surface exists on this OS (macOS 14+).
    var supportsCooperativeActivation: Bool { get }
    func sleep(milliseconds: Int) async
}

@MainActor
final class SystemDSHActivationEnvironment: DSHActivationEnvironment {
    private func app(_ pid: pid_t) -> NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }

    func target(pid: pid_t) -> DSHActivationTarget? {
        guard let application = app(pid) else { return nil }
        return DSHActivationTarget(pid: pid, bundleIdentifier: application.bundleIdentifier,
                                   isTerminated: application.isTerminated,
                                   activationPolicy: application.activationPolicy)
    }
    func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func requestSystemActivation(pid: pid_t) -> Bool {
        guard let application = app(pid) else { return false }
        if #available(macOS 14.0, *) { return application.activate(options: [.activateAllWindows]) }
        // macOS 13 only: the ignoring flag is deprecated and ineffective on 14+,
        // so it is never used there.
        return application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
    func requestSelfActivation() -> Bool {
        if #available(macOS 14.0, *) { NSApp.activate(); return true }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
    func isCurrentActive() -> Bool { NSApp.isActive }
    func yieldActivation(toPID pid: pid_t) -> Bool {
        // NSApplication yields the *receiver's* active status to the given app.
        // The API returns void; an app that cannot yield simply reports true
        // here and the cooperative request below decides.
        guard #available(macOS 14.0, *), let application = app(pid) else { return false }
        NSApp.yieldActivation(to: application)
        return true
    }
    func cooperativeActivation(ofPID pid: pid_t) -> Bool {
        guard #available(macOS 14.0, *), let application = app(pid) else { return false }
        return application.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
    }
    var supportsCooperativeActivation: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }
    func sleep(milliseconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}

/// Bounded, exact-instance DSH activation. The direct request stays the fast
/// path; on macOS 14+ a single cooperative fallback is allowed when the system
/// does not allow it: request our own active status, confirm it within a
/// bounded wait, yield to the same verified instance, then activate from us.
/// We never assume another foreground app yielded for us, and an allowed
/// request is still not proof of frontmost state.
@MainActor
final class DSHActivator {
    static let bundleIdentifier = "com.deepseek.dsh"
    private static let logger = Logger(subsystem: AgentPetPaths.bundleIdentifier, category: "DSHActivation")
    private let environment: DSHActivationEnvironment

    init(environment: DSHActivationEnvironment = SystemDSHActivationEnvironment()) {
        self.environment = environment
    }

    func activate(pid: pid_t, validate: @escaping @MainActor () -> Bool) async -> DSHActivationOutcome {
        if Task.isCancelled { return .cancelled }
        guard validate() else { return stopped(.superseded, stage: "precheck") }
        switch checkedTarget(pid: pid) {
        case .failed(let outcome): return failed(outcome, stage: "instance", pid: pid)
        case .ok(let target):
            let frontmost = environment.frontmostPID().map(String.init) ?? "none"
            Self.logger.info("DSH activation request pid=\(pid, privacy: .public) policy=\(target.activationPolicy.rawValue, privacy: .public) frontmost=\(frontmost, privacy: .public)")
        }
        if environment.requestSystemActivation(pid: pid) { return .activated }
        guard environment.supportsCooperativeActivation else {
            return failed(.requestRejected, stage: "directRejected", pid: pid)
        }
        // Modern direct rejection records our own active state so a real
        // capture can separate "system refused" from "we were never active".
        let sourceActive = environment.isCurrentActive()
        Self.logger.notice("DSH activation stage=directRejected sourceActive=\(sourceActive, privacy: .public) pid=\(pid, privacy: .public)")
        guard environment.requestSelfActivation() else {
            return failed(.selfActivationFailed, stage: "selfActivationRequest", pid: pid)
        }
        var becameActive = false
        for _ in 0..<10 {
            if Task.isCancelled { return .cancelled }
            if environment.isCurrentActive() { becameActive = true; break }
            await environment.sleep(milliseconds: 50)
            // Every await re-validates: the store's turn/host can change while
            // this wait is in flight and nothing cancels the task.
            guard validate() else { return stopped(.superseded, stage: "duringWait") }
        }
        guard becameActive, environment.isCurrentActive() else {
            return failed(.selfActivationFailed, stage: "selfActive", pid: pid)
        }
        if Task.isCancelled { return .cancelled }
        guard validate() else { return stopped(.superseded, stage: "postWait") }
        switch checkedTarget(pid: pid) {
        case .failed(let outcome):
            return failed(outcome, stage: "instanceChanged", pid: pid)
        case .ok: break
        }
        guard environment.yieldActivation(toPID: pid) else {
            return failed(.yieldRejected, stage: "yield", pid: pid)
        }
        if Task.isCancelled { return .cancelled }
        guard validate() else { return stopped(.superseded, stage: "postYield") }
        let allowed = environment.cooperativeActivation(ofPID: pid)
        guard allowed else { return failed(.requestRejected, stage: "cooperativeActivation", pid: pid) }
        Self.logger.info("DSH activation: cooperative request allowed pid=\(pid, privacy: .public)")
        return .activated
    }

    /// Terminal failure: a notice per stage plus one error with the final cause,
    /// keeping real failures searchable without any session content.
    private func failed(_ outcome: DSHActivationOutcome, stage: String, pid: pid_t) -> DSHActivationOutcome {
        Self.logger.notice("DSH activation stage=\(stage, privacy: .public) pid=\(pid, privacy: .public)")
        Self.logger.error("DSH activation failed reason=\(String(describing: outcome), privacy: .public) stage=\(stage, privacy: .public) pid=\(pid, privacy: .public)")
        return outcome
    }

    private func stopped(_ outcome: DSHActivationOutcome, stage: String) -> DSHActivationOutcome {
        Self.logger.notice("DSH activation stopped stage=\(stage, privacy: .public) reason=\(String(describing: outcome), privacy: .public)")
        return outcome
    }

    /// Re-checks the exact instance (same pid, bundle, not terminated) before
    /// and after the cooperative fallback.
    private enum TargetCheck {
        case ok(DSHActivationTarget)
        case failed(DSHActivationOutcome)
    }

    private func checkedTarget(pid: pid_t) -> TargetCheck {
        guard let target = environment.target(pid: pid) else { return .failed(.appMissing) }
        guard target.bundleIdentifier == Self.bundleIdentifier else { return .failed(.bundleMismatch) }
        guard !target.isTerminated else { return .failed(.terminated) }
        return .ok(target)
    }
}
