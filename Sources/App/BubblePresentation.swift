import Foundation
import AgentPetCore

/// Sessions sharing an agent kind collapse into one row when enabled.
struct GroupedSession: Identifiable {
    /// The host-neutral Team identity of one aggregated row. The row's
    /// state-bearing fields always come from `session` (the current lead when
    /// present).
    struct TeamInfo: Equatable, Sendable {
        /// AionUI is the historical default; AO rows explicitly carry their
        /// host so the two identities never collide.
        var host: HostKind = .aionUI
        let id: String
        let name: String
        let leaderMissing: Bool
        /// The lead's own role is known, but its live check is no longer current
        /// (never checked, a later check failed, or the check belongs to an
        /// earlier launch / a stalled checker). The last known result may be
        /// kept, but never as current evidence.
        var identityUnconfirmed = false
        /// The lead claims `.working` but has no fresh native activity evidence
        /// (same 300 s floor as members). A static DB match cannot keep a
        /// permanent "working" claim alive.
        var activityUnconfirmed = false
        /// At least one identity-verified member of this Team still has fresh
        /// `working` evidence. Member activity only keeps the row visible and
        /// withholds the leader's own success; it never rewrites the leader's
        /// state, timer or identity.
        var membersWorking = false
        /// Fresh idle activity is also meaningful when a project has no
        /// orchestrator. It never claims that a native turn succeeded.
        var hasCurrentIdleMember = false
        /// Native replies waiting for the user's exact read receipt. Host idle
        /// is activity metadata and must not extinguish this result indicator.
        var unreadNativeResult: UnreadNativeResult? = nil
        /// The secondary unread control captures one member. The primary row
        /// remains a project entry; neither control acknowledges siblings.
        var unreadNavigationSession: AgentSession? = nil
        var unreadNativeCount = 0
        enum UnreadNativeResult: Equatable, Sendable { case completed, unknown }
        /// AO-only member summary. AionUI Team rows keep their existing
        /// lead-only semantics; AO rows must not let an idle leader hide a
        /// member waiting, failed, cancelled or unknown.
        var memberState: MemberState? = nil
        /// Source-owned facts displayed by the project summary. This is only a
        /// view projection; no receipt is copied into another native session.
        var aoAttentionReceipts: [AOAttentionReceipt] = []

        enum MemberState: Equatable, Sendable {
            case waiting, failed, cancelled, unknown
        }
    }
    let session: AgentSession   // highest-priority session in the group
    let count: Int              // total sessions sharing this agent kind
    var team: TeamInfo? = nil
    var id: String {
        guard let team else { return "\(session.groupKey)-\(session.id)" }
        return team.host == .aionUI ? "team-\(team.id)" : "ao-team-\(team.id)"
    }
}

/// Pure display policy. Settings/message providers are captured at the UI boundary;
/// no shared instances, persistence, navigation or clock reads occur here.
enum BubblePresentation {
    struct Configuration {
        var hiddenKinds: Set<AgentKind> = []
        var minStateFilter: MinStateFilter = .all
        var sessionGrouping: BubbleSessionGrouping = .byKind
        var groupByKind = false
        var displayMode: BubbleDisplayMode = .carousel
        var maxSessions = 5
        /// Independent AionUI Team switch; the whole Team is shown or hidden as
        /// one row and is never affected by per-kind filters.
        var showAionUiTeams = true
        /// Production supplies the default-off experiment preference. Pure
        /// callers can opt in independently to exercise the AO projection.
        var showAgentOrchestratorTeams = true
        var showDSHTUI = false
        // Wall clock captured by the live UI boundary; deterministic in tests.
        var now = Date.distantPast
        var readResultRetention: ReadResultRetention = .fiveSeconds
    }
    static func hasContent(reaction: String, showChat: Bool, petID: String?, multiAgent: Bool,
                           sessions: [AgentSession], chatLine: String, settings: Configuration) -> Bool {
        // "Has content" must match the rows that actually render: a Team whose
        // lead no longer qualifies (read/expired) yields no row, so it cannot
        // keep an empty bubble alive.
        !reaction.isEmpty || (showChat && petID != nil &&
            ((multiAgent && !groups(sessions, settings: settings).isEmpty) || !chatLine.isEmpty))
    }
    // attentionPriority is internal to AgentPetCore — use local rank
    private static func rank(_ s: AgentState) -> Int {
        switch s { case .working: 4; case .waiting: 5; case .done: 2; case .registered: 1; case .idle: 0 }
    }

    static func isReadResult(_ session: AgentSession) -> Bool {
        (session.state == .done || session.state == .idle) &&
            session.hasReadReceipt && !session.isStopped
    }

    static func readResultDeadline(_ session: AgentSession, retention: ReadResultRetention) -> Date? {
        guard isReadResult(session), let seconds = retention.seconds else { return nil }
        // Legacy receipts without readAt use the last stored activity timestamp.
        return (session.readAt ?? session.updatedAt).addingTimeInterval(seconds)
    }

    static func nextReadResultDeadline(_ sessions: [AgentSession], retention: ReadResultRetention, now: Date) -> Date? {
        let results = sessions.compactMap { readResultDeadline($0, retention: retention) }
        let projects = Dictionary(grouping: sessions.filter {
            !$0.isCodexInternalTask && !$0.isOpencodeSubagent && !$0.isDSHBackend
                && $0.hostTeamScope?.host == .agentOrchestrator
        }, by: { $0.hostTeamScope!.teamID })
        let idle = projects.values.compactMap { aoProjectIdleDeadline($0, retention: retention, now: now) }
        // Truly empty idle projects use a short deadline. Completed native
        // results remain until read, then use the configured retention deadline.
        return (results + idle).filter { $0 > now }.min()
    }

