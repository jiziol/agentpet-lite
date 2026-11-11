import AppKit
import CryptoKit
import AgentPetCore

struct DSHReadinessResult: Sendable {
    enum Status: String, Sendable { case readyToInstall, startRequired, repairRequired, connected, unconfirmed, endpointUnavailable, incompatible, limited, failed, cancelled }
    struct Check: Sendable {
        let key: String
        let passed: Bool
        var detail = ""
    }
    var status: Status
    var checks: [Check] = []
    var evidence = ""
}

/// Volatile metadata from the live socket callback only, never persisted history
/// or queue replay. Test reads this cache and cannot manufacture an observation.
struct DSHLiveSignals {
    struct Signal: Sendable { let observation: DSHObservation; let receivedAt: Date }
    private var signals: [String: Signal] = [:]

    mutating func receive(_ event: AgentEvent, at now: Date) {
        guard event.agentKind == .dsh, event.eventName == "dsh/observation", let value = event.dsh,
              value.valid, event.sessionId == value.sessionKey, value.hostStartedAt <= event.timestamp,
              abs(event.timestamp.timeIntervalSince(now)) <= 5 else { return }
        signals = signals.filter { now.timeIntervalSince($0.value.receivedAt) <= 30 }
        if let old = signals[value.profileID], old.observation.hostID == value.hostID,
           old.observation.nativeSessionID == value.nativeSessionID,
           old.observation.revision >= value.revision { return }
        if let old = signals[value.profileID], old.observation.hostID != value.hostID,
           old.observation.hostStartedAt >= value.hostStartedAt { return }
        signals[value.profileID] = .init(observation: value, receivedAt: now)
        if signals.count > 32, let oldest = signals.min(by: { $0.value.receivedAt < $1.value.receivedAt })?.key {
            signals.removeValue(forKey: oldest)
        }
    }

    func signal(profileID: String, since: Date) -> Signal? {
        guard let value = signals[profileID], value.receivedAt >= since else { return nil }
        return value
    }

    static func profileID(_ target: DSHIntegrationSetup.Target) -> String {
        let path = target.home.appendingPathComponent("profiles/desktop").resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }
}

@MainActor
enum DSHReadinessTest {
    typealias SignalSource = @MainActor (String, Date) -> DSHLiveSignals.Signal?
    typealias PeerVerifier = @MainActor (DSHObservation, DSHIntegrationSetup.Target) async -> Bool

    typealias HealthSource = @MainActor (DSHIntegrationSetup.Target) async -> [DSHBridgeProtocol.Probe]

