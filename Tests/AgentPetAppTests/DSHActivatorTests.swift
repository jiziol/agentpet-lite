import XCTest
@testable import agentpet

/// The activation sequence is exercised through the injectable environment so
/// each branch (direct, cooperative fallback, refusals, cancellation) is real
/// control flow, not a mirrored copy of the implementation.
@MainActor
final class DSHActivatorTests: XCTestCase {
    private final class FakeEnvironment: DSHActivationEnvironment {
        var targetValue: DSHActivationTarget? = .init(pid: 42, bundleIdentifier: "com.deepseek.dsh",
                                                      isTerminated: false, activationPolicy: .regular)
        /// Successive exact-instance checks can observe a changed snapshot.
        var queuedTargets: [DSHActivationTarget?] = []
        var frontmost: pid_t? = 99
        var supportsCooperative = true
        var systemAccepted = true
        var selfRequestSucceeds = true
        var selfBecomesActive = true
        var yieldAccepted = true
        var cooperativeAccepted = true
        var calls: [String] = []
        /// Runs inside the bounded self-activation wait so a test can model a
        /// store change that happens while this task is suspended.
        var onSleep: (() -> Void)?

        func target(pid: pid_t) -> DSHActivationTarget? {
            calls.append("target")
            let value = queuedTargets.isEmpty ? targetValue : queuedTargets.removeFirst()
            guard let value, value.pid == pid else { return nil }
            return value
        }
        func frontmostPID() -> pid_t? { calls.append("frontmost"); return frontmost }
        func requestSystemActivation(pid: pid_t) -> Bool { calls.append("requestSystem"); return systemAccepted }
        func requestSelfActivation() -> Bool { calls.append("requestSelf"); return selfRequestSucceeds }
        func isCurrentActive() -> Bool { calls.append("isActive"); return selfBecomesActive }
        func yieldActivation(toPID pid: pid_t) -> Bool { calls.append("yield"); return yieldAccepted }
        func cooperativeActivation(ofPID pid: pid_t) -> Bool { calls.append("cooperative"); return cooperativeAccepted }
        var supportsCooperativeActivation: Bool { supportsCooperative }
        func sleep(milliseconds: Int) async { calls.append("sleep"); onSleep?() }
    }

    private func activator(_ environment: FakeEnvironment) -> DSHActivator {
        DSHActivator(environment: environment)
    }

    func testDirectActivationSuccessKeepsTheFastPath() async {
        let environment = FakeEnvironment()
        let outcome = await activator(environment).activate(pid: 42, validate: { true })
        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(environment.calls, ["target", "frontmost", "requestSystem"])
    }

    func testExactInstanceFailuresAreDistinguished() async {
        let cases: [(DSHActivationTarget?, DSHActivationOutcome)] = [
            (nil, .appMissing),
            (.init(pid: 42, bundleIdentifier: "com.other.app", isTerminated: false, activationPolicy: .regular), .bundleMismatch),
            (.init(pid: 42, bundleIdentifier: "com.deepseek.dsh", isTerminated: true, activationPolicy: .regular), .terminated),
        ]
        for (target, expected) in cases {
            let environment = FakeEnvironment()
            environment.targetValue = target
            let outcome = await activator(environment).activate(pid: 42, validate: { true })
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(environment.calls, ["target"])
        }
    }

    func testLegacyPathRejectsWithoutCooperativeFallback() async {
        let environment = FakeEnvironment()
        environment.supportsCooperative = false
        environment.systemAccepted = false
        let outcome = await activator(environment).activate(pid: 42, validate: { true })
        XCTAssertEqual(outcome, .requestRejected)
        XCTAssertEqual(environment.calls, ["target", "frontmost", "requestSystem"])
    }

    func testCooperativeFallbackYieldsAndActivatesTheSameInstance() async {
        let environment = FakeEnvironment()
        environment.systemAccepted = false
        let outcome = await activator(environment).activate(pid: 42, validate: { true })
        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(environment.calls, ["target", "frontmost", "requestSystem", "isActive",
                                           "requestSelf", "isActive", "isActive", "target", "yield", "cooperative"])
    }

    func testSelfActivationRequestAndConfirmationFailuresHaveTheirOwnReason() async {
        let requestFails = FakeEnvironment()
        requestFails.systemAccepted = false
        requestFails.selfRequestSucceeds = false
        let failedRequest = await activator(requestFails).activate(pid: 42, validate: { true })
        XCTAssertEqual(failedRequest, .selfActivationFailed)

        let neverActive = FakeEnvironment()
        neverActive.systemAccepted = false
        neverActive.selfBecomesActive = false
        let outcome = await activator(neverActive).activate(pid: 42, validate: { true })
        XCTAssertEqual(outcome, .selfActivationFailed)
        XCTAssertEqual(neverActive.calls.filter { $0 == "isActive" }.count, 11)  // sourceActive log + bounded wait
    }

    func testYieldAndCooperativeRefusalsAreDistinguished() async {
        let yieldFails = FakeEnvironment()
        yieldFails.systemAccepted = false
        yieldFails.yieldAccepted = false
        let yieldOutcome = await activator(yieldFails).activate(pid: 42, validate: { true })
        XCTAssertEqual(yieldOutcome, .yieldRejected)

        let cooperativeFails = FakeEnvironment()
        cooperativeFails.systemAccepted = false
        cooperativeFails.cooperativeAccepted = false
        let cooperativeOutcome = await activator(cooperativeFails).activate(pid: 42, validate: { true })
        XCTAssertEqual(cooperativeOutcome, .requestRejected)
    }

    func testInstanceChangeBeforeYieldStopsWithoutRequesting() async {
        let environment = FakeEnvironment()
        environment.systemAccepted = false
        environment.selfBecomesActive = true
        // The second exact-instance check sees a terminated app.
        environment.queuedTargets = [
            .init(pid: 42, bundleIdentifier: "com.deepseek.dsh", isTerminated: false, activationPolicy: .regular),
            .init(pid: 42, bundleIdentifier: "com.deepseek.dsh", isTerminated: true, activationPolicy: .regular),
        ]
        let outcome = await activator(environment).activate(pid: 42, validate: { true })
        XCTAssertEqual(outcome, .terminated)
        XCTAssertFalse(environment.calls.contains("yield"))
    }

    func testCancelledTaskStopsBeforeAnyRequest() async {
        let environment = FakeEnvironment()
        let task = Task { await activator(environment).activate(pid: 42, validate: { true }) }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testValidationFailureDuringSleepWaitStopsWithoutYielding() async {
        let environment = FakeEnvironment()
        environment.systemAccepted = false
        environment.selfBecomesActive = false      // force the bounded wait to sleep
        var valid = true
        environment.onSleep = {
            // The store's turn/host changes while this task is suspended, and
            // nothing cancels the task.
            environment.selfBecomesActive = true
            valid = false
        }
        let outcome = await activator(environment).activate(pid: 42, validate: { valid })
        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(environment.calls.contains("sleep"))
        XCTAssertFalse(environment.calls.contains("yield"))
        XCTAssertFalse(environment.calls.contains("cooperative"))
    }

    func testValidationFailureAtPrecheckStopsBeforeAnyRequest() async {
        let environment = FakeEnvironment()
        let outcome = await activator(environment).activate(pid: 42, validate: { false })
        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(environment.calls.isEmpty)
    }
}