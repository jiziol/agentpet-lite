import Foundation
import AppKit
import AgentPetCore
import os

/// Owns the live session state inside the running app: starts the socket
/// server, drains any queued events on launch, applies incoming events and
/// prunes stale ones, and publishes a display-ordered list to the UI.
///
/// All `SessionStore` access is confined to the main actor.
@MainActor
final class AppDaemon: ObservableObject {
    static let shared = AppDaemon()
    private static let transportLog = Logger(subsystem: AgentPetPaths.bundleIdentifier, category: "event-transport")

    @Published private(set) var sessions: [AgentSession] = []
    private(set) var dshLiveSignals = DSHLiveSignals()

    private let store: SessionStore = {
        let s = SessionStore(coalescesSnapshotWrites: true)
        s.archiveStore = SessionArchiveStore.shared
        s.persistenceURL = URL(fileURLWithPath: AgentPetPaths.baseDir + "/codex-sessions-v1.json")
        return s
    }()
    private let server = EventSocketServer(path: AgentPetPaths.socketPath)
    private let localCompatibilityServer = AgentPetPaths.migratedLocalDir.map {
        EventSocketServer(path: $0 + "/agentpet.sock")
    }
    private var pruneTimer: Timer?
    private var readResultTimer: Timer?
    @Published private(set) var navigationMessages: [String: String] = [:]
    private var isRunning = false
    private var endedDismissal = EndedTaskDismissalState(data: UserDefaults.standard.data(forKey: EndedTaskDismissalState.defaultsKey))
    private let speechInbox = OpencodeSpeechInbox()
    private var opencodeSpeech = OpencodeSpeechState()
    private let dshSpeechInbox = DSHSpeechInbox()
    private var dshSpeech = DSHSpeechState()
    private lazy var metadata = SessionMetadataCoordinator(current: { [weak self] in self?.store.session(id: $0) })
    /// Independent AO host projection; dormant when AO is not installed or its
    /// run file is absent.
    private lazy var aoHost = AOHostObserver(
        applySnapshot: { [weak self] snapshot, now in
            self?.store.applyAOSnapshot(snapshot, now: now) ?? []
        },
        markUnavailable: { [weak self] now in
            self?.store.markAOUnavailable(now: now) ?? []
        },
        notify: { [weak self] before, after in
            guard before != nil else { return }
            self?.notifyIfNeeded(before: before?.state, session: after)
        },
        refreshUI: { [weak self] in self?.refresh() })
    private lazy var aoSessionReading = AOSessionReadingObserver(
        enabled: { BubbleSettings.shared.aoExperimentActive },
        sessions: { [weak self] in self?.store.sessions ?? [] },
        markRead: { [weak self] native, at in self?.store.markOpened(native, at: at) ?? false },
        refreshUI: { [weak self] in self?.refresh() })
    /// Bounded invalidation of cached Team verifications (see
    /// `TeamVerificationWatchdog`).
    private var teamVerificationWatchdog = TeamVerificationWatchdog()
    private lazy var observation = SessionObservationCoordinator(
        current: { [weak self] in self?.store.session(id: $0) },
        receive: { [weak self] in self?.consumeObservation($0) },
        human: { [weak self] id, kind, change, at in self?.consumeHuman(id, kind: kind, change: change, at: at) },
        message: { [weak self] id, message in
            guard let self, self.isRunning, BubbleSettings.shared.agentMessagesEnabled,
                  let session = self.store.session(id: id), !session.isCodexInternalTask else { return }
            PetController.shared.showProgress(message, session: session)
        }, agyMessage: { [weak self] id, message in
            guard let self, self.isRunning, BubbleSettings.shared.agentMessagesEnabled,
                  let session = self.store.session(id: id), !session.isDSHBackend, message.boundary.matches(session) else { return }
            PetController.shared.showProgress(message, session: session)
        })

    func applyPetBubbleSetting(enabled: Bool) {
        guard isRunning else { return }
        observation.setMessagesEnabled(enabled)
        speechInbox.clear()
        opencodeSpeech.reset(enabled: enabled, now: Date())
        dshSpeechInbox.clear(); dshSpeech.reset(enabled: enabled, now: Date())
        PetController.shared.clearProgress()

    }

