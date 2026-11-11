import AppKit
import OSLog
import Combine
import AgentPetCore

/// Resolves the aggregate session mood, plays a short `celebrate` burst when
/// work finishes, owns the selected (imported) pet, and drives the chat bubble.
@MainActor
final class PetController: ObservableObject {
    static let shared = PetController()

    @Published private(set) var mood: PetMood = .idle
    @Published private(set) var chatLine: String = ""

    @Published var selectedPetID: String? {
        didSet { UserDefaults.standard.set(selectedPetID, forKey: Self.petKey) }
    }
    @Published var showChat: Bool {
        didSet {
            UserDefaults.standard.set(showChat, forKey: Self.chatKey)
            refreshChat()
        }
    }
    /// Whether the pet shows a chat line while idle (the "doing nothing" chatter).
    @Published var showIdleMessage: Bool {
        didSet {
            UserDefaults.standard.set(showIdleMessage, forKey: Self.idleMsgKey)
            refreshChat()
        }
    }
    /// When enabled, spawns one pet window per active project instead of a single shared pet.
    @Published var splitPet: Bool = UserDefaults.standard.bool(forKey: "agentpet.splitPet") {
        didSet {
            UserDefaults.standard.set(splitPet, forKey: "agentpet.splitPet")
            update(sessions: rawSessions)   // re-evaluate windows when toggled
        }
    }
    /// In split mode: hide a configured project's pet while it has no active work
    /// (it reappears when the project runs again). Off = the project pet stays put.
    @Published var hideIdleProjectPets: Bool = UserDefaults.standard.bool(forKey: "agentpet.hideIdleProjectPets") {
        didSet {
            UserDefaults.standard.set(hideIdleProjectPets, forKey: "agentpet.hideIdleProjectPets")
            update(sessions: rawSessions)
        }
    }
    /// When disabled, freezes all continuous/perpetual pet and bubble animation so
    /// the SwiftUI render loop can go idle (lower CPU, reduce-motion option).
    @Published var animationsEnabled: Bool =
        (UserDefaults.standard.object(forKey: "agentpet.animationsEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(animationsEnabled, forKey: "agentpet.animationsEnabled") }
    }
    /// User-adjustable sprite frame rate (1–12 fps). Active moods animate at this
    /// rate; idle is capped at 2 fps regardless of the slider (idle CPU win).
    @Published var animationFPS: Double =
        ((UserDefaults.standard.object(forKey: "agentpet.animationFPS") as? Double) ?? 8).clampedFPS {
        didSet {
            let v = animationFPS.clampedFPS
            if v != animationFPS { animationFPS = v; return }   // re-entrancy guard for clamp
            UserDefaults.standard.set(animationFPS, forKey: "agentpet.animationFPS")
        }
    }
    /// Sprite point size, freely adjustable via a slider.
    @Published var petPoint: Double {
        didSet { UserDefaults.standard.set(petPoint, forKey: Self.sizeKey) }
    }

    static let minPoint: Double = 60
    static let maxPoint: Double = 240
    static let presets: [(String, Double)] = [("S", 84), ("M", 120), ("L", 168)]

    private var latestSessions: [AgentSession] = []
    /// The unfiltered session list from the last `update`, kept so display
    /// switches (AionUI Team off/on, split mode) can recompute without losing
    /// the Team members they previously filtered out.
    private(set) var rawSessions: [AgentSession] = []
    private var quotaCue: PetAnimationCue?
    private var quotaText = ""
    private var quotaTimer: Timer?
    lazy var systemNotices = SystemNoticeCenter(visible: {
        PetWindowController.shared.isSystemNoticeVisible(id: $0)
    }, changed: { [weak self] in self?.systemNoticeChanged() })
    private lazy var idleRotation = IdleSpeechRotation(eligible: { [weak self] in
        guard let self else { return false }
        return self.showIdleMessage && self.mood == .idle && self.breakState == nil
            && PetWindowController.shared.hasVisibleIdleChatter
    }, advance: { [weak self] in self?.refreshChat() })
    private var idleRefreshScheduled = false
    private var idleSubscriptions = Set<AnyCancellable>()
    private var speech = PetSpeechState()
    private var speechTimer: Timer?

    func showProgress(_ message: CodexVisibleMessage, session: AgentSession) {
        guard BubbleSettings.shared.agentMessagesEnabled, BubbleSettings.shared.allowsAgentActivity(session) else { return }
        speech.receive(message, session: session, now: Date())
        scheduleSpeechExpiry()
        syncWindows()
    }

    func showProgress(_ message: OpencodeVisibleMessage, session: AgentSession) {
        guard BubbleSettings.shared.agentMessagesEnabled, BubbleSettings.shared.allowsAgentActivity(session) else { return }
        let candidate = PetSpeechState.Candidate(fence: .init(session, turnID: message.turnID),
            itemID: message.partID, timestamp: message.timestamp, revision: message.revision,
            content: message.mode == .withdraw ? .withdraw : .snapshot(message.text))
        speech.receive(candidate, session: session, now: Date())
        scheduleSpeechExpiry()
        syncWindows()
    }

    func clearProgress() {
        speechTimer?.invalidate(); speechTimer = nil
        speech.clear()
        if systemNotices.current?.kind.isPriority == true { speech.beginImportant(now: Date(), controlled: true) }
        syncWindows()
    }

    func showProgress(_ message: DSHVisibleMessage, session: AgentSession) {
        guard BubbleSettings.shared.agentMessagesEnabled, BubbleSettings.shared.allowsAgentActivity(session) else { return }
        let candidate = PetSpeechState.Candidate(fence: .init(session, turnID: String(message.turn)),
            itemID: message.itemID, timestamp: message.timestamp, revision: message.revision,
            content: message.mode == .withdraw ? .withdraw : .snapshot(message.text))
        speech.receive(candidate, session: session, now: Date())
        scheduleSpeechExpiry(); syncWindows()
    }

    func showProgress(_ message: AntigravityVisibleMessage, session: AgentSession) {
        guard BubbleSettings.shared.agentMessagesEnabled, BubbleSettings.shared.allowsAgentActivity(session),
              message.boundary.matches(session) else { return }
        let candidate = PetSpeechState.Candidate(fence: .init(session, turnID: message.executionID),
            itemID: message.itemID, timestamp: message.timestamp, revision: message.revision,
            content: message.mode == .withdraw ? .withdraw : .snapshot(message.text))
        speech.receive(candidate, session: session, now: Date())
        scheduleSpeechExpiry(); syncWindows()
    }

    private func scheduleSpeechExpiry() {
        speechTimer?.invalidate(); speechTimer = nil
        guard let next = speech.nextExpiry else { return }
        let timer = Timer(timeInterval: max(0.01, next.timeIntervalSinceNow), repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.speech.reconcile(self.latestSessions, now: Date())
                self.scheduleSpeechExpiry()
                self.syncWindows()
            }
        }
        speechTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func clearLowQuota() {
        quotaTimer?.invalidate(); quotaTimer = nil
        quotaCue = nil
        systemNotices.clear()
        quotaText = ""
        scheduleSpeechExpiry(); syncWindows()
    }

    func showLowQuota(_ notice: CodexLowQuotaReminder.Notice) {
        guard BubbleSettings.shared.superchatEnabled else { return }
        quotaTimer?.invalidate()
        quotaCue = .init(id: notice.id, key: "quota")
        systemNotices.post(.lowQuota(notice))
        let id = notice.id
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.quotaCue?.id == id else { return }
                self.quotaCue = nil; self.quotaTimer = nil; self.syncWindows()
            }
        }
    }

    func showQuotaRecovered(_ notice: CodexQuotaRecovery.Notice) {
        guard BubbleSettings.shared.superchatEnabled else { return }
        quotaTimer?.invalidate(); quotaTimer = nil; quotaCue = nil
        systemNotices.post(.recovered(notice))
    }

    func showPomodoro(_ text: String) {
        showPomodoroNotice(.init(id: UUID().uuidString, kind: .pomodoro,
            title: SystemNotice.text("Pomodoro: ", "番茄时钟："), body: text, legacyText: text))
    }

    /// Operation feedback for the user-initiated click-through toggle. It is
    /// delivered through the existing Superchat notice surface; the clock
    /// keeps it out of the way of priority notices and updates it in place.
    func showClickThroughFeedback(enabled: Bool, suspended: Bool) {
        guard BubbleSettings.shared.superchatEnabled else { return }
        systemNotices.post(.clickThrough(enabled: enabled, suspended: suspended))
    }

    func showPomodoroFinished(phase: PomodoroClock.Phase, focusMinutes: Int, restMinutes: Int,
                              onConfirmed: (() -> Void)? = nil) {
        let body = phase == .focus ? SystemNotice.format("%d min focus done, break %d min", "%d分钟专注完成，可休息%d分钟", focusMinutes, restMinutes)
            : SystemNotice.format("%d min break done, ready to focus", "%d分钟休息结束，可继续专注", restMinutes)
        showPomodoroNotice(.init(id: UUID().uuidString, kind: .pomodoro, title: SystemNotice.text("Pomodoro: ", "番茄时钟："),
            body: body, legacyText: body,
            shortBody: phase == .focus ? SystemNotice.format("Focus done, break %d min", "专注完成，可休息%d分钟", restMinutes)
                : SystemNotice.text("Break done, ready to focus", "休息结束，可继续专注"),
            confirmationLabel: onConfirmed == nil ? nil : (phase == .focus ? "Start break" : "Start focus")),
            onConfirmed: onConfirmed)
    }

    private func showPomodoroNotice(_ notice: SystemNotice, onConfirmed: (() -> Void)? = nil) {
        #if AGENTPET_LOCAL
        Logger(subsystem: AgentPetPaths.bundleIdentifier, category: "pomodoro-notice").notice("deliver timer notice enabled=\(BubbleSettings.shared.superchatEnabled, privacy: .public)")
        #endif
        guard BubbleSettings.shared.superchatEnabled else { return }
        systemNotices.post(notice, onConfirmed: onConfirmed)
    }

    private func systemNoticeChanged() {
        quotaText = systemNotices.current?.legacyText ?? ""
        if systemNotices.current?.kind.isPriority == true { speech.beginImportant(now: Date(), controlled: true) }
        else { speech.endImportant(now: Date()) }
        scheduleSpeechExpiry(); syncWindows()
    }

    /// Number of active agent lines currently shown; drives window height.
    @Published private(set) var chatLineCount: Int = 0
    /// Sorted active sessions for the structured desktop bubble. Empty when idle/done/celebrate.
    @Published private(set) var activeAgentSessions: [AgentSession] = []

    private static let petKey = "agentpet.selectedPetID"
    private static let chatKey = "agentpet.showChat"
    private static let idleMsgKey = "agentpet.showIdleMessage"
    private static let sizeKey = "agentpet.petSize"
    private static let celebrateDuration: TimeInterval = 3

    init() {
        selectedPetID = UserDefaults.standard.string(forKey: Self.petKey)
        showChat = (UserDefaults.standard.object(forKey: Self.chatKey) as? Bool) ?? true
        showIdleMessage = (UserDefaults.standard.object(forKey: Self.idleMsgKey) as? Bool) ?? true
        let saved = UserDefaults.standard.object(forKey: Self.sizeKey) as? Double ?? 120
        petPoint = min(max(saved, Self.minPoint), Self.maxPoint)
    }

    func applySpeechDuration(_ duration: TimeInterval) {
        speech.setDuration(duration); scheduleSpeechExpiry(); syncWindows()
    }

    func start() {
        speech.setDuration(BubbleSettings.shared.messageDuration)
        IdleSpeechSettings.shared.objectWillChange.sink { [weak self] _ in
            // Published fires before storage mutation. Coalesce a custom apply's
            // content/source changes into one pick on the next main-loop turn.
            guard let self, !self.idleRefreshScheduled else { return }
            self.idleRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.idleRefreshScheduled = false
                self?.refreshChat()
            }
        }.store(in: &idleSubscriptions)
        idleRotation.start()
        // Re-plan windows when project→pet mappings change so adding/removing a
        // configured project takes effect immediately (no need to wait for the
        // next session event).
        ProjectPetSettings.shared.onChange = { [weak self] in
            guard let self else { return }
            self.update(sessions: self.rawSessions)
        }
    }

    func reconcileIdleChatter() { idleRotation.reconcile() }

    func stop() {
        idleRotation.stop()
        idleSubscriptions.removeAll()
    }

    /// Returns the effective sprite fps for a given mood, honouring the slider.
    /// Idle and sleepy are capped at 2 fps regardless of the slider value (calm CPU win).
    func spriteFPS(forMood mood: PetMood) -> Double {
        (mood == .idle || mood == .sleepy) ? min(animationFPS, 2) : animationFPS
    }

    private var sizeAnimTimer: Timer?
    private var sizeAnimStep = 0
    private var sizeAnimStart = 0.0
    private var sizeAnimTarget = 0.0
    private static let sizeAnimSteps = 14

    /// Eases `petPoint` to a target so a preset tap resizes as smoothly as a
    /// slider drag (each step drives the same smooth window resize).
    func animateSize(to target: Double) {
        sizeAnimTimer?.invalidate()
        sizeAnimTarget = min(max(target, Self.minPoint), Self.maxPoint)
        sizeAnimStart = petPoint
        sizeAnimStep = 0
        sizeAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tickSize() }
        }
    }

    private func tickSize() {
        sizeAnimStep += 1
        let t = min(Double(sizeAnimStep) / Double(Self.sizeAnimSteps), 1)
        let eased = t * t * (3 - 2 * t)   // smoothstep
        petPoint = sizeAnimStart + (sizeAnimTarget - sizeAnimStart) * eased
        if sizeAnimStep >= Self.sizeAnimSteps {
            petPoint = sizeAnimTarget
            sizeAnimTimer?.invalidate()
        }
    }

    /// Called by the daemon whenever the session list changes.
    /// Team-aware eligibility for pet state, windows and speech: a shown Team
    /// counts only through its verified lead, and members of a hidden or
    /// unverified Team never drive the pet. Ordinary sessions are unchanged.
    static func teamEligible(_ sessions: [AgentSession],
                             teamsShown: Bool = BubbleSettings.shared.showAionUiTeams,
                             aoShown: Bool = BubbleSettings.shared.aoExperimentActive) -> [AgentSession] {
        sessions.filter { session in
            guard aoShown || !session.isAOHostSession else { return false }
            guard let team = session.hostTeamScope else { return true }
            switch team.host {
            case .aionUI: return teamsShown && team.role == .lead
            case .agentOrchestrator: return aoShown && team.role == .lead
            }
        }
    }

    /// Recompute derived pet state after a display-switch change without losing
    /// the original session list (so re-enabling restores the Team rows).
    func applySettingsChange() {
        update(sessions: rawSessions)
    }

    func update(sessions: [AgentSession]) {
        rawSessions = sessions
        let eligible = Self.teamEligible(sessions)
        latestSessions = eligible
        speech.reconcile(eligible, now: Date())
        scheduleSpeechExpiry()
        let resolved = MoodResolver.aggregate(eligible)

        setMood(resolved)

        if resolved == .working || resolved == .waiting {
            if BubbleSettings.shared.structuredTasksEnabled {
                buildAgentChatLine(sessions: eligible)
            } else {
                chatLineCount = 0
                activeAgentSessions = []
                refreshChat()
            }
        } else {
            chatLineCount = 0
            activeAgentSessions = []
        }
        syncWindows()
    }

    /// Rebuilds chat state when the user toggles multi-agent bubble mode.
    func applyBubbleModeChange() {
        guard mood == .working || mood == .waiting else { return }
        if BubbleSettings.shared.structuredTasksEnabled {
            buildAgentChatLine(sessions: latestSessions)
        } else {
            chatLineCount = 0
            activeAgentSessions = []
            refreshChat()
        }
        syncWindows()
    }

    private func settleAfterCelebrate() {
        celebratingKeys.removeAll()
        setMood(MoodResolver.aggregate(latestSessions))
        syncWindows()
    }

    /// Plays a short celebrate burst with a custom line (e.g. an achievement
    /// unlock), then settles back to the aggregate mood. Sets `chatLine`
    /// directly — `setMood` would re-roll it from the message pools.
    func flashCelebrate(line: String, petID: String? = nil) {
        let resolvedPetID = petID ?? selectedPetID
        let keys: [String]
        if let pid = resolvedPetID {
            keys = PetWindowPlanner.windowKeys(forPetID: pid, split: splitPet,
                                               mappings: ProjectPetSettings.shared.mappings,
                                               selectedPetID: selectedPetID)
        } else {
            keys = [PetWindowPlanner.defaultKey]
        }
        for key in keys {
            celebratingKeys[key] = CelebrateFlash(line: line, mood: .celebrate)
            let k = key
            Timer.scheduledTimer(withTimeInterval: Self.celebrateDuration, repeats: false) { _ in
                Task { @MainActor [weak self] in
                    self?.celebratingKeys.removeValue(forKey: k)
                    self?.syncWindows()
                }
            }
        }
        StatusBarController.shared.refreshTitle()
        syncWindows()
    }

    /// Plays a short level-up burst with a custom line, using the dedicated
    /// `.levelup` mood (a distinct clip from the done-celebrate), then settles
    /// back to the aggregate mood. Sets `chatLine` directly — `setMood` would
    /// re-roll it from the message pools.
    func flashLevelUp(line: String, petID: String? = nil) {
        let resolvedPetID = petID ?? selectedPetID
        let keys: [String]
        if let pid = resolvedPetID {
            keys = PetWindowPlanner.windowKeys(forPetID: pid, split: splitPet,
                                               mappings: ProjectPetSettings.shared.mappings,
                                               selectedPetID: selectedPetID)
        } else {
            keys = [PetWindowPlanner.defaultKey]
        }
        for key in keys {
            celebratingKeys[key] = CelebrateFlash(line: line, mood: .levelup)
            let k = key
            Timer.scheduledTimer(withTimeInterval: Self.celebrateDuration, repeats: false) { _ in
                Task { @MainActor [weak self] in
                    self?.celebratingKeys.removeValue(forKey: k)
                    self?.syncWindows()
                }
            }
        }
        StatusBarController.shared.refreshTitle()
        syncWindows()
    }

    private func setMood(_ newMood: PetMood) {
        let changed = newMood != mood
        mood = newMood
        // Only re-pick the line when the mood actually changes, so a periodic
        // refresh (e.g. the 10s prune) doesn't keep swapping the idle line and
        // resize/jump the pet. `reroll` forces a new pick on real transitions.
        refreshChat(reroll: changed)
    }

    /// Re-pick the chat line so it adopts a newly chosen app language at once.
    func relocalize() { refreshChat() }

    private func refreshChat(reroll: Bool = true) {
        guard BubbleSettings.shared.structuredTasksEnabled else {
            chatLine = ""
            StatusBarController.shared.refreshTitle()
            syncWindows()
            return
        }
        if mood == .idle {
            guard showIdleMessage else {
                chatLine = ""
                StatusBarController.shared.refreshTitle()
                syncWindows()
                return
            }
            if reroll || chatLine.isEmpty {
                chatLine = idleLine()
            }
            StatusBarController.shared.refreshTitle()
            syncWindows()
            return
        }
        // Multi-agent mode owns chatLine during working/waiting; otherwise use PetChat.
        if (mood == .working || mood == .waiting)
            && BubbleSettings.shared.structuredTasksEnabled
            && chatLineCount > 0 {
            StatusBarController.shared.refreshTitle()
            syncWindows()
            return
        }
        if reroll || chatLine.isEmpty {
            chatLine = chatLine(forMood: mood)
        }
        StatusBarController.shared.refreshTitle()
        syncWindows()
    }

    // MARK: - Chat line (reusable per-mood line picker)

    /// The idle "doing nothing" chatter, care-coloured (hunger / budget anxiety).
    /// Shared by the aggregate `refreshChat` and per-project home windows.
    private func idleLine(petID: String? = nil) -> String {
        let content = IdleSpeechSettings.shared
        let hunger = PetCare.hunger(state: PetCareController.shared.state(for: petID), now: Date())
        // Literal custom lines do not acquire care-generated additions.
        let pool = content.source == .custom ? content.lines : CareChat.idlePool(base: content.lines, hunger: hunger)
        return content.pick(from: pool)
    }

    /// A fresh chat line for a non-idle mood, honouring the bubble source.
    /// Reused for both the aggregate pet and per-project split windows.
    private func chatLine(forMood mood: PetMood) -> String {
        let pool = BubbleMessages.defaultLines(mood)
        return pool.randomElement() ?? ""
    }

    /// The chat line shown for a planned window. For working/waiting in
    /// multi-agent mode the structured `AgentBubble` carries the rows, so the
    /// `chatLine` is only the plain-text fallback (and stays empty so the
    /// bubble isn't double-drawn); otherwise a per-mood pool pick.
    private func chatLine(forMood mood: PetMood, sessions: [AgentSession], petID: String? = nil) -> String {
        switch mood {
        case .idle, .sleepy:
            guard showIdleMessage else { return "" }
            return idleLine(petID: petID)
        case .working, .waiting:
            if BubbleSettings.shared.structuredTasksEnabled && !sessions.isEmpty {
                return sessions.map { "• \(TickerFormatter.line(for: $0))" }.joined(separator: "\n")
            }
            return chatLine(forMood: mood)
        case .done, .celebrate, .levelup:
            return chatLine(forMood: mood)
        }
    }

    // MARK: - Agent list

    /// Builds the structured session list and a plain-text fallback chatLine.
    private func buildAgentChatLine(sessions: [AgentSession]) {
        let active = TickerFormatter.sorted(
            sessions.filter { $0.state != .idle && $0.state != .registered }
        )
        activeAgentSessions = active
        chatLineCount = active.count
        if active.isEmpty {
            chatLine = ""
        } else {
            // Plain-text fallback used by the menu bar chat pill (lineLimit(1) shows first line).
            chatLine = active.map { "• \(TickerFormatter.line(for: $0))" }.joined(separator: "\n")
        }
        StatusBarController.shared.refreshTitle()
        syncWindows()
    }

    // MARK: - Window coordination (planner → PetWindowController)

    private struct CelebrateFlash {
        let line: String
        let mood: PetMood
    }

    private var celebratingKeys: [String: CelebrateFlash] = [:]

    // MARK: - Break reminder (home pet rests)

    /// Transient override shown on the home/default pet during a break.
    private enum BreakDisplay {
        case resting(line: String)
        case perkUp(line: String)
    }
    private var breakState: BreakDisplay?
    private var breakPerkTimer: Timer?

    /// Puts the home/default pet into a resting state until `endBreakRest`.
    /// Only the `default` window is affected; project pets keep their mood.
    func beginBreakRest(line: String) {
        breakPerkTimer?.invalidate()
        breakState = .resting(line: line)
        syncWindows()
    }

    /// Clears any in-progress break rest immediately (e.g. the user disabled the
    /// reminder mid-break). Without this the home pet would stay "resting", since
    /// only the break-over path clears `breakState`.
    func cancelBreakRest() {
        breakPerkTimer?.invalidate()
        breakPerkTimer = nil
        guard breakState != nil else { return }
        breakState = nil
        syncWindows()
    }

    /// Wakes the home/default pet: a short "back to work" line, then clears.
    func endBreakRest(line: String) {
        breakPerkTimer?.invalidate()
        breakState = .perkUp(line: line)
        syncWindows()
        breakPerkTimer = Timer.scheduledTimer(withTimeInterval: Self.celebrateDuration, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.breakState = nil
                self?.syncWindows()
            }
        }
    }

    /// Plans the per-project pet windows from the current sessions and reconciles
    /// the window registry. Single-pet mode (Split OFF) yields exactly one
    /// "default" window whose state mirrors today's aggregate behaviour.
    private var syncScheduled = false

    /// The window's bubble display list. Planned sessions render as before; the
    /// home window additionally accepts every Team-marked session so the
    /// collapsed Team row can weigh member activity against the leader's own
    /// turn, and a leaderless Team still reaches the bubble as a neutral row.
    /// Mood, animation, speech and window planning stay leader-driven, and the
    /// Team row's identity, state and timer still come from the leader. Pure so
    /// the projection is testable without a live controller.
    nonisolated static func displayProjection(raw: [AgentSession], plannedIDs: Set<String>, defaultWindow: Bool,
                                              teamsShown: Bool) -> [AgentSession] {
        var result = raw.filter { plannedIDs.contains($0.id) }
        guard defaultWindow else { return result }
        result += raw.filter { session in
            guard let team = session.hostTeamScope, !plannedIDs.contains(session.id) else { return false }
            switch team.host {
            case .aionUI: return teamsShown
            case .agentOrchestrator: return true
            }
        }
        return result
    }

    private func syncWindows() {
        guard !syncScheduled else { return }
        syncScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.performWindowSync()
        }
    }

    private func performWindowSync() {
        let specs = PetWindowPlanner.plan(
            sessions: latestSessions,
            split: splitPet,
            mappings: ProjectPetSettings.shared.mappings,
            defaultPetID: selectedPetID,
            forceDefault: breakState != nil || quotaCue != nil || systemNotices.current != nil,
            hideIdleProjects: hideIdleProjectPets,
            retainedSessionIDs: Set(BubblePresentation.visible(latestSessions,
                settings: BubbleSettings.shared.presentationConfiguration)
                .filter { $0.state == .idle && BubblePresentation.isReadResult($0) }.map(\.id))
        )

        let liveKeys = Set(specs.map(\.key))
        // Drop tracking for windows that no longer exist.
        celebratingKeys = celebratingKeys.filter { liveKeys.contains($0.key) }

        PetWindowController.shared.sync(specs: specs, noticeSource: systemNotices) { [weak self] spec in
            self?.windowState(for: spec)
                ?? PetWindowController.WindowState(petID: spec.petID, mood: spec.mood,
                                                   sessions: [], count: spec.count, chatLine: "")
        }
    }

    /// Resolves the displayed state for one planned window.
    private func windowState(for spec: PetWindowSpec) -> PetWindowController.WindowState {
        // Substitute the selected pet when the configured pet was deleted, so a
        // missing sprite falls back to the default instead of the paw placeholder.
        let petID: String? = {
            if let id = spec.petID, ImagePetStore.shared.pack(id: id) != nil { return id }
            return selectedPetID
        }()

        // A break nudge overrides the home/default pet (rest visual + line) in
        // both split modes. Project pets keep their own mood — this nudges the
        // user, not the agents. `.sleepy` is the rest visual; `.idle` on perk-up.
        if spec.key == PetWindowPlanner.defaultKey, let bs = breakState {
            let mood: PetMood
            let line: String
            switch bs {
            case .resting(let l): mood = .sleepy; line = l
            case .perkUp(let l): mood = .idle; line = l
            }
            var animation = PetAnimationContext(cue: quotaCue,
                quotaReminderEnabled: BubbleSettings.shared.superchatEnabled)
            animation.baseKey = mood.rawValue
            animation.baseTrigger = "break:" + mood.rawValue
            return PetWindowController.WindowState(
                petID: petID, mood: mood, sessions: [], count: 0, chatLine: line,
                animationContext: animation, quotaText: quotaText)
        }

        // Message visibility follows the tracked sessions, independently of
        // the pet's celebrate/done mood. Otherwise the last completion loses
        // its unread/read lamp exactly when all agents stop working.
        let ids = Set(spec.sessionIDs)
        // Include explicit cancelled/idle results for animation only. The
        // planner's visible-message membership remains unchanged. Animation is
        // leader-driven: an unverified Team member never animates the pet.
        let animationSessions = latestSessions.filter { session in
            guard splitPet else { return true }
            let owner = ProjectPetResolver.mapping(forProject: session.project,
                mappings: ProjectPetSettings.shared.mappings)
                .map { ProjectPetResolver.normalize($0.projectPath) } ?? PetWindowPlanner.defaultKey
            return owner == spec.key
        }
        let animationContext = PetAnimationContext(sessions: animationSessions,
            cue: spec.key == PetWindowPlanner.defaultKey ? quotaCue : nil,
            quotaReminderEnabled: BubbleSettings.shared.superchatEnabled)
        let quotaLine = spec.key == PetWindowPlanner.defaultKey ? (quotaText) : ""
        let speechRows = BubbleSettings.shared.agentMessagesEnabled
            ? speech.visible(sessions: animationSessions, hiddenKinds: BubbleSettings.shared.hiddenKinds,
                             showTeams: BubbleSettings.shared.showAionUiTeams, now: Date()) : []
        // The bubble may adopt leaderless Team members as neutral display data;
        // mood, animation, speech and planning above stay leader-driven.
        let display = Self.displayProjection(raw: rawSessions, plannedIDs: ids,
                                             defaultWindow: spec.key == PetWindowPlanner.defaultKey,
                                             teamsShown: BubbleSettings.shared.showAionUiTeams)
        let tracked = TickerFormatter.sorted(display.filter {
            ($0.state != .idle || BubblePresentation.isReadResult($0)) && $0.state != .registered
        })
        if let flash = celebratingKeys[spec.key] {
            return PetWindowController.WindowState(
                petID: petID, mood: flash.mood, sessions: tracked, count: tracked.count, chatLine: flash.line,
                animationContext: animationContext, quotaText: quotaLine, speechRows: speechRows
            )
        }

        let groupSessions: [AgentSession]
        let lineCount: Int
        let resolvedLine: String
        if !splitPet && spec.key == PetWindowPlanner.defaultKey {
            groupSessions = tracked
            lineCount = tracked.count
            resolvedLine = chatLine
        } else {
            groupSessions = tracked
            lineCount = spec.count
            resolvedLine = chatLine(forMood: spec.mood, sessions: groupSessions, petID: spec.petID)
        }
        return PetWindowController.WindowState(
            petID: petID,
            mood: spec.mood,
            sessions: groupSessions,
            count: lineCount,
            chatLine: resolvedLine, animationContext: animationContext, quotaText: quotaLine, speechRows: speechRows,
            idleText: showIdleMessage && (spec.mood == .idle || spec.mood == .sleepy)
                && BubblePresentation.visible(groupSessions, settings: BubbleSettings.shared.presentationConfiguration).isEmpty
                && speechRows.isEmpty && quotaLine.isEmpty ? resolvedLine : ""
        )
    }
}

// MARK: - FPS helpers

private extension Double {
    /// Clamps a frame-rate value to the valid 1–12 fps slider range.
    var clampedFPS: Double { min(max(self, 1), 12) }
}

/// Built-in (system) chat lines per mood.
enum PetChat {
    static let lines: [PetMood: [String]] = [
        .working: [
            "Thinking…", "Working on it…", "On it!", "Crunching code…",
            "Hmm, let me see…", "Cooking something up…", "Deep in thought…",
            "Brain go brrr…", "Almost there…", "Wiring it up…",
        ],
        .waiting: [
            "I need you!", "Your turn 👀", "Waiting on you…", "Can you check this?",
            "Psst, need input!", "Awaiting orders…", "Help me out?", "Stuck, need you!",
        ],
        .done: [
            "All done! ✅", "Finished!", "Ta-da!", "Done and dusted!",
            "Nailed it!", "That's a wrap!", "Mission complete!",
        ],
        .celebrate: [
            "🎉 Woohoo!", "We did it!", "Victory!", "Yesss!", "High five! 🙌", "Champion!",
        ],
    ]
}