    /// Quiet projects retire only after native results are read. Unread results
    /// remain visible; read results follow the configured retention interval.
    /// Polling/metadata refreshes cannot extend this activity-based deadline.
    private static func aoProjectIdleDeadline(_ members: [AgentSession], retention: ReadResultRetention, now: Date) -> Date? {
        guard !members.isEmpty else { return nil }
        var lastIdle = Date.distantPast
        var delay: TimeInterval = 3
        for member in members {
            // A terminated host has no live role. Its independently completed
            // native result is nevertheless settled history, not unknown work.
            let completedExit = member.aoObservation?.isExited == true
                && !member.isAOPlaceholder && member.taskResult == .completed
                && (member.state == .done || member.state == .idle)
            guard member.hostTeamScope?.host == .agentOrchestrator,
                  member.aoObservationIsCurrent(at: now),
                  let host = member.aoObservation, host.available,
                  completedExit || (isCurrentlyVerified(member, now: now)
                    && host.activity == .idle && !host.isWorking && !host.isWaiting
                    && !host.isExited && !host.isNoSignal),
                  member.state != .working, member.state != .waiting,
                  member.pendingApproval == nil, (member.humanRequests ?? []).isEmpty,
                  !member.hasUnread,
                  !member.hasAOUnread,
                  member.taskResult == nil || member.taskResult == .completed else { return nil }
            let idleAt = max(member.turnEndedAt ?? member.stateSince, host.activityAt ?? host.updatedAt)
            guard idleAt.timeIntervalSince1970.isFinite else { return nil }
            if member.hasReadReceipt, member.taskResult != nil {
                guard let seconds = retention.seconds else { return nil }
                delay = seconds
            }
            lastIdle = max(lastIdle, max(idleAt, member.readAt ?? .distantPast))
        }
        return lastIdle.addingTimeInterval(delay)
    }

    /// How long a member's stored `working` state still counts as live Team
    /// activity. A host that exits leaves persisted `working` rows behind, and
    /// codex working rows are never TTL-pruned by the store, so this bound is
    /// the only thing that frees a dead Team. Matches the store's own active
    /// staleness floor (`SessionReducer.staleActiveAfter`, 300 s). A member that
    /// went quiet inside a long task stops counting: only a fresh check may
    /// confirm activity.
    static let teamMemberActivityWindow: TimeInterval = 300

    /// How long a successful host check stays current **inside one launch**.
    /// The daemon re-checks every ~2 s, so this only tolerates a stalled
    /// checker; it is not a launch TTL. Current validity across launches is
    /// decided by `AionUiVerificationLaunch.epoch`, so a relaunch always waits
    /// for a fresh check even when the persisted check is only seconds old.
    static let teamVerificationStallWindow: TimeInterval = 60

    /// The stored live check still attests this exact session/conversation/Team
    /// role, was produced by this process launch, and its checker has not
    /// stalled.
    static func isCurrentlyVerified(_ session: AgentSession, now: Date) -> Bool {
        if let scope = session.hostTeamScope, scope.host == .agentOrchestrator {
            guard scope.role != nil, let verifiedAt = scope.verifiedAt,
                  verifiedAt.timeIntervalSince1970.isFinite,
                  now.timeIntervalSince(verifiedAt) >= -5 else { return false }
            return now.timeIntervalSince(verifiedAt) <= teamVerificationStallWindow
        }
        guard let verification = session.attestableAionUiVerification,
              verification.launchEpoch == AionUiVerificationLaunch.epoch else { return false }
        return now.timeIntervalSince(verification.verifiedAt) <= teamVerificationStallWindow
    }

    /// Last evidence that a session was actually doing something.
    static func lastActivityAt(_ session: AgentSession) -> Date {
        var latest = max(session.updatedAt, session.stateSince)
        if let turnStart = session.turnStartedAt { latest = max(latest, turnStart) }
        if let observation = session.aoObservation {
            latest = max(latest, observation.activityAt ?? observation.updatedAt)
        }
        return latest
    }

    /// A member only counts as live Team activity when its identity is
    /// currently verified, it is genuinely working, and that evidence is recent
    /// enough that a leftover row from a stopped host cannot pin the Team busy
    /// forever. Cancelled members, unverified marks and lapsed checks never
    /// count.
    static func isActiveTeamMember(_ session: AgentSession, now: Date) -> Bool {
        isCurrentlyVerified(session, now: now) && !session.isStopped
            && session.aoObservation?.isExited != true && session.aoObservation?.isWaiting != true
            && session.aoObservation?.isNoSignal != true && session.state == .working
            && now.timeIntervalSince(lastActivityAt(session)) <= teamMemberActivityWindow
    }

    /// AO-only member summary, highest urgency first. AionUI keeps its existing
    /// lead-only semantics so this cannot change a historical contract.
    private static func aoMemberState(_ members: [AgentSession], now: Date) -> GroupedSession.TeamInfo.MemberState? {
        let verified = members.filter { isCurrentlyVerified($0, now: now) && !$0.isStopped }
        // Exact project ownership stays meaningful after a host exits. Native
        // failure/cancellation and explicit human obligations cannot disappear
        // merely because there is no longer a current orchestrator/worker role.
        let associated = members.filter { $0.aoObservationIsCurrent(at: now) }
        if associated.contains(where: { $0.pendingApproval != nil || ($0.humanRequests ?? []).isEmpty == false }) { return .waiting }
        if verified.contains(where: { $0.state == .waiting || ($0.aoObservation?.isWaiting == true
            && $0.aoObservation?.isExited != true) }) { return .waiting }
        if associated.contains(where: { $0.state == .done && $0.taskResult == .failed }) { return .failed }
        if members.contains(where: { isActiveTeamMember($0, now: now) }) { return nil }
        if associated.contains(where: { $0.isStopped }) { return .cancelled }
        if members.contains(where: { $0.aoObservation?.available == false }) { return .unknown }
        if verified.contains(where: { member in
            member.aoObservation?.isExited == true || member.aoObservation?.isNoSignal == true
                || (member.state == .idle && member.taskResult == nil
                && member.aoObservation?.activity == .unknown
                && member.aoObservation?.status != "idle"
                )
        }) { return .unknown }
        return nil
    }