    private func consumeHuman(_ id: String, kind: AgentKind, change: HumanIntervention, at: Date) {
        guard isRunning, store.session(id: id)?.agentKind == kind else { return }
        let before = store.session(id: id)?.state
        var event = AgentEvent(sessionId: id, agentKind: kind, eventName: "HumanInput", timestamp: at)
        event.humanIntervention = change
        guard let session = store.apply(event, now: at) else { return }
        notifyIfNeeded(before: before, session: session)
        refresh()
    }

    private func consumeObservation(_ value: SessionObservation) {
        guard isRunning else { return }
        switch value.payload {
        case .aionUiCancellation(let signal):
            guard let stopped = store.apply(value) else { return }
            var event = AgentEvent(sessionId: signal.conversation.nativeSessionID, agentKind: .antigravity,
                eventName: "AionUiLogCancellation", timestamp: signal.timestamp)
            event.turnResult = .cancelled
            AntigravityEventTrace.record(event, state: stopped.state)
        case .antigravityLog(let signal):
            guard let stopped = store.apply(value) else { return }
            var event = AgentEvent(sessionId: signal.sessionID, agentKind: .antigravity,
                eventName: "NativeLogCancellation", timestamp: signal.timestamp)
            event.turnResult = .cancelled
            AntigravityEventTrace.record(event, state: stopped.state)
        case .antigravitySQLite:
            guard store.apply(value) != nil else { return }
        case .codexLifecycle(let id, let event):
            let prior = store.session(id: id), before = prior?.state
            guard let session = store.apply(value) else { return }
            let trace = AgentEvent(sessionId: id, agentKind: .codex,
                eventName: "Native:" + (event.result?.rawValue ?? "started"), timestamp: event.timestamp)
            CodexEventTrace.record(trace, before: before, after: session.state)
            let notificationBefore: AgentState? = session.state == .done && event.result != nil && prior?.codexTurnResult == nil ? .working : before
            notifyIfNeeded(before: notificationBefore, session: session)
        case .hook: return
        }
        refresh()
    }

    /// Called only after AppKit has accepted quitting, so a cancelled failed
    /// snapshot flush leaves live observation and navigation intact.
    func stop() {
        isRunning = false
        speechInbox.clear(); opencodeSpeech.reset(enabled: false, now: Date())
        dshSpeechInbox.clear(); dshSpeech.reset(enabled: false, now: Date())
        pruneTimer?.invalidate(); pruneTimer = nil
        readResultTimer?.invalidate(); readResultTimer = nil
        server.stop(); localCompatibilityServer?.stop()
        navigation.stop(); metadata.stop(); observation.stop(); aoHost.stop(); aoSessionReading.stop()
        PetController.shared.clearProgress()
    }

    func flushSnapshots() -> SnapshotSaveStatus { store.flushSnapshots() }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        var fileLimit = rlimit()
        getrlimit(RLIMIT_NOFILE, &fileLimit)
        Self.transportLog.notice("daemon starting nofile=\(fileLimit.rlim_cur, privacy: .public)")
        opencodeSpeech.reset(enabled: BubbleSettings.shared.agentMessagesEnabled, now: Date())
        dshSpeech.reset(enabled: BubbleSettings.shared.agentMessagesEnabled, now: Date())
        // The approval reply can race the CLI closing its socket — a stray
        // write must return EPIPE, not SIGPIPE-kill the whole app.
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(
            atPath: AgentPetPaths.baseDir, withIntermediateDirectories: true
        )