    static func run(setup: DSHIntegrationSetup?, cancellation: LocalAgentTestCancellation,
                    timeout: TimeInterval = 17, signal: SignalSource,
                    verifyPeer: PeerVerifier = verifyDesktopPeer, health: HealthSource? = nil,
                    acceptedEventSockets: [String] = AgentPetPaths.eventSocketPaths) async -> DSHReadinessResult {
        var result = DSHReadinessResult(status: .failed)
        func cancelled() -> DSHReadinessResult { .init(status: .cancelled, checks: result.checks) }
        guard !cancellation.isCancelled else { return cancelled() }
        guard let setup else {
            result.checks.append(.init(key: "application", passed: false)); return result
        }
        // Registration is diagnostic only. A live compatible bridge can be installed/updated
        // independently and must not be blocked by a bundled package or package-manager layout.
        let inspected = await Task.detached(priority: .userInitiated) { () -> (DSHIntegrationSetup.Inspection?, [DSHReadinessResult.Check]) in
            do {
                try setup.validateApplication(); try setup.validateProfile()
                return (try? setup.inspect(), [.init(key: "application", passed: true), .init(key: "profile", passed: true)])
            } catch {
                return (nil, [.init(key: "application", passed: false, detail: error.localizedDescription)])
            }
        }.value
        result.checks = inspected.1
        guard !cancellation.isCancelled else { return cancelled() }
        guard result.checks.allSatisfy(\.passed) else { return result }
        if !setup.desktopIsRunning {
            result.status = inspected.0?.configuration == .absent ? .readyToInstall : .startRequired
            result.checks.append(.init(key: "running", passed: false)); return result
        }
        result.checks.append(.init(key: "running", passed: true))
        let expectedProfile = DSHLiveSignals.profileID(setup.target)
        if let health {
            let probes = await health(setup.target).filter { $0.status.valid && $0.status.profileID == expectedProfile }
            guard !cancellation.isCancelled else { return cancelled() }
            if probes.count > 1 {
                result.status = .endpointUnavailable
                result.checks.append(.init(key: "communication", passed: false, detail: "dsh.health.ambiguous")); return result
            }
            if let probe = probes.first {
                let state = probe.status
                result.checks.append(.init(key: "protocol", passed: state.compatible))
                guard state.compatible else { result.status = .incompatible; return result }
                let connected = state.eventConnected && acceptedEventSockets.contains(state.eventSocket)
                result.checks.append(.init(key: "communication", passed: connected))
                guard connected else { result.status = .endpointUnavailable; return result }
                let pending = state.capabilities.contains("pending.v1") && state.clientCount == 1
                result.checks.append(.init(key: "pending", passed: pending))
                result.checks.append(.init(key: "navigation", passed: state.navigationReady))
                result.checks.append(.init(key: "speech", passed: state.capabilities.contains("speech.v1")))
                result.status = pending && state.navigationReady ? .connected : .limited
                result.evidence = "@agentpet-lite/dsh-bridge " + state.packageVersion + "\nProtocol: 1\nProfile: " + state.profileID
                return result
            }
        }
        let began = Date(), deadline = ProcessInfo.processInfo.systemUptime + max(0, min(timeout, 20))
        let profileID = DSHLiveSignals.profileID(setup.target)
        var receivedUnverifiedSignal = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !cancellation.isCancelled else { return cancelled() }
            guard setup.desktopIsRunning else {
                result.status = .startRequired
                result.checks[result.checks.count - 1] = .init(key: "running", passed: false)
                return result
            }
            if let live = signal(profileID, began), live.receivedAt >= began,
               live.observation.profileID == profileID {
                receivedUnverifiedSignal = true
                if await verifyPeer(live.observation, setup.target) {
                    guard !cancellation.isCancelled else { return cancelled() }
                    result.status = .connected
                    result.checks.append(.init(key: "communication", passed: true))
                    result.evidence = "@agentpet-lite/dsh-bridge\nProfile: \(profileID)\nHost: \(live.observation.hostID)\n\(live.receivedAt.ISO8601Format())"
                    return result
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !cancellation.isCancelled else { return cancelled() }
        result.status = receivedUnverifiedSignal ? .endpointUnavailable : inspected.0?.configuration == .absent ? .readyToInstall : .unconfirmed
        result.checks.append(.init(key: "communication", passed: false))
        return result
    }

    static func discoverHealth(_ target: DSHIntegrationSetup.Target) async -> [DSHBridgeProtocol.Probe] {
        let profile = DSHLiveSignals.profileID(target)
        let probes = await Task.detached { DSHBridgeProtocol.discover(profileID: profile) }.value
        return probes.filter { probe in
            DSHNavigation.processAncestors(of: probe.peerPID).contains { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                      app.bundleIdentifier == "com.deepseek.dsh", let url = app.bundleURL else { return false }
                return url.resolvingSymlinksInPath() == target.application.resolvingSymlinksInPath()
            }
        }
    }

    static func verifyDesktopPeer(_ observation: DSHObservation, _ target: DSHIntegrationSetup.Target) async -> Bool {
        let ancestors = await Task.detached {
            DSHNavigation.probePeer(observation).map { DSHNavigation.processAncestors(of: $0) } ?? []
        }.value
        return ancestors.contains { pid in
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  app.bundleIdentifier == "com.deepseek.dsh", let url = app.bundleURL else { return false }
            return url.resolvingSymlinksInPath() == target.application.resolvingSymlinksInPath()
        }
    }
}