    /// Sessions the bubble may show. Ordinary sessions keep the current
    /// kind/state/read filters. Sessions with a verified AionUI Team
    /// association are governed by the independent Team switch here; their
    /// row state is decided per Team in `groups` from the current lead.
    static func visible(_ sessions: [AgentSession], settings: Configuration) -> [AgentSession] {
        let base = sessions
            .filter { !$0.isOpencodeSubagent }
            .filter { !$0.isCodexInternalTask && !$0.isDSHBackend }
            .filter { settings.showDSHTUI || !$0.isDSHTUI }
            .filter { settings.showAgentOrchestratorTeams || !$0.isAOHostSession }
        let teams = base.filter { $0.hostTeamScope != nil }
        let normal = base
            .filter { $0.hostTeamScope == nil }
            .filter { !settings.hiddenKinds.contains($0.agentKind) }
            .filter { settings.minStateFilter.includes($0.state) || $0.hasUnread || isReadResult($0) || ($0.state == .done && $0.hasReadReceipt) }
            .filter { $0.agentKind != .codex || ($0.state != .done && $0.state != .idle) || $0.hasUnread || isReadResult($0) || ($0.state == .done && $0.hasReadReceipt) }
            .filter {
                guard let deadline = readResultDeadline($0, retention: settings.readResultRetention) else { return true }
                return settings.now < deadline
            }
        let shownTeams = teams.filter { session in
            guard let host = session.hostTeamScope?.host else { return false }
            switch host {
            case .aionUI: return settings.showAionUiTeams
            case .agentOrchestrator: return settings.showAgentOrchestratorTeams
            }
        }
        return normal + shownTeams
    }

    /// The Team row disappears exactly when its lead would: the lead alone
    /// decides state, unread and read-result retention.
    private static func leaderQualifies(_ leader: AgentSession, settings: Configuration) -> Bool {
        guard settings.minStateFilter.includes(leader.state) || leader.hasUnread || isReadResult(leader) || (leader.state == .done && leader.hasReadReceipt) else { return false }
        guard leader.agentKind != .codex || (leader.state != .done && leader.state != .idle) || leader.hasUnread || isReadResult(leader) || (leader.state == .done && leader.hasReadReceipt) else { return false }
        guard let deadline = readResultDeadline(leader, retention: settings.readResultRetention) else { return true }
        return settings.now < deadline
    }

