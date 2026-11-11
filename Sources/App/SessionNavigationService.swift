import AppKit
import AgentPetCore

/// Navigation evidence is deliberately distinct from a real-client page check.
/// A successful deep link plus foreground activation retains existing click semantics.
enum SessionNavigationResult {
    enum Evidence {
        case terminalTarget, deepLinkAcceptedAndForeground, dshConfirmed(DSHObservation)
        case aoProject(AOProjectNavigation.Destination)
        case aoExactSession(String)
        var acknowledgesNativeSession: Bool {
            if case .aoProject = self { return false }
            return true
        }
    }
    case opened(Evidence)
    case failed(String)
    case superseded
}

@MainActor
protocol SessionNavigationBackend: AnyObject {
    func dshBinding(_ session: AgentSession) async -> DSHAntigravityBinding.Lookup
    func openAOProject(_ target: AOProjectNavigation.Target, validate: @escaping @MainActor () -> Bool) async -> AOProjectNavigation.Outcome
    func association(_ session: AgentSession) async -> AionUiMetadata.Lookup
    func selectOpencode(_ session: AgentSession) async -> OpencodeTUINavigation.Result
    func focusTerminal(_ session: AgentSession) async -> TerminalFocus.Result
    func open(_ url: URL, bundleID: String) async -> Bool
    func isFrontmost(bundleID: String) -> Bool
    func selectDSH(_ target: DSHObservation, verifyOnly: Bool) async -> DSHNavigation.Receipt?
    func dshDesktop(peerPID: pid_t) async -> pid_t?
    func activateDSH(_ pid: pid_t, validate: @escaping @MainActor () -> Bool) async -> DSHActivationOutcome
    func isFrontmostDSH(_ pid: pid_t) -> Bool
}

extension SessionNavigationBackend {
    func openAOProject(_ target: AOProjectNavigation.Target, validate: @escaping @MainActor () -> Bool) async -> AOProjectNavigation.Outcome {
        .failed("AO 项目导航不可用；未标记已读")
    }
    func dshBinding(_ session: AgentSession) async -> DSHAntigravityBinding.Lookup { .notFound }
}

@MainActor
final class SystemSessionNavigationBackend: SessionNavigationBackend {
    func openAOProject(_ target: AOProjectNavigation.Target, validate: @escaping @MainActor () -> Bool) async -> AOProjectNavigation.Outcome {
        guard BubbleSettings.shared.aoExperimentActive else {
            return .failed(NSLocalizedString("ao.experiment.disabled", comment: ""))
        }
        return await AOProjectNavigation.open(target, driver: SystemAOProjectNavigationDriver(), validate: {
            BubbleSettings.shared.aoExperimentActive && validate()
        })
    }
    func dshBinding(_ session: AgentSession) async -> DSHAntigravityBinding.Lookup {
        await Task.detached(priority: .userInitiated) { DSHAntigravityBinding.read(sessionID: session.id) }.value
    }
    func association(_ session: AgentSession) async -> AionUiMetadata.Lookup {
        await Task.detached(priority: .userInitiated) { AionUiHostAdapter().association(for: session) }.value
    }
    func selectOpencode(_ session: AgentSession) async -> OpencodeTUINavigation.Result {
        await Task.detached(priority: .userInitiated) {
            OpencodeTUINavigation.select(session)
        }.value
    }
    func focusTerminal(_ session: AgentSession) async -> TerminalFocus.Result {
        await withCheckedContinuation { continuation in
            TerminalFocus.focus(program: session.terminalProgram, tty: session.terminalTTY, focusURL: session.terminalFocusURL) {
                continuation.resume(returning: $0)
            }
        }
    }
    func open(_ url: URL, bundleID: String) async -> Bool {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { app, error in
                continuation.resume(returning: error == nil && app?.bundleIdentifier == bundleID)
            }
        }
    }
    func isFrontmost(bundleID: String) -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }
    func selectDSH(_ target: DSHObservation, verifyOnly: Bool) async -> DSHNavigation.Receipt? {
        await Task.detached(priority: .userInitiated) { DSHNavigation.select(target, verifyOnly: verifyOnly) }.value
    }
    func dshDesktop(peerPID: pid_t) async -> pid_t? {
        let ancestors = await Task.detached(priority: .userInitiated) { DSHNavigation.processAncestors(of: peerPID) }.value
        return ancestors.compactMap { NSRunningApplication(processIdentifier: $0) }
            .first { $0.bundleIdentifier == "com.deepseek.dsh" && !$0.isTerminated }?.processIdentifier
    }
    private let dshActivator = DSHActivator()

    func activateDSH(_ pid: pid_t, validate: @escaping @MainActor () -> Bool) async -> DSHActivationOutcome {
        await dshActivator.activate(pid: pid, validate: validate)
    }
    func isFrontmostDSH(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "com.deepseek.dsh", !app.isTerminated else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
}