        // Reserve event listeners before restored sessions attach file watchers.
        let inbox = speechInbox
        let dshInbox = dshSpeechInbox
        for (index, endpoint) in ([server] + [localCompatibilityServer].compactMap({ $0 })).enumerated() {
            do {
                try endpoint.start(onVisibleMessage: { [weak self] message in
                    guard inbox.offer(message) else { return }
                    Task { @MainActor [weak self] in self?.consumeOpencodeSpeech() }
                }, onDSHVisibleMessage: { [weak self] message in
                    guard dshInbox.offer(message) else { return }
                    Task { @MainActor [weak self] in self?.consumeDSHSpeech() }
                }) { event in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        self.dshLiveSignals.receive(event, at: Date())
                        self.ingest(event)
                    }
                }
                Self.transportLog.notice("listener started role=\(index, privacy: .public)")
            } catch {
                getrlimit(RLIMIT_NOFILE, &fileLimit)
                Self.transportLog.error("listener failed role=\(index, privacy: .public) error=\(String(describing: error), privacy: .public) nofile=\(fileLimit.rlim_cur, privacy: .public)")
            }
        }

        observation.setMessagesEnabled(BubbleSettings.shared.agentMessagesEnabled)

        configureReadResultRetention()
        store.restoreCodexSessions()
        if let source = AgentPetPaths.migratedLocalDir {
            LocalMigrationIdentity.removeCopiedQueueDuplicates(destination: AgentPetPaths.baseDir, source: source)
        }
        // Replay queued events with their original timestamps (not "now"), so
        // sessions that ended while the app was closed look stale and get
        // pruned immediately instead of resurrecting as "working".
        for directory in [AgentPetPaths.queueDir] + [AgentPetPaths.migratedLocalDir.map { $0 + "/queue" }].compactMap({ $0 }) {
            EventSocketServer.drainQueue(directory: directory) { [store] event in
                store.apply(event, now: event.timestamp)
            }
        }
        // Queued events predate this launch. Keep their native rows/receipts,
        // but do not let an old AO claim become the current host generation.
        _ = store.clearAOHostClaims()
        store.reconcileOpencodeLiveness(now: Date())
        store.prune(now: Date())
        aoHost.start()
        aoSessionReading.start()
        for session in store.sessions where session.agentKind == .codex {
            var event = AgentEvent(sessionId: session.id, agentKind: .codex, eventName: "Restore", timestamp: Date())
            event.codexHome = session.codexHome
            resolveCodexMetadata(for: event)
        }
        refresh()

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.prune() }
        }
        // NativeUsageProbe owns Codex quota reminders independently of idle speech.
    }

    private func consumeOpencodeSpeech() {
        let messages = speechInbox.take()
        guard isRunning, BubbleSettings.shared.agentMessagesEnabled else { return }
        opencodeSpeech.receive(messages, now: Date())
        deliverOpencodeSpeech()
    }

    private func deliverOpencodeSpeech() {
        for (message, session) in opencodeSpeech.drain(sessions: store.sorted, now: Date()) {
            PetController.shared.showProgress(message, session: session)
        }
    }

    private func consumeDSHSpeech() {
        let messages = dshSpeechInbox.take()
        guard isRunning, BubbleSettings.shared.agentMessagesEnabled else { return }
        dshSpeech.receive(messages, now: Date()); deliverDSHSpeech()
    }

    private func deliverDSHSpeech() {
        for (message, session) in dshSpeech.drain(sessions: store.sorted, now: Date()) {
            PetController.shared.showProgress(message, session: session)
        }
    }

    /// Clears the tracked sessions (e.g. after disconnecting an integration).
    func clearSessions() {
        store.clear()
        speechInbox.clear(); opencodeSpeech.reset(enabled: BubbleSettings.shared.agentMessagesEnabled, now: Date())
        dshSpeechInbox.clear(); dshSpeech.reset(enabled: BubbleSettings.shared.agentMessagesEnabled, now: Date())
        refresh()
    }

    /// Clears ended results from presentation without discarding active source
    /// state or inventing a successful navigation/read receipt.
    func clearEndedSessions(ids: Set<String>? = nil) {
        let selected = store.sorted.filter { ids == nil || ids!.contains($0.id) }
        endedDismissal.dismiss(selected, now: Date())
        saveEndedDismissal()
        refresh()
    }

    private func saveEndedDismissal() {
        if let data = endedDismissal.encoded() {
            UserDefaults.standard.set(data, forKey: EndedTaskDismissalState.defaultsKey)
        }
    }

    /// Dismisses a single session (e.g. a stuck agent).
    func removeSession(_ id: String) {
        store.remove(id: id)
        refresh()
    }

    /// Resolves a pending approval from the bubble UI: writes the decision to
    /// the hook and optimistically clears the pending state in the store.
    func resolveApproval(sessionId: String, requestId: String, decision: ApprovalDecision) {
        _ = PendingApprovalRegistry.shared.resolve(requestId: requestId, decision: decision)
        if store.resolveApproval(id: sessionId, requestId: requestId) {
            refresh()
        }
    }

    private lazy var navigation = SessionNavigationService(
        session: { [weak self] in self?.store.session(id: $0) },
        dshTarget: { [weak self] in self?.store.dshNavigationTarget(for: $0, now: Date()) },
        dshBridgeTarget: { [weak self] in
            self?.store.dshNavigationTarget(profileID: $0.profileID, nativeSessionID: $0.nativeSessionID, now: Date())
        },
        aoProjectObservations: { [weak self] in self?.store.aoHostObservations ?? [] },
        updateAssociation: { [weak self] clicked, record in
            _ = self?.store.updateAionUiMetadata(id: clicked.id, createdAt: clicked.createdAt, record: record)
        }, completion: { [weak self] clicked, result in self?.completeNavigation(clicked, result: result) })

    func focusTerminal(sessionId: String, intent: SessionNavigationService.Intent = .session) {
        guard let clicked = store.session(id: sessionId), navigation.navigate(clicked, intent: intent) else { return }
        navigationMessages[sessionId] = "正在打开会话…"
    }

    /// A local acknowledgement of the AO fact displayed in the bubble. It does
    /// not open a page, approve a request, or acknowledge a native turn.
    func acknowledgeAO(_ receipt: AOAttentionReceipt) {
        _ = store.acknowledgeAO(receipt, at: Date())
        refresh()
    }

    private func completeNavigation(_ clicked: AgentSession, result: SessionNavigationResult) {
        switch result {
        case .opened(let evidence):
            if case .dshConfirmed(let target) = evidence, clicked.agentKind == .dsh {
                _ = store.markDSHOpened(clicked, target: target, at: Date())
            } else if evidence.acknowledgesNativeSession {
                _ = store.markOpened(clicked, at: Date())
            }
            navigationMessages.removeValue(forKey: clicked.id)
        case .failed(let message): navigationMessages[clicked.id] = message
        case .superseded: navigationMessages.removeValue(forKey: clicked.id)
        }
        refresh()
    }

    private func resolveDSHAntigravityBackend(for session: AgentSession) {
        guard session.agentKind == .antigravity, session.antigravityFromDSH == nil,
              session.terminalProgram == nil, session.terminalTTY == nil,
              session.validAionUiConversation == nil else { return }
        metadata.read(session, purpose: "dsh-agy-backend", interval: 10, load: {
            DSHAntigravityBinding.read(sessionID: session.id)
        }, apply: { [weak self] binding in
            guard let self, case .matched = binding,
                  self.store.markAntigravityDSHBackend(expected: session) else { return }
            self.refresh()
        })
    }

    private func resolveAionUiMetadata(for session: AgentSession) {
        guard !session.isAOPlaceholder, !session.isDSHBackend else { return }
        if session.agentKind == .opencode, !session.isOpencodeSubagent,
           session.validAionUiConversation != nil, session.state == .working,
           let turnID = session.opencodeTurnID, Date().timeIntervalSince(session.updatedAt) >= 2 {
            metadata.read(session, purpose: "opencode-completion", interval: 5, load: {
                OpencodeCompletedTurn.read(sessionID: session.id, turnID: turnID)
            }, apply: { [weak self] record in
                guard let self, let completed = self.store.reconcileOpencodeCompletion(
                    expected: session, record: record, now: Date()) else { return }
                self.notifyIfNeeded(before: .working, session: completed)
                self.refresh()
            })
        }
        if session.agentKind == .opencode, !session.isOpencodeSubagent {
            metadata.read(session, purpose: "opencode-parent", interval: 30, load: {
                OpencodeSessionMetadata.parentID(sessionID: session.id)
            }, apply: { [weak self] parent in
                guard let self, self.store.updateOpencodeParent(id: session.id, createdAt: session.createdAt, parentID: parent) else { return }
                self.refresh()
            })
        }
        guard !session.isOpencodeSubagent else { return }
        guard [.codex, .antigravity, .opencode, .pi].contains(session.agentKind) else { return }
        metadata.read(session, purpose: "aionui", interval: 2, load: {
            // The host adapter keeps the exact-ID re-check: a suspended ACP
            // runtime that dropped its native anchor still resolves, so only a
            // real removal reaches the bounded invalidation below.
            AionUiHostAdapter().association(for: session)
        }, apply: { [weak self] lookup in
            guard let self else { return }
            // Reject a result that no longer belongs to the identity this check
            // was requested for (a navigation update, a replacement or a lapse
            // may have changed it while the lookup was in flight).
            guard let current = self.store.session(id: session.id),
                  AionUiAssociationToken(session).matches(current) else { return }
            self.applyAionUiAssociation(lookup, for: current)
        })
    }

    /// Applies one host association result. A matched record is applied (and
    /// stamps the live verification) as before; an unverifiable result drops the
    /// cached verification immediately, and after the bounded grace window also
    /// drops the verified role while keeping the raw Team mark. A stale cached
    /// result is therefore never presented as the Team's current state, and a
    /// later successful re-check restores everything.
    private func applyAionUiAssociation(_ lookup: AionUiMetadata.Lookup, for session: AgentSession) {
        let now = Date()
        let action = AionUiVerificationPolicy.action(for: lookup, session: session, now: now,
                                                     watchdog: &teamVerificationWatchdog)
        switch action {
        case .ignore:
            return
        case .apply(let record):
            guard AionUiVerificationApplier.apply(record, for: session, in: store, verifiedAt: now) else { return }
            refresh()
        case .invalidate(let clearRole):
            guard store.clearAionUiVerification(id: session.id, createdAt: session.createdAt,
                                                clearRole: clearRole) else { return }
            refresh()
        }
    }

    private func ingest(_ event: AgentEvent) {
        guard isRunning else { return }
        guard !RetiredAgentRegistry.ignores(event.agentKind, rawName: event.agentName) else { return }
        // Internal automatic approval review is not an unanswered human prompt.
        // Inspect only native policy metadata before publishing this no-ID Hook.
        if event.agentKind == .codex, let turnID = event.codexPermissionTurnID,
           event.humanIntervention == nil, event.approvalRequestId == nil {
            let home = event.codexHome ?? CodexMetadata.defaultHome
            metadata.reviewQueue.async { [weak self] in
                let mode = CodexMetadata.read(sessionID: event.sessionId, home: home)?.rolloutPath.flatMap { path in
                    CodexReviewMode.read(path: path, sessionID: event.sessionId, turnID: turnID, at: event.timestamp)
                }
                let reviewed = CodexReviewMode.reviewedPermission(event, mode: mode)
                Task { @MainActor [weak self] in self?.ingest(reviewed) }
            }
            return
        }
        let before = store.session(id: event.sessionId)?.state
        guard let updated = store.apply(event, now: Date()) else {
            if event.agentKind == .codex { resolveCodexMetadata(for: event) }
            feedSubagentTokens(for: event)
            refresh()
            return
        }
        CodexEventTrace.record(event, before: before, after: updated.state)
        AntigravityEventTrace.record(event, state: updated.state)
        resolveTitle(for: event)
        resolveModel(for: event)
        feedLiveTokens(for: event)

        // Native request identities determine waiting. Stop still collects
        // usage, without guessing a dialog from assistant prose.
        if event.agentKind == .claude, event.eventName == "Stop", updated.state == .done {
            finishClaudeTurn(event: event, before: before, session: updated)
        } else if !(event.agentKind == .codex && updated.state == .done && updated.codexTurnResult == nil) {
            // Wait for native result before calling a Codex stop successful.
            notifyIfNeeded(before: before, session: updated)
        }
        refresh()
    }

    /// Resolves which pet should receive XP for a given project path.
    /// Split ON  → the project's configured pet (or the selected pet if unconfigured).
    /// Split OFF → always the selected pet (identical to today's behaviour).
    func careTarget(forProject project: String?) -> String? {
        guard PetController.shared.splitPet else { return PetController.shared.selectedPetID }
        return ProjectPetSettings.shared.petID(forProject: project)
            ?? PetController.shared.selectedPetID
    }

    /// Tokens appear in the transcript while Claude is still working, so the
    /// pet eats live on tool events instead of waiting for `Stop`. Throttled
    /// per session; reads are incremental (offset-based), so the `Stop` path
    /// picking up the remainder never double-counts.
    private var lastLiveFeed: [String: Date] = [:]
    private var codexPathBySession: [String: String] = [:]
    private static let liveFeedInterval: TimeInterval = 10

    private func feedLiveTokens(for event: AgentEvent) {
        switch event.agentKind {
        case .claude:
            // Claude's Stop is handled by refineDoneIfQuestion (it feeds the remainder).
            guard event.eventName != "Stop" else { return }
            let path: String? = event.transcriptPath
                ?? event.project.map { TranscriptReader.inferredPath(sessionId: event.sessionId, cwd: $0) }
            guard let path else { return }
            let now = Date()
            if let last = lastLiveFeed[event.sessionId],
               now.timeIntervalSince(last) < Self.liveFeedInterval { return }
            lastLiveFeed[event.sessionId] = now
            let project = event.project
            Task.detached(priority: .utility) {
                guard let delta = TranscriptReader.newUsageDelta(at: path), delta.tokens > 0 else { return }
                await MainActor.run {
                    SessionAppEffectExecutor.consume(SessionUsageReceipt(sessionID: event.sessionId, eventAt: event.timestamp,
                        tokens: delta.tokens, project: project, agent: "claude", costUSD: delta.costUSD),
                        petID: AppDaemon.shared.careTarget(forProject: project))
                }
            }
        case .codex:
            feedCodexTokens(for: event)
        default:
            return
        }
    }

    private func feedSubagentTokens(for event: AgentEvent) {
        guard event.eventName == "SubagentStop" || event.eventName == "subagentStop" else { return }
        guard event.agentKind == .claude else { return }
        guard let agentId = event.subagentId else { return }
        let parentPath = event.transcriptPath
            ?? event.project.map { TranscriptReader.inferredPath(sessionId: event.sessionId, cwd: $0) }
        guard let parentPath else { return }
        let path = TranscriptReader.subagentTranscriptPath(parentTranscriptPath: parentPath, agentId: agentId)
        let project = event.project
        let agent = event.agentKind.rawValue
        Task.detached(priority: .utility) {
            guard let delta = TranscriptReader.newUsageDelta(at: path), delta.tokens > 0 else { return }
            await MainActor.run {
                SessionAppEffectExecutor.consume(SessionUsageReceipt(sessionID: event.sessionId, eventAt: event.timestamp,
                    tokens: delta.tokens, project: project, agent: agent, costUSD: delta.costUSD),
                    petID: AppDaemon.shared.careTarget(forProject: project))
            }
        }
    }

    /// Codex has no Claude-style transcript; it writes a rollout JSONL under
    /// ~/.codex/sessions with per-turn token counts. Feed those so Codex earns
    /// token-based XP like Claude (#29). Feeds live on tool events and once more
    /// on Stop to catch the final turn; reads are incremental so no double-count.
    private func feedCodexTokens(for event: AgentEvent) {
        let isStop = event.eventName == "Stop"
        let now = Date()
        if !isStop, let last = lastLiveFeed[event.sessionId],
           now.timeIntervalSince(last) < Self.liveFeedInterval { return }
        lastLiveFeed[event.sessionId] = now
        let sid = event.sessionId
        let project = event.project
        let cachedPath = codexPathBySession[sid]
        Task.detached(priority: .utility) {
            guard let path = cachedPath
                ?? CodexMetadata.read(sessionID: sid, home: event.codexHome ?? CodexMetadata.defaultHome)?.rolloutPath else { return }
            let tokens = TranscriptReader.newCodexUsageTokens(at: path) ?? 0
            await MainActor.run {
                AppDaemon.shared.codexPathBySession[sid] = path
                guard tokens > 0 else { return }
                SessionAppEffectExecutor.consume(SessionUsageReceipt(sessionID: sid, eventAt: event.timestamp,
                    tokens: tokens, project: project, agent: "codex"), petID: AppDaemon.shared.careTarget(forProject: project))
            }
        }
    }

    /// Collects usage off-thread. Only a native request can establish waiting.
    private func finishClaudeTurn(event: AgentEvent, before: AgentState?, session: AgentSession) {
        let sessionId = event.sessionId
        let stateSince = session.stateSince
        let path: String? = event.transcriptPath
            ?? event.project.map { TranscriptReader.inferredPath(sessionId: sessionId, cwd: $0) }
        guard let path else {
            notifyIfNeeded(before: before, session: session)
            return
        }
        // Capture the project string (Sendable) before crossing the actor boundary.
        let project = session.project
        Task.detached(priority: .utility) { [weak self] in
            // The turn just ended either way — feed the pet the tokens it burnt.
            let delta = TranscriptReader.newUsageDelta(at: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                SessionAppEffectExecutor.consume(SessionUsageReceipt(sessionID: sessionId, eventAt: event.timestamp,
                    tokens: delta?.tokens ?? 0, project: project, agent: "claude", costUSD: delta?.costUSD ?? 0),
                    petID: self.careTarget(forProject: project))
                guard let final = self.store.session(id: sessionId), final.stateSince == stateSince else { return }
                self.notifyIfNeeded(before: before, session: final)
                self.refresh()
            }
        }
    }

    private func resolveTitle(for event: AgentEvent) {
        guard event.agentKind != .opencode, let session = store.session(id: event.sessionId) else { return }
        if event.agentKind == .codex { resolveCodexMetadata(for: event); return }
        if event.agentKind == .antigravity {
            metadata.read(session, purpose: "agy-title", interval: 5, force: event.eventName == "done", load: {
                let title = AntigravityMetadata.title(sessionID: event.sessionId, transcriptPath: event.transcriptPath)
                let activity = event.message == "工具执行结束，继续处理任务"
                    ? AntigravityMetadata.recentActivity(sessionID: event.sessionId, transcriptPath: event.transcriptPath) : nil
                return (title, activity)
            }, apply: { [weak self] result in
                guard let self else { return }
                if let title = result.0 { self.store.updateTitle(id: event.sessionId, title: title) }
                if let activity = result.1 { self.store.updateAntigravityActivity(id: event.sessionId, message: activity, since: event.timestamp) }
                self.refresh()
            })
            return
        }
        guard session.title == nil,
              let path = event.transcriptPath ?? event.project.map({ TranscriptReader.inferredPath(sessionId: event.sessionId, cwd: $0) }) else { return }
        metadata.read(session, purpose: "title", load: { TranscriptReader.title(at: path) }, apply: { [weak self] title in
            self?.store.updateTitle(id: event.sessionId, title: title)
            self?.refresh()
        })
    }

    private func resolveCodexMetadata(for event: AgentEvent) {
        guard let session = store.session(id: event.sessionId) else { return }
        resolveCodexInternalTask(for: session, force: event.eventName == "UserPromptSubmit")
        let home = event.codexHome ?? CodexMetadata.defaultHome
        metadata.read(session, purpose: "codex", interval: 5, force: event.eventName == "Stop", load: {
            CodexMetadata.read(sessionID: event.sessionId, home: home)
        }, apply: { [weak self] record in
            guard let self else { return }
            self.store.updateCodexMetadata(id: event.sessionId, record: record, home: home)
            if let path = record.rolloutPath, let current = self.store.session(id: event.sessionId) {
                self.codexPathBySession[event.sessionId] = path
                self.observation.watchCodex(current, path: path)
            }
            self.refresh()
        })
    }

    /// Diagnostic fallback for a known internal source. Desktop starts require
    /// a logged exit or definitive owner absence; live candidates stay visible.
    /// Disposable AionUi titles have an exact native client source span.
    /// Missing titles, absent threads, silence and the model name alone are not evidence.
    private func resolveCodexInternalTask(for session: AgentSession, force: Bool = false) {
        guard session.agentKind == .codex, !session.isCodexInternalTask,
              session.codexHasNativeThreadRecord != true,
              !session.codexDesktop, session.title == nil,
              session.terminalProgram == nil, session.terminalTTY == nil,
              session.terminalFocusURL == nil, session.validAionUiConversation == nil,
              let home = session.codexHome else { return }
        metadata.read(session, purpose: "codex-internal-task", interval: 30, force: force, load: {
            let source = session.updatedAt <= (session.codexInternalTaskObservedAt ?? .distantPast)
                ? session.codexTransientSource : nil
            return CodexInternalTaskEvidence.read(sessionID: session.id, home: home, cachedSource: source)
        }, apply: { [weak self] evidence in
            guard let self, self.store.applyCodexInternalTaskEvidence(expected: session, evidence: evidence) else { return }
            self.refresh()
        })
    }

    private func resolveModel(for event: AgentEvent) {
        guard event.agentKind == .claude, let session = store.session(id: event.sessionId),
              let path = event.transcriptPath ?? event.project.map({ TranscriptReader.inferredPath(sessionId: event.sessionId, cwd: $0) }) else { return }
        metadata.read(session, purpose: "model", interval: 30, load: { TranscriptReader.latestAssistantModel(at: path) }, apply: { [weak self] model in
            self?.store.updateModel(id: event.sessionId, model: model)
            self?.refresh()
        })
    }

    private func notifyIfNeeded(before: AgentState?, session: AgentSession) {
        guard BubbleSettings.shared.aoExperimentActive || !session.isAOHostSession else { return }
        let effects = SessionNotificationPolicy.effects(before: before, session: session)
        SessionAppEffectExecutor.execute(effects, session: session, petID: careTarget(forProject: session.project))
    }

    private func prune() {
        if let source = AgentPetPaths.migratedLocalDir {
            // Helpers cached before the identity switch can queue events while
            // Lite is restarting. Only the migrated source is consumed here.
            EventSocketServer.drainQueue(directory: source + "/queue") { [weak self] event in
                self?.ingest(event)
            }
        }
        for session in store.sessions {
            resolveDSHAntigravityBackend(for: session)
            resolveCodexInternalTask(for: session)
            if !session.isCodexInternalTask { resolveAionUiMetadata(for: session) }
        }
        for session in store.reconcileOpencodeLiveness(now: Date()) {
            notifyIfNeeded(before: .working, session: session)
        }
        store.prune(now: Date())
        guard store.sorted != sessions else { return }
        refresh()
    }

    func applyReadResultRetention() {
        guard isRunning else { return }
        configureReadResultRetention()
        refresh()
    }

    private func configureReadResultRetention() {
        let retention = BubbleSettings.shared.readResultRetention
        store.preserveReadResults = retention == .forever
        // Preserve the existing cleanup floor and allow the one-minute display.
        store.doneToIdleAfter = max(30, retention.seconds ?? 30)
    }

    private func scheduleReadResultExpiry() {
        readResultTimer?.invalidate(); readResultTimer = nil
        let now = Date()
        guard let deadline = BubblePresentation.nextReadResultDeadline(sessions,
            retention: BubbleSettings.shared.readResultRetention, now: now) else { return }
        let timer = Timer(timeInterval: max(0.001, deadline.timeIntervalSince(now)), repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.refresh()
            }
        }
        readResultTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refresh() {
        let trackedSessions = store.sorted.filter { !$0.isCodexInternalTask }
        navigation.retain(Set(trackedSessions.map(\.id)))
        navigationMessages = navigationMessages.filter { key, _ in trackedSessions.contains { $0.id == key } }
        let dismissalRevision = endedDismissal.revision
        sessions = endedDismissal.visible(trackedSessions, now: Date()).filter { !$0.isUnidentifiedCodexCompletion }
        if endedDismissal.revision != dismissalRevision { saveEndedDismissal() }
        for session in store.sessions { resolveDSHAntigravityBackend(for: session) }
        for session in trackedSessions { resolveAionUiMetadata(for: session) }
        metadata.retain(store.sessions)
        observation.reconcile(trackedSessions)
        let ids = Set(trackedSessions.map(\.id))
        teamVerificationWatchdog.retain(ids)
        codexPathBySession = codexPathBySession.filter { ids.contains($0.key) }
        lastLiveFeed = lastLiveFeed.filter { ids.contains($0.key) }
        scheduleReadResultExpiry()
        PetController.shared.update(sessions: sessions)
        deliverOpencodeSpeech()
        StatusBarController.shared.updateStatus(sessions)
        deliverDSHSpeech()
    }
}