    static func groups(_ sessions: [AgentSession], settings: Configuration, expanded: Bool = false) -> [GroupedSession] {
        // 1. Filter: Teams stay whole under their own switch; ordinary sessions
        //    keep the current filters.
        let filtered = Self.visible(sessions, settings: settings)
        let teamSessions = filtered.filter { $0.hostTeamScope != nil }
        let normalSessions = filtered.filter { $0.hostTeamScope == nil }

        // 2. Teams collapse first: one stable row per verified host/team id,
        //    before kind collapsing, state sorting and the row cap below.
        //    State-bearing fields come from the current lead; the membership
        //    list itself never contributes the lead's state.
        struct TeamKey: Hashable { let host: HostKind; let teamID: String }
        var teamGroups: [GroupedSession] = []
        var byTeam: [TeamKey: [AgentSession]] = [:]
        for session in teamSessions {
            guard let scope = session.hostTeamScope else { continue }
            byTeam[TeamKey(host: scope.host, teamID: scope.teamID), default: []].append(session)
        }
        for (key, members) in byTeam {
            if key.host == .agentOrchestrator,
               let deadline = aoProjectIdleDeadline(members, retention: settings.readResultRetention, now: settings.now),
               settings.now >= deadline { continue }
            let lead: AgentSession?
            if key.host == .agentOrchestrator {
                // This is a display representative of the project, not the
                // parent of all workers. Multiple orchestrators are deterministic.
                lead = members.filter { $0.hostTeamScope?.role == .lead }.sorted {
                    let a = Self.isCurrentlyVerified($0, now: settings.now)
                    let b = Self.isCurrentlyVerified($1, now: settings.now)
                    if a != b { return a }
                    if rank($0.state) != rank($1.state) { return rank($0.state) > rank($1.state) }
                    return $0.id < $1.id
                }.first
            } else { lead = members.first { $0.hostTeamScope?.role == .lead } }
            let projectUnread = key.host == .agentOrchestrator && members.contains(where: \.hasUnread)
            let membersWorking = members.contains { Self.isActiveTeamMember($0, now: settings.now) }
            let memberState = key.host == .agentOrchestrator
                ? Self.aoMemberState(members.filter { $0.id != lead?.id }, now: settings.now) : nil
            if let lead {
                // A read/expired leader is evicted only when no verified member
                // is still working or asking for attention: member activity
                // keeps the Team row, but the row's state, timer and identity
                // stay the leader's.
                if !leaderQualifies(lead, settings: settings), !membersWorking, memberState == nil, !projectUnread { continue }
            } else if !members.contains(where: {
                Self.isActiveTeamMember($0, now: settings.now) || leaderQualifies($0, settings: settings)
            }), memberState == nil, !projectUnread {
                // A lead-less Team (never verified, or a cached verification
                // that was dropped) survives only while some member would
                // still be shown on its own. It must not revive a result that
                // was already read and evicted.
                continue
            }
            let carrier = lead ?? members.min(by: { $0.id < $1.id })!
            let unreadResults = members.filter {
                !$0.isAOPlaceholder && ($0.state == .done || $0.state == .idle)
                    && !$0.isStopped && $0.notificationVersion > $0.readThroughVersion
            }
            let unreadNativeResult: GroupedSession.TeamInfo.UnreadNativeResult? = unreadResults.isEmpty ? nil
                : unreadResults.allSatisfy { $0.taskResult == .completed } ? .completed : .unknown
            let unreadMembers = key.host == .agentOrchestrator ? members.filter {
                !$0.isAOPlaceholder && !$0.isStopped && $0.notificationVersion > $0.readThroughVersion
            } : []
            let navigationSession = unreadMembers.filter {
                $0.aoObservationIsCurrent(at: settings.now)
                    && $0.aoObservation?.projectID == key.teamID
            }.sorted {
                // Explicit human waits first, then newest unread native result.
                // Host polling timestamps cannot reorder or renew a result.
                if ($0.state == .waiting) != ($1.state == .waiting) { return $0.state == .waiting }
                let a = $0.turnEndedAt ?? $0.updatedAt, b = $1.turnEndedAt ?? $1.updatedAt
                return a != b ? a > b : $0.id < $1.id
            }.first
            // Verified members carry the host team name; an unverified mark
            // keeps the neutral Team identity instead of borrowing a member's.
            let name = members.compactMap { $0.hostTeamScope?.teamName }.first
                ?? (key.host == .aionUI ? "AionUI Team" : "Agent Orchestrator Team")
            let receipts = key.host == .agentOrchestrator ? Dictionary(
                members.flatMap { $0.aoAttentionReceipts ?? [] }.map { ($0.id, $0) },
                uniquingKeysWith: { a, b in a.version >= b.version ? a : b }
            ).values.sorted { $0.id < $1.id } : []
            teamGroups.append(GroupedSession(session: carrier, count: 1,
                                             team: .init(host: key.host, id: key.teamID, name: name,
                                                         leaderMissing: lead == nil,
                                                         identityUnconfirmed: lead.map {
                                                             !Self.isCurrentlyVerified($0, now: settings.now)
                                                         } ?? false,
                                                         activityUnconfirmed: lead.map {
                                                             $0.state == .working && settings.now.timeIntervalSince(
                                                                Self.lastActivityAt($0)) > Self.teamMemberActivityWindow
                                                         } ?? false,
                                                         membersWorking: membersWorking,
                                                         hasCurrentIdleMember: key.host == .agentOrchestrator && members.contains {
                                                             Self.isCurrentlyVerified($0, now: settings.now)
                                                                 && $0.state != .working && $0.state != .waiting
                                                                 && $0.aoObservation?.activity == .idle
                                                                 && $0.aoObservation?.isExited == false
                                                                 && $0.aoObservation?.isWaiting == false
                                                                 && $0.aoObservation?.isNoSignal == false
                                                         },
                                                         unreadNativeResult: key.host == .agentOrchestrator ? unreadNativeResult : nil,
                                                         unreadNavigationSession: navigationSession,
                                                         unreadNativeCount: unreadMembers.count,
                                                         memberState: memberState,
                                                         aoAttentionReceipts: receipts)))
        }

        // 3. Sort ordinary sessions (grouped mode always sorts by kind first).
        var sorted = normalSessions
        let sortByKind = settings.sessionGrouping == .byKind || settings.groupByKind
        if sortByKind {
            sorted.sort {
                if $0.groupKey != $1.groupKey {
                    return $0.groupKey < $1.groupKey
                }
                if rank($0.state) != rank($1.state) { return rank($0.state) > rank($1.state) }
                return $0.updatedAt > $1.updatedAt
            }
        } else {
            sorted.sort {
                if rank($0.state) != rank($1.state) { return rank($0.state) > rank($1.state) }
                return $0.updatedAt > $1.updatedAt
            }
        }

        // 4. Collapse ordinary sessions by agent kind when grouped (highest-priority session per kind).
        var result: [GroupedSession]
        if settings.sessionGrouping == .byKind {
            var seen: [String: Int] = [:]
            result = []
            for s in sorted {
                if s.hasAOUnread || s.agentKind == .codex || s.agentKind == .antigravity || s.agentKind == .opencode {
                    result.append(GroupedSession(session: s, count: 1))
                    continue
                }
                if let idx = seen[s.groupKey] {
                    result[idx] = GroupedSession(session: result[idx].session, count: result[idx].count + 1)
                } else {
                    seen[s.groupKey] = result.count
                    result.append(GroupedSession(session: s, count: 1))
                }
            }
        } else {
            result = sorted.map { GroupedSession(session: $0, count: 1) }
        }

        // 5. Merge Team rows: they never merge with ordinary rows. Ordering
        //    follows the same kind/rank/time keys; a missing lead sorts like
        //    idle instead of borrowing member activity.
        result.append(contentsOf: teamGroups)
        result.sort {
            if sortByKind, $0.session.groupKey != $1.session.groupKey {
                return $0.session.groupKey < $1.session.groupKey
            }
            let a = $0.team?.leaderMissing == true ? AgentState.idle : $0.session.state
            let b = $1.team?.leaderMissing == true ? AgentState.idle : $1.session.state
            if rank(a) != rank(b) { return rank(a) > rank(b) }
            if $0.session.updatedAt != $1.session.updatedAt { return $0.session.updatedAt > $1.session.updatedAt }
            return $0.id < $1.id
        }

        // 6. Cap to maxSessions (list/compact); carousel shows all groups.
        if expanded || settings.displayMode == .carousel {
            return result
        }
        return Array(result.prefix(settings.maxSessions))
    }