/// Owns cancellable navigation attempts; Store remains the authority for receipts.
/// All callbacks carry the clicked value and an attempt token, never a fresh message.
@MainActor
final class SessionNavigationService {
    enum Intent { case session, aoProject }
    private struct Attempt {
        let token: UUID
        let clicked: AgentSession
        let task: Task<Void, Never>
        /// Current AO-bound rows re-verify the AO association throughout the
        /// native route. Historical/conflicted rows use a native-only route
        /// and never claim AO precision.
        let requireAOContext: Bool
    }
    private var attempts: [String: Attempt] = [:]
    private let backend: any SessionNavigationBackend
    private let session: (String) -> AgentSession?
    private let aoProjectObservations: () -> [AOHostObservation]
    private let dshBridgeTarget: (DSHAntigravityBinding.Record) -> DSHObservation?
    private let dshTarget: (AgentSession) -> DSHObservation?
    private let updateAssociation: (AgentSession, AionUiMetadata.Record) -> Void
    private let completion: (AgentSession, SessionNavigationResult) -> Void
    init(backend: any SessionNavigationBackend = SystemSessionNavigationBackend(),
         session: @escaping (String) -> AgentSession?,
         dshTarget: @escaping (AgentSession) -> DSHObservation?,
         dshBridgeTarget: @escaping (DSHAntigravityBinding.Record) -> DSHObservation? = { _ in nil },
         aoProjectObservations: @escaping () -> [AOHostObservation] = { [] },
         updateAssociation: @escaping (AgentSession, AionUiMetadata.Record) -> Void,
         completion: @escaping (AgentSession, SessionNavigationResult) -> Void) {
        self.backend = backend; self.session = session; self.dshTarget = dshTarget
        self.dshBridgeTarget = dshBridgeTarget
        self.aoProjectObservations = aoProjectObservations
        self.updateAssociation = updateAssociation; self.completion = completion
    }
    @discardableResult
    func navigate(_ clicked: AgentSession, intent: Intent = .session) -> Bool {
        if let old = attempts[clicked.id], old.clicked.createdAt == clicked.createdAt { return false }
        attempts.removeValue(forKey: clicked.id)?.task.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.route(clicked, token: token, intent: intent)
            guard self.attempts[clicked.id]?.token == token else { return }
            self.attempts.removeValue(forKey: clicked.id)
            self.completion(clicked, self.sameInstance(clicked) ? result : .superseded)
        }
        let requireAOContext = clicked.isAOHostSession
            && clicked.aoBinding?.isCurrent == true
            && !clicked.isAOPlaceholder
            && clicked.hostTeamScope?.host != .agentOrchestrator
        attempts[clicked.id] = Attempt(token: token, clicked: clicked, task: task,
                                       requireAOContext: requireAOContext)
        return true
    }
    func retain(_ ids: Set<String>) {
        for id in attempts.keys where !ids.contains(id) { attempts.removeValue(forKey: id)?.task.cancel() }
    }
    func stop() { for attempt in attempts.values { attempt.task.cancel() }; attempts.removeAll() }
    private func sameInstance(_ clicked: AgentSession) -> Bool {
        guard let current = session(clicked.id) else { return false }
        return current.createdAt == clicked.createdAt && current.agentKind == clicked.agentKind
    }
    private func valid(_ clicked: AgentSession, _ token: UUID) -> Bool {
        guard !Task.isCancelled, let attempt = attempts[clicked.id],
              attempt.token == token, sameInstance(clicked) else { return false }
        return attempt.requireAOContext ? aoContextMatches(clicked) : true
    }
    /// A native route may only proceed while the AO association still names
    /// the same AO session and daemon generation. This does not make the native
    /// page an AO precise target.
    private func aoContextMatches(_ clicked: AgentSession) -> Bool {
        guard clicked.isAOHostSession else { return true }
        guard let current = session(clicked.id), current.createdAt == clicked.createdAt,
              current.agentKind == clicked.agentKind,
              current.aoBinding?.sessionID == clicked.aoBinding?.sessionID,
              current.aoBinding?.isCurrent == true else { return false }
        return current.aoObservation?.sessionID == clicked.aoObservation?.sessionID
            && current.aoObservation?.instanceID == clicked.aoObservation?.instanceID
    }
    private func aoNativePreciseTarget(_ clicked: AgentSession) -> Bool {
        guard clicked.isAOHostSession, !clicked.isAOPlaceholder else { return false }
        guard clicked.hostTeamScope?.host != .agentOrchestrator else { return false }
        guard clicked.aoBinding?.isCurrent == true, let observation = clicked.aoObservation,
              observation.available, clicked.aoObservationIsCurrent(at: Date()) else { return false }
        return aoContextMatches(clicked)
    }
    private func route(_ clicked: AgentSession, token: UUID, intent: Intent) async -> SessionNavigationResult {
        guard valid(clicked, token) else { return .superseded }
        if intent == .aoProject {
            guard clicked.isAOHostSession,
                  clicked.aoObservation?.projectID != AOHostMapping.standaloneProjectID else {
                return .failed(NSLocalizedString("ao.navigation.unconfirmed", comment: ""))
            }
            return await openAO(clicked, token: token, projectEntry: true)
        }
        if clicked.isAOPlaceholder
            || (clicked.isAOHostSession && (clicked.hostTeamScope?.host == .agentOrchestrator
                || (clicked.aoBinding?.isCurrent == true && clicked.aoObservation?.projectID == AOHostMapping.standaloneProjectID))) {
            // AO-only rows and AO Team targets have no precise external route.
            return await openAO(clicked, token: token)
        }
        if clicked.isAOHostSession {
            if clicked.aoBinding?.isCurrent == true {
                // A current AO-bound native row keeps its exact native route
                // only while the AO association and instance still verify.
                guard aoNativePreciseTarget(clicked) else {
                    return await openAO(clicked, token: token)
                }
            }
            // Historical/conflicted native rows may still open their own
            // exact native target; this is not an AO navigation success.
            if clicked.agentKind == .dsh { return await openDSH(clicked, token: token) }
            return await nativeRoute(clicked, token: token)
        }
        if clicked.agentKind == .dsh { return await openDSH(clicked, token: token) }
        return await nativeRoute(clicked, token: token)
    }
    /// Existing supported native exact routes. This is entered only for an
    /// ordinary native row or an AO-bound row whose exact native target and AO
    /// context both still verify.
    private func nativeRoute(_ clicked: AgentSession, token: UUID) async -> SessionNavigationResult {
        guard valid(clicked, token) else { return .superseded }
        let lookup = await backend.association(clicked)
        guard valid(clicked, token) else { return .superseded }
        switch lookup {
        case .matched(let record):
            updateAssociation(clicked, record)
            guard record.conversation.nativeSessionID == clicked.id, record.conversation.agentKind == clicked.agentKind else { return .failed("找不到对应 AionUi 会话或应用") }
            // A Team-scoped row (stored or freshly marked) always targets the
            // Team view, and only after fresh verification. An unverified or
            // stale identity fails closed instead of opening one member's page.
            let wasTeam = clicked.aionUiTeamScope != nil
            let url: URL?
            if wasTeam || record.conversation.teamID != nil {
                guard record.conversation.teamRole != nil, let teamURL = record.conversation.teamURL else {
                    return .failed("团队关联暂时无法确认，请在 AionUi 中重试")
                }
                url = teamURL
            } else {
                url = record.conversation.url
            }
            guard let url else { return .failed("找不到对应 AionUi 会话或应用") }
            return await openLink(url, bundleID: "com.aionui.app", clicked: clicked, token: token,
                failure: "无法打开对应 AionUi 会话，请重试", background: "已请求打开 AionUi；客户端尚未切到前台，请重试")
        case .ambiguous: return .failed("AionUi 会话关联不唯一；未打开终端，请重试")
        case .unavailable where clicked.validAionUiConversation != nil,
             .notFound where clicked.validAionUiConversation != nil:
            return .failed("无法确认对应 AionUi 会话，请重试")
        default: break
        }
        if clicked.agentKind == .antigravity {
            let binding = await backend.dshBinding(clicked)
            guard valid(clicked, token) else { return .superseded }
            switch binding {
            case .matched(let record): return await openDSH(clicked, token: token, binding: record)
            case .ambiguous: return .failed("DSH agy 会话关联不唯一，请在 DSH 中确认")
            case .unavailable: return .failed("无法读取 DSH agy 会话关联，请重试")
            case .notFound: break
            }
        }
        if clicked.agentKind == .codex && clicked.codexDesktop {
            guard let url = CodexMetadata.threadURL(sessionID: clicked.id) else { return .failed("无法打开会话，请重试") }
            return await openLink(url, bundleID: "com.openai.codex", clicked: clicked, token: token,
                failure: "无法打开会话，请重试", background: "已请求打开会话；客户端尚未切到前台，请重试")
        }
        if clicked.agentKind == .opencode {
            let selection = await backend.selectOpencode(clicked)
            guard valid(clicked, token) else { return .superseded }
            let terminal: TerminalInfo.Captured
            switch selection {
            case .selected(let selected): terminal = selected
            case .unsupported: return .failed(NSLocalizedString("navigation.opencode.unsupported", comment: ""))
            case .unavailable: return .failed(NSLocalizedString("navigation.opencode.unavailable", comment: ""))
            case .ambiguous: return .failed(NSLocalizedString("navigation.opencode.ambiguous", comment: ""))
            case .failed: return .failed(NSLocalizedString("navigation.opencode.failed", comment: ""))
            }
            var target = clicked
            target.terminalProgram = terminal.program; target.terminalTTY = terminal.tty; target.terminalFocusURL = terminal.focusURL
            let focused = await backend.focusTerminal(target)
            return focused == .openedTarget ? .opened(.terminalTarget) : .failed("会话已选择；无法定位对应终端标签页")
        }
        switch await backend.focusTerminal(clicked) {
        case .openedTarget: return .opened(.terminalTarget)
        case .activatedApplication: return .failed("已打开终端；无法定位对应会话")
        case .failed: return .failed("无法打开对应会话，请重试")
        }
    }
    private func openLink(_ url: URL, bundleID: String, clicked: AgentSession, token: UUID,
                          failure: String, background: String) async -> SessionNavigationResult {
        guard await backend.open(url, bundleID: bundleID) else { return .failed(failure) }
        for _ in 0..<12 {
            guard valid(clicked, token) else { return .superseded }
            if backend.isFrontmost(bundleID: bundleID) { return .opened(.deepLinkAcceptedAndForeground) }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return .superseded }
        }
        return .failed(background)
    }
    /// Unread native results request their exact AO page. Other project clicks
    /// retain the orchestrator/board entry; neither can acknowledge a sibling.
    private func openAO(_ clicked: AgentSession, token: UUID, projectEntry: Bool = false) async -> SessionNavigationResult {
        guard valid(clicked, token), let binding = clicked.aoBinding,
              let observation = clicked.aoObservation else {
            return .failed("AO 尚未确认该会话；未标记已读，请在 Agent Orchestrator 中打开对应会话")
        }
        guard clicked.aoObservationIsCurrent(at: Date()) else {
            return .failed("AO 会话关联已过期；未标记已读，请在 Agent Orchestrator 中重新确认")
        }
        guard let current = session(clicked.id), current.createdAt == clicked.createdAt,
              current.aoBinding?.sessionID == binding.sessionID,
              current.aoObservation?.sessionID == observation.sessionID,
              current.aoObservation?.instanceID == observation.instanceID else {
            return .superseded
        }
        let target = AOProjectNavigation.Target(projectID: observation.projectID,
            projectName: observation.projectName ?? observation.projectID,
            orchestratorIDs: Set(aoProjectObservations().compactMap { host in
                let age = Date().timeIntervalSince(host.observedAt)
                guard host.available, age >= 0, age <= 60,
                      host.instanceID == observation.instanceID, host.projectID == observation.projectID,
                      host.role == .orchestrator, !host.isTerminated, host.activity != .exited else { return nil }
                return host.sessionID
            }), instanceID: observation.instanceID,
            sessionID: observation.projectID == AOHostMapping.standaloneProjectID
                || (!projectEntry && !clicked.isAOPlaceholder && !clicked.isStopped && clicked.notificationVersion > clicked.readThroughVersion)
                ? observation.sessionID : nil)
        let validateAO: @MainActor () -> Bool = { [weak self] in
            guard let self, self.valid(clicked, token), let current = self.session(clicked.id),
                  current.aoObservationIsCurrent(at: Date()),
                  current.aoObservation?.projectID == observation.projectID,
                  current.aoObservation?.instanceID == observation.instanceID,
                  current.aoBinding?.sessionID == binding.sessionID else { return false }
            return true
        }
        let outcome = await backend.openAOProject(target, validate: validateAO)
        guard validateAO() else { return .superseded }
        switch outcome {
        case .opened(let destination):
            let exactID: String?
            switch destination {
            case .orchestrator(let id), .session(let id): exactID = id
            case .board: exactID = nil
            }
            if let requested = target.sessionID, exactID != requested {
                return .failed(NSLocalizedString("ao.navigation.unconfirmed", comment: ""))
            }
            // Only this clicked native result can be read, and only when the
            // confirmed page names its exact AO owner. A board/other leader
            // never acknowledges members or independent AO human requests.
            if !clicked.isAOPlaceholder, exactID == binding.sessionID {
                return .opened(.aoExactSession(binding.sessionID))
            }
            return .opened(.aoProject(destination))
        case .failed(let message): return .failed(message)
        case .superseded: return .superseded
        }
    }

    private func openDSH(_ clicked: AgentSession, token: UUID, binding: DSHAntigravityBinding.Record? = nil) async -> SessionNavigationResult {
        guard let target = binding.map({ dshBridgeTarget($0) }) ?? dshTarget(clicked) else { return .failed("DSH 实例已断开，请在原客户端继续会话后重试") }
        guard let receipt = await backend.selectDSH(target, verifyOnly: false) else {
            return .failed("DSH 会话选择未确认；请检查原桌面实例或窗口")
        }
        guard valid(clicked, token) else { return .superseded }
        guard let pid = await backend.dshDesktop(peerPID: receipt.peerPID) else {
            return .failed("DSH 会话已选中，但无法确认对应桌面进程")
        }
        guard valid(clicked, token), validDSHTarget(clicked, target, binding: binding) else { return .superseded }
        // The activator re-checks this closure after its bounded wait; the
        // navigation token/target must still be current before any yield or
        // target activation (Task cancellation alone is not enough).
        let activation = await backend.activateDSH(pid) { [weak self] in
            guard let self else { return false }
            return self.valid(clicked, token) && self.validDSHTarget(clicked, target, binding: binding)
        }
        guard valid(clicked, token), validDSHTarget(clicked, target, binding: binding) else { return .superseded }
        switch activation {
        case .activated:
            break
        case .cancelled, .superseded:
            return .superseded
        case .appMissing, .bundleMismatch, .terminated:
            return .failed("DSH 会话已选中，但已无法确认对应桌面进程")
        case .requestRejected, .selfActivationFailed, .yieldRejected:
            return .failed("DSH 会话已选中，但系统未接受窗口切换，请重试")
        }
        for _ in 0..<12 {
            guard valid(clicked, token) else { return .superseded }
            if backend.isFrontmostDSH(pid) {
                let confirmation = await backend.selectDSH(target, verifyOnly: true)
                guard valid(clicked, token), validDSHTarget(clicked, target, binding: binding),
                      confirmation?.peerPID == receipt.peerPID, confirmation?.clientID == receipt.clientID,
                      confirmation?.generation == receipt.generation, backend.isFrontmostDSH(pid) else {
                    return .failed("无法打开会话，请重试")
                }
                if let binding {
                    guard await backend.dshBinding(clicked) == .matched(binding), valid(clicked, token),
                          validDSHTarget(clicked, target, binding: binding), backend.isFrontmostDSH(pid) else {
                        return .failed("DSH agy 会话关联已变化，请重试")
                    }
                }
                return .opened(.dshConfirmed(target))
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return .superseded }
        }
        return .failed("DSH 已选中会话，但未能确认对应桌面到前台")
    }
    private func validDSHTarget(_ clicked: AgentSession, _ target: DSHObservation, binding: DSHAntigravityBinding.Record?) -> Bool {
        guard let current = session(clicked.id), current.createdAt == clicked.createdAt,
              current.dsh?.turn == clicked.dsh?.turn, let latest = binding.map({ dshBridgeTarget($0) }) ?? dshTarget(current) else { return false }
        return latest.hostID == target.hostID && latest.navigationSocket == target.navigationSocket
    }
}