    struct Row {
        let session: AgentSession
        /// Set only for an aggregated AionUI Team row. State, message, lamp,
        /// elapsed and unread then follow the current lead (this session);
        /// a missing lead stays explicitly unknown instead of borrowing a
        /// member's state.
        var team: GroupedSession.TeamInfo? = nil
        var customMessages = false
        var navigationSessionID: String { session.id }
        var isAOProjectEntry: Bool { team?.host == .agentOrchestrator }
        var unreadNavigationSessionID: String? { team?.unreadNavigationSession?.id }
        var unreadNativeCount: Int { team?.unreadNativeCount ?? 0 }
        var unreadNavigationHint: String {
            guard let target = team?.unreadNavigationSession else {
                return NSLocalizedString("ao.project.unread.unavailable", comment: "")
            }
            return NSLocalizedString("ao.project.unread.hint", comment: "") + " · "
                + (target.aoObservation?.displayName ?? target.aoBinding?.sessionID ?? target.id)
        }
        var line: (PetMood) -> String = { _ in "" }
        var fallbackMessage: String? = nil
        private var leaderMissing: Bool { team?.leaderMissing == true }
        /// The Team's lead is known by its cached role, but its live check is no
        /// longer current. The last known result may stay visible; it is never
        /// presented as the current state.
        private var identityUnconfirmed: Bool { team?.identityUnconfirmed == true }
        /// The lead claims `.working` without fresh native activity evidence.
        private var activityUnconfirmed: Bool { team?.activityUnconfirmed == true }
        /// The Team's own work still runs through verified members. Their real
        /// activity replaces the lead's terminal result or its stale/unconfirmed
        /// claim, while approval, failure and cancellation keep their meaning.
        private var membersTakeOver: Bool {
            guard let team, team.membersWorking, !team.leaderMissing else { return false }
            guard session.pendingApproval == nil, !session.isStopped else { return false }
            if session.opencodeDisconnectedAt != nil || session.dshDisconnectedAt != nil { return false }
            switch session.state {
            case .done: return session.taskResult != .failed
            case .idle: return true
            case .working: return activityUnconfirmed || identityUnconfirmed
            case .waiting, .registered: return false
            }
        }
        private var isAOTeam: Bool { team?.host == .agentOrchestrator }
        private var aoUnreadResultLabel: String? {
            switch team?.unreadNativeResult {
            case .completed: return "回合已完成，未读"
            case .unknown: return "回合结果未知，未读"
            case nil: return nil
            }
        }
        var aoAttentionReceipts: [AOAttentionReceipt] {
            isAOTeam ? (team?.aoAttentionReceipts ?? []) : (session.aoAttentionReceipts ?? [])
        }
        /// AO's host lifecycle can prove the session exited even when the last
        /// native Hook still says working/waiting. That is an unknown result,
        /// never a success, and never rewrites the native turn record.
        private var hostExited: Bool {
            guard team == nil, !session.isAOPlaceholder, let observation = session.aoObservation,
                  observation.isExited else { return false }
            return session.state == .working || session.state == .waiting || session.state == .registered
        }
        private var hostExitLabel: String {
            session.aoObservation.map(AOHostMapping.message(for:)) ?? "AO 会话已退出"
        }
        /// A bound native row can be idle without a native turn result. AO's
        /// no-signal/PR/idle state is then explicitly unknown, not success.
        private var hostUnknown: Bool {
            guard team == nil, !session.isAOPlaceholder, let observation = session.aoObservation,
                  observation.isUnknownState, session.state == .idle,
                  session.taskResult == nil, !session.isStopped else { return false }
            return true
        }
        /// A current AO wait is independent of a native turn's outcome. Reading
        /// either source cannot resolve it; this only overrides the display.
        private var hostWaiting: Bool {
            guard let observation = session.aoObservation, observation.available,
                  observation.isWaiting, !observation.isExited,
                  session.aoBinding?.isCurrent == true,
                  session.aoBinding?.sessionID == observation.sessionID,
                  session.pendingApproval == nil else { return false }
            return true
        }
        private var hostWaitingLabel: String? {
            guard hostWaiting, let observation = session.aoObservation else { return nil }
            return observation.activity == .waitingInput ? "等待用户输入" : "等待人工处理"
        }
        /// A member prompt/failure/cancel/unknown must not be masked by an idle
        /// AO leader. Only AO Team rows get this override; AionUI keeps its
        /// existing lead-only contract.
        private var memberAttention: GroupedSession.TeamInfo.MemberState? {
            guard isAOTeam, let memberState = team?.memberState,
                  session.state == .idle, session.pendingApproval == nil,
                  !session.isStopped, !identityUnconfirmed, !activityUnconfirmed else { return nil }
            return memberState
        }
        private var memberAttentionLabel: String? {
            switch memberAttention {
            case .waiting: return "成员等待人工处理"
            case .failed: return "成员失败"
            case .cancelled: return "成员已停止"
            case .unknown: return "成员结果未知"
            case nil: return nil
            }
        }
        private func memberStateLabel(_ state: GroupedSession.TeamInfo.MemberState) -> String {
            switch state {
            case .waiting: return "成员等待人工处理"
            case .failed: return "成员失败"
            case .cancelled: return "成员已停止"
            case .unknown: return "成员结果未知"
            }
        }
        private var leaderlessMemberState: GroupedSession.TeamInfo.MemberState? {
            guard isAOTeam, leaderMissing else { return nil }
            return team?.memberState
        }
        /// A Team row never claims the leader's own completion as the Team's
        /// outcome: there is no Team-level completion evidence in this batch, so
        /// the leader's finished turn stays visible while the Team's completion
        /// is explicitly unconfirmed.
        private var teamWithholdsCompletion: Bool {
            guard team != nil, !leaderMissing else { return false }
            return session.state == .done && session.taskResult == .completed
                && session.opencodeDisconnectedAt == nil && session.dshDisconnectedAt == nil
                && !session.isStopped && session.pendingApproval == nil
        }
        /// A lead-less Team row never surfaces a member's approval prompt or
        /// waiting animation; a verified lead's own approval still shows.
        var showsPendingApproval: Bool { session.pendingApproval != nil && team?.leaderMissing != true }
        var isWaitingDisplay: Bool {
            if isAOTeam { return ["等待中", "等待用户输入", "等待人工处理"].contains(stateLabel) }
            if hostExited { return false }
            if leaderMissing { return leaderlessMemberState == .waiting }
            if hostWaiting { return true }
            return (session.state == .waiting || memberAttention == .waiting) && team?.leaderMissing != true
        }
        /// A displayed row that asks the user to act: an Allow/Deny prompt, a
        /// turn blocked on input, or a failed result. A lead-less Team shows an
        /// explicit unknown row, so it exposes no member prompt or outcome here.
        /// Used only to decide whether the shared task bubble may pass clicks
        /// through; it never resolves or acknowledges anything.
        var requiresManualHandling: Bool {
            // This visible explicit control must remain clickable even when
            // ordinary task text is configured to pass clicks through.
            if isAOProjectEntry && unreadNativeCount > 0 { return true }
            if aoAttentionReceipts.contains(where: \.hasUnread) { return true }
            if isAOTeam, team?.memberState == .waiting { return true }
            if leaderMissing {
                return isAOTeam && (leaderlessMemberState == .waiting || leaderlessMemberState == .failed)
            }
            if showsPendingApproval { return true }
            if hostExited { return false }
            if hostWaiting { return true }
            if memberAttention == .waiting || memberAttention == .failed { return true }
            if session.isStopped { return false }
            if isWaitingDisplay { return true }
            if session.state == .done, session.taskResult == .failed, !membersTakeOver { return true }
            return false
        }
        var usesTaskDetails: Bool {
            session.isAOHostSession || session.agentKind == .codex || session.agentKind == .antigravity
                || session.agentKind == .opencode || session.agentKind == .dsh || session.agentKind == .pi
        }

        /// AO-only rows and AO Team targets are clickable only to surface the
        /// explicit AO navigation limitation. A bound native row preserves its
        /// existing exact native route; it does not become an AO target.
        var isAOTeamTarget: Bool {
            session.hostTeamScope?.host == .agentOrchestrator
        }
        private var hasNativeExactRoute: Bool {
            if session.agentKind == .dsh { return session.dsh?.navigationSocket != nil }
            return session.agentKind == .antigravity || session.validAionUiConversation != nil || session.terminalProgram != nil
                || (session.agentKind == .codex && session.codexDesktop)
                || (session.agentKind == .opencode && session.opencodeNavigationSocket != nil)
                || (session.agentKind == .opencode && session.opencodeProcessID != nil)
        }
        /// Any displayed session whose terminal we know can be jumped to, whatever
        /// its state (working, waiting, done). Its tab may still be open.
        var canFocusTerminal: Bool {
            if session.isCodexInternalTask || session.isDSHBackend || session.isDSHTUI { return false }
            if session.isAOPlaceholder || isAOTeamTarget { return true }
            if session.isAOHostSession {
                // Historical/conflicted claims retain their own native target
                // for viewing/reading; this is never an AO navigation.
                if session.aoBinding?.isCurrent == false { return hasNativeExactRoute }
                guard session.aoObservation?.available == true else { return false }
                if session.aoObservation?.projectID == AOHostMapping.standaloneProjectID { return true }
                return hasNativeExactRoute
            }
            return hasNativeExactRoute
        }
        var navigationHint: String {
            if session.isAOPlaceholder || isAOTeamTarget {
                return "点击打开 AO 项目编排器；不可用时打开项目看板"
            }
            if session.isAOHostSession {
                if session.aoBinding?.isCurrent == false {
                    return canFocusTerminal ? "点击打开对应原生会话（AO 归属冲突，仅原生任务）"
                        : "无可用的精确会话跳转"
                }
                return canFocusTerminal ? "点击打开对应原生会话（AO 关联需仍有效）" : "无可用的精确会话跳转"
            }
            if session.agentKind == .opencode, session.validAionUiConversation == nil,
               (session.opencodeNavigationSocket ?? "").isEmpty {
                return NSLocalizedString("navigation.opencode.hint", comment: "")
            }
            return "点击打开对应会话"
        }

        /// Kept outside configurable/truncated task tokens by SessionBubbleRow.
        var associationNotice: String? { session.isAOPlaceholder ? "关联未确认" : nil }
        var titleText: String {
            if let team { return team.name }
            if let observation = session.aoObservation {
                let role = observation.role == .orchestrator ? "AO Leader" : "AO Worker"
                let body = session.title ?? observation.displayName
                    ?? String(observation.sessionID.prefix(12))
                let title = body.hasPrefix("AO ") ? body : role + " · " + body
                if session.isAOPlaceholder {
                    return "关联未确认 · " + title + "（" + observation.sessionID + "）"
                }
                return title
            }
            return session.title ?? (session.agentKind == .codex ? "Codex" : session.agentKind == .opencode ? "OpenCode" : session.agentKind == .dsh ? "DSH" : session.agentKind == .pi ? "Pi" : "Antigravity") + " · " + String(session.id.prefix(8))
        }
        func visibleTokens(_ layout: BubbleLayout) -> [BubbleTokenItem] {
            layout.tokens.filter {
                guard $0.isVisible else { return false }
                // A lead-less Team row exposes none of the carrier member's
                // model, project or timing; only the explicit unknown remains.
                if leaderMissing && [.model, .project, .elapsed].contains($0.token) { return false }
                // Never render the same Team copy twice: the state label is
                // dropped when the message already carries it (the neutral
                // "主Agent状态未知" row, or a Team row withheld while members
                // still work).
                if team != nil, $0.token == .stateLabel, stateLabel == messageText { return false }
                return ($0.token != .title || session.title != nil || team != nil) &&
                    ($0.token != .model || session.model != nil) &&
                    !(usesTaskDetails && ($0.token == .title || $0.token == .separator))
            }
        }
        var projectName: String {
            if let observation = session.aoObservation {
                return observation.projectName ?? observation.projectID
            }
            return session.project.map { ($0 as NSString).lastPathComponent } ?? session.id
        }

        var elapsedStart: Date { usesTaskDetails ? (session.turnStartedAt ?? session.stateSince) : session.stateSince }

        /// The leader's own state label without any Team-level qualification.
        private var leaderStateLabel: String {
            guard usesTaskDetails else { return session.state.rawValue.capitalized }
            if session.isAOPlaceholder, let observation = session.aoObservation {
                return AOHostMapping.message(for: observation)
            }
            switch session.state {
            case .registered: return "已连接"
            case .working: return "工作中"
            case .waiting: return "等待中"
            case .done:
                if session.agentKind == .pi && session.taskResult == nil { return "结果未知" }
                if session.agentKind == .opencode && session.opencodeDisconnectedAt != nil { return "连接中断" }
                if session.agentKind == .dsh && (session.dshDisconnectedAt != nil || session.dsh?.result == .unknown) { return "结果未知" }
                if let observation = session.aoObservation, observation.isUnknownState, session.taskResult == nil {
                    return AOHostMapping.message(for: observation)
                }
                switch session.taskResult {
                case .cancelled: return "已停止"
                case .failed: return "失败"
                default: return "已完成"
                }
            case .idle:
                if let observation = session.aoObservation, observation.isUnknownState, session.taskResult == nil {
                    return AOHostMapping.message(for: observation)
                }
                return "空闲"
            }
        }

        var stateLabel: String {
            if isAOTeam {
                // A project summary reports observed project activity. Missing
                // native leader hooks do not make known member activity unknown.
                if !leaderMissing, !identityUnconfirmed {
                    if session.pendingApproval != nil || session.state == .waiting {
                        return hostWaitingLabel ?? "等待中"
                    }
                    if session.isStopped { return "已停止" }
                    if session.state == .done, session.taskResult == .failed { return "失败" }
                    if session.state == .working, !activityUnconfirmed {
                        return hostWaitingLabel ?? "工作中"
                    }
                }
                if let state = team?.memberState {
                    switch state {
                    case .waiting: return "等待中"
                    case .failed: return "失败"
                    case .cancelled: return "已停止"
                    case .unknown: return "等待状态更新"
                    }
                }
                if team?.membersWorking == true { return "工作中" }
                if leaderMissing {
                    return aoUnreadResultLabel ?? (team?.hasCurrentIdleMember == true ? "空闲" : "等待状态更新")
                }
                if identityUnconfirmed { return "等待状态更新" }
                if session.pendingApproval != nil { return "等待中" }
                if let observation = session.aoObservation, observation.available {
                    if observation.isWaiting { return hostWaitingLabel ?? "等待中" }
                    if observation.isWorking { return "工作中" }
                    if observation.isExited { return aoUnreadResultLabel ?? hostExitLabel }
                    if !observation.isNoSignal,
                       observation.activity == .idle || observation.status == "idle" {
                        // Idle is an explicit host activity, not a turn-success claim.
                        return aoUnreadResultLabel ?? "空闲"
                    }
                }
                return "等待状态更新"
            }
            if leaderMissing {
                if let memberState = leaderlessMemberState {
                    return (team?.membersWorking == true
                        ? "主Agent状态未知，成员执行中" : "主Agent状态未知") + "；" + memberStateLabel(memberState)
                }
                if let memberAttentionLabel {
                    return (team?.membersWorking == true
                        ? "主Agent状态未知，成员执行中" : "主Agent状态未知") + "；" + memberAttentionLabel
                }
                return team?.membersWorking == true ? "主Agent状态未知，成员执行中" : "主Agent状态未知"
            }
            if let memberAttentionLabel { return memberAttentionLabel }
            if hostExited { return hostExitLabel }
            if let hostWaitingLabel { return hostWaitingLabel }
            if hostUnknown { return "结果未知" }
            if membersTakeOver { return "成员执行中" }
            if identityUnconfirmed {
                // Keep the known historical result, never as the current state.
                if session.state == .done && session.taskResult == .completed {
                    return "主Agent已完成，当前无法确认"
                }
                return leaderStateLabel + "，当前无法确认"
            }
            if activityUnconfirmed { return "主Agent活动未确认" }
            if teamWithholdsCompletion { return "主Agent回合已完成，团队完成未确认" }
            return leaderStateLabel
        }
        var messageText: String {
            if isAOTeam { return stateLabel }
            if leaderMissing { return stateLabel }
            if hostExited { return stateLabel }
            if hostWaiting { return stateLabel }
            if hostUnknown { return stateLabel }
            if memberAttentionLabel != nil || membersTakeOver || identityUnconfirmed || activityUnconfirmed || teamWithholdsCompletion {
                return stateLabel
            }
            if session.state == .waiting, session.humanRequests != nil {
                return session.message ?? "等待你的回复"
            }
            if usesTaskDetails { return session.message ?? stateLabel }
            let message = session.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? (fallbackMessage ?? stateLabel) : message
        }

        private func moodFor(_ state: AgentState) -> PetMood {
            switch state {
            case .working, .registered: return .working
            case .waiting:              return .waiting
            case .done:                 return .done
            case .idle:                 return .idle
            }
        }

        enum Lamp { case running, attention, success, failure, unknown, off }

        /// A display decision only: acknowledgement never resolves a pending request.
        var lamp: Lamp {
            if isAOTeam {
                switch stateLabel {
                case "空闲", "已停止": return .off
                case "工作中": return .running
                case "等待中", "等待用户输入", "等待人工处理": return .attention
                case "失败": return .failure
                case "回合已完成，未读": return .success
                default: return .unknown
                }
            }
            if team == nil, session.isAOPlaceholder, let observation = session.aoObservation,
               observation.isUnknownState, !session.isStopped, session.pendingApproval == nil {
                return .unknown
            }
            if leaderMissing {
                if let memberAttention = team?.memberState {
                    switch memberAttention {
                    case .waiting: return .attention
                    case .failed: return .failure
                    case .cancelled: return .off
                    case .unknown: return .unknown
                    }
                }
                return team?.membersWorking == true ? .running : .unknown
            }
            if let memberAttention {
                switch memberAttention {
                case .waiting: return .attention
                case .failed: return .failure
                case .cancelled: return .off
                case .unknown: return .unknown
                }
            }
            if hostExited { return .unknown }
            if hostWaiting { return .attention }
            if hostUnknown { return .unknown }
            if session.isStopped { return .off }
            if session.pendingApproval != nil {
                return session.hasReadReceipt ? .off : .attention
            }
            switch session.indicator {
            case .attention:
                // A stored waiting/human prompt keeps its meaning.
                return .attention
            case .running:
                if membersTakeOver { return .running }
                // Cached `running` is only current activity while both the
                // native evidence and the identity are current.
                if identityUnconfirmed || activityUnconfirmed { return .unknown }
                return .running
            case .read, .idle:
                return membersTakeOver ? .running : .off
            case .unread:
                // Disconnection is not a successful result, even if an earlier
                // native completion is still stored in the same session.
                if session.opencodeDisconnectedAt != nil || session.dshDisconnectedAt != nil { return .unknown }
                switch session.taskResult {
                case .failed: return .failure
                case .cancelled: return .off
                case .completed:
                    if membersTakeOver { return .running }
                    if identityUnconfirmed { return .unknown }
                    // A Team row never presents the lead's own success as the
                    // Team's result.
                    return team == nil ? .success : .unknown
                case nil: return .unknown
                }
            }
        }
        var dotIsLit: Bool { lamp != .off }
        var dotSpins: Bool { dotIsLit }
        var indicatorLabel: String {
            if leaderMissing { return stateLabel }
            if memberAttentionLabel != nil { return stateLabel }
            if hostExited { return stateLabel }
            if hostWaiting { return stateLabel }
            if hostUnknown { return stateLabel }
            if membersTakeOver { return "成员执行中" }
            if identityUnconfirmed || activityUnconfirmed { return stateLabel }
            // A Team row's dot always carries the row's own state copy.
            if team != nil { return stateLabel }
            switch lamp {
            case .running: return "执行中"
            case .attention: return "等待人工处理，未读"
            case .success: return "成功，未读"
            case .failure: return "失败，未读"
            case .unknown: return "结果未知，未读"
            case .off: return session.hasReadReceipt || session.isStopped ? "已读，灯已熄灭" : "空闲，灯已熄灭"
            }
        }
        static let runningRGB: (Double, Double, Double) = (0x3B / 255.0, 0x82 / 255.0, 0xF6 / 255.0)
        static let attentionRGB: (Double, Double, Double) = (0xF5 / 255.0, 0x9E / 255.0, 0x0B / 255.0)
        static let failureRGB: (Double, Double, Double) = (0xEF / 255.0, 0x44 / 255.0, 0x44 / 255.0)
        static let successRGB: (Double, Double, Double) = (0.13, 0.77, 0.37)
        static let offRGB: (Double, Double, Double) = (0x6B / 255.0, 0x72 / 255.0, 0x80 / 255.0)
        /// A Team row's unknown means "the Team's completion is not confirmed":
        /// neither failure nor success, and deliberately **not** the read/off
        /// gray, so an unconfirmed-but-unread Team is never mistaken for an
        /// acknowledged one. Unread stays lit and breathing in this colour.
        static let teamUnconfirmedRGB: (Double, Double, Double) = (0x8B / 255.0, 0x5C / 255.0, 0xF6 / 255.0)

        var indicatorRGB: (Double, Double, Double) {
            switch lamp {
            case .running: return Self.runningRGB
            case .attention: return Self.attentionRGB
            case .failure: return Self.failureRGB
            case .unknown: return team != nil || session.isAOHostSession ? Self.teamUnconfirmedRGB : Self.failureRGB
            case .success: return Self.successRGB
            case .off: return Self.offRGB
            }
        }
        func elapsedString(since date: Date, now: Date) -> String {
            let s = max(0, Int(now.timeIntervalSince(date)))
            if s < ELAPSED_SECONDS_LIMIT { return "\(s)s" }
            let m = s / 60
            if m < 60 { return "\(m)m" }
            return "\(m / 60)h \(m % 60)m"
        }

        /// The elapsed text for this row. A Team row labels the timer as the
        /// current lead's so nobody reads it as the Team's earliest member.
        func elapsedText(since date: Date, now: Date) -> String {
            let text = elapsedString(since: date, now: now)
            return team == nil ? text : "主Agent计时 " + text
        }
    }
}

extension BubbleSettings {
    var presentationConfiguration: BubblePresentation.Configuration {
        .init(hiddenKinds: hiddenKinds, minStateFilter: minStateFilter, sessionGrouping: sessionGrouping,
              groupByKind: groupByKind, displayMode: displayMode, maxSessions: maxSessions,
              showAionUiTeams: showAionUiTeams,
              showAgentOrchestratorTeams: aoExperimentActive,
              showDSHTUI: showDSHTUI,
              now: Date(), readResultRetention: readResultRetention)
    }

    /// Whether one session may drive pet speech and state under the Team rules:
    /// a shown Team speaks only through its current lead; every member of a
    /// hidden Team stays silent; ordinary sessions keep the per-kind filter.
    func allowsAgentActivity(_ session: AgentSession) -> Bool {
        guard showDSHTUI || !session.isDSHTUI else { return false }
        guard aoExperimentActive || !session.isAOHostSession else { return false }
        if let team = session.hostTeamScope {
            switch team.host {
            case .aionUI:
                return showAionUiTeams && team.role == .lead
            case .agentOrchestrator:
                return aoExperimentActive && team.role == .lead
            }
        }
        return !hiddenKinds.contains(session.agentKind)
    }
}
