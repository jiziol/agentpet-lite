import Foundation

/// Agent Orchestrator is an independent host: it owns projects, orchestrator
/// and worker sessions, while the native agent keeps its own source identity.
/// These types carry only host facts observed through AO's documented read
/// surface. They never stand in for a native hook result.
public enum AOHostRole: String, Codable, Sendable {
    case orchestrator
    case worker
}

public enum AOHostActivity: String, Codable, Sendable {
    case active
    case idle
    case waitingInput = "waiting_input"
    case blocked
    case exited
    case unknown
}

public enum AOHostTeamRole: String, Codable, Sendable {
    case lead
    case teammate
}

/// A display scope for the shared Team presentation. Production AO scopes are
/// projects: every session with the same explicit project ID shares one bubble.
/// This does not claim a historical worker→orchestrator creation relationship.
public struct AOOrchestration: Codable, Equatable, Sendable {
    public var teamID: String
    public var teamName: String
    public var role: AOHostTeamRole
    /// The AO session that owns the orchestration context, when evidence names
    /// one. A lead may name itself.
    public var orchestratorSessionID: String?

    public init(teamID: String, teamName: String, role: AOHostTeamRole,
                orchestratorSessionID: String? = nil) {
        self.teamID = teamID
        self.teamName = teamName
        self.role = role
        self.orchestratorSessionID = orchestratorSessionID
    }

    public var valid: Bool {
        AOHostObservation.validID(teamID) && AOHostObservation.validLabel(teamName, limit: 240)
            && (orchestratorSessionID == nil || AOHostObservation.validID(orchestratorSessionID!))
    }
}

/// One AO session snapshot. Only fields needed for observation/association are
/// decoded; prompts, conversation bodies, reasoning and credentials are never
/// part of this model.
public struct AOHostObservation: Codable, Equatable, Sendable {
    public var sessionID: String
    public var projectID: String
    public var projectName: String?
    public var role: AOHostRole
    public var harness: String
    public var displayName: String?
    public var branch: String?
    public var status: String
    public var displayStatus: String?
    public var activity: AOHostActivity
    public var activityAt: Date?
    public var isTerminated: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastEventAt: Date?
    public var observedAt: Date
    public var instanceID: String
    /// False after AO became unreachable. The last row is history, not current
    /// evidence, and must not claim a live state.
    public var available: Bool
    public var orchestration: AOOrchestration?

    public init(sessionID: String, projectID: String, projectName: String? = nil,
                role: AOHostRole, harness: String, displayName: String? = nil,
                branch: String? = nil, status: String, displayStatus: String? = nil,
                activity: AOHostActivity, activityAt: Date? = nil, isTerminated: Bool,
                createdAt: Date, updatedAt: Date, lastEventAt: Date? = nil,
                observedAt: Date, instanceID: String, available: Bool = true,
                orchestration: AOOrchestration? = nil) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.projectName = projectName
        self.role = role
        self.harness = harness
        self.displayName = displayName
        self.branch = branch
        self.status = status
        self.displayStatus = displayStatus
        self.activity = activity
        self.activityAt = activityAt
        self.isTerminated = isTerminated
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastEventAt = lastEventAt
        self.observedAt = observedAt
        self.instanceID = instanceID
        self.available = available
        self.orchestration = orchestration
    }

    public static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._:-]{1,160}$", options: .regularExpression) != nil
    }

    public static func validInstanceID(_ value: String) -> Bool {
        value.range(of: "^apprun-[A-Za-z0-9-]{6,80}$", options: .regularExpression) != nil
    }

    public static func validHarness(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil
    }

    public static func validLabel(_ value: String, limit: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= limit else { return false }
        return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public var valid: Bool {
        guard Self.validID(sessionID), Self.validID(projectID), Self.validHarness(harness),
              Self.validInstanceID(instanceID),
              status.utf8.count <= 64, !status.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              displayStatus == nil || (displayStatus!.utf8.count <= 64
                && !displayStatus!.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })),
              projectName == nil || Self.validLabel(projectName!, limit: 240),
              displayName == nil || Self.validLabel(displayName!, limit: 240),
              branch == nil || Self.validLabel(branch!, limit: 240),
              createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite,
              observedAt.timeIntervalSince1970.isFinite,
              activityAt == nil || activityAt!.timeIntervalSince1970.isFinite,
              lastEventAt == nil || lastEventAt!.timeIntervalSince1970.isFinite,
              updatedAt >= createdAt.addingTimeInterval(-5),
              orchestration == nil || orchestration!.valid else { return false }
        return true
    }

    /// A real host process that stopped is not a successful turn.
    public var isExited: Bool {
        isTerminated || activity == .exited || status == "exited" || status == "terminated"
            || displayStatus == "Exited" || displayStatus == "Terminated"
            || displayStatus == "Interrupted"
    }

    public var isWaiting: Bool {
        activity == .waitingInput || activity == .blocked
            || status == "needs_input" || status == "waiting_input" || status == "blocked"
            || displayStatus == "Blocked"
    }

    public var isWorking: Bool {
        !isExited && !isWaiting && (activity == .active || status == "working"
            || ["Working", "Reviewing", "Review scheduled", "Review pending",
                "Fixing CI failures", "Addressing comments"].contains(displayStatus ?? ""))
    }

    public var isNoSignal: Bool {
        !isExited && !isWaiting && (status == "no_signal" || displayStatus == "No signal")
    }

    /// PR and review states are host context, never proof that the current turn
    /// succeeded. They intentionally fall through to an unknown/idle result.
    public var isPullRequestState: Bool {
        ["pr_open", "draft", "ci_failed", "review_pending", "changes_requested",
         "commented", "approved", "mergeable", "merged"].contains(status)
            || ["Awaiting PR", "Draft", "CI failing", "Commented", "Changes requested",
                "Needs human review", "Mergeable", "Approved", "Merged",
                "Closed without merge"].contains(displayStatus ?? "")
    }

    public var isUnknownState: Bool {
        !available || isNoSignal || (!isExited && !isWaiting && !isWorking)
    }

    public var teamRole: AOHostTeamRole? { orchestration?.role }
}

/// Exact native-session ↔ AO-session binding. `hookEnvironment` is captured
/// from the AO variables in the agent process environment; it is an observed
/// identity, never a cwd/title/time inference. `hostObservation` is a
/// placeholder row owned by AO observation itself.
public enum AOBindingOrigin: String, Codable, Sendable {
    case hookEnvironment
    case hostObservation
    case nativeIdentity
}

public struct AOBinding: Codable, Equatable, Sendable {
    public var sessionID: String
    public var projectID: String?
    /// AO runtime launch that produced the environment evidence, when the
    /// harness exports it. A different launch is a new generation, not the
    /// same role silently carried forward.
    public var launchID: String?
    public var agentKind: AgentKind
    public var origin: AOBindingOrigin
    public var boundAt: Date
    /// Historical marker retained for explicit old-generation evidence. This
    /// batch never infers a replacement from createdAt or a changed launch
    /// string; ambiguous claims use `conflictedAt` and keep both rows.
    public var supersededAt: Date?
    /// Set when more than one native session claims the same AO session and the
    /// protocol cannot distinguish the real task from a same-harness nested
    /// process. A conflicted claim never carries the current AO role; the
    /// native row itself remains visible with its own state/receipt.
    public var conflictedAt: Date?

    public init(sessionID: String, projectID: String?, launchID: String? = nil,
                agentKind: AgentKind, origin: AOBindingOrigin, boundAt: Date,
                supersededAt: Date? = nil, conflictedAt: Date? = nil) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.launchID = launchID
        self.agentKind = agentKind
        self.origin = origin
        self.boundAt = boundAt
        self.supersededAt = supersededAt
        self.conflictedAt = conflictedAt
    }

    public var isCurrent: Bool { supersededAt == nil && conflictedAt == nil }

    public var valid: Bool {
        AOHostObservation.validID(sessionID)
            && (projectID == nil || AOHostObservation.validID(projectID!))
            && (launchID == nil || AOHostObservation.validID(launchID!))
            && boundAt.timeIntervalSince1970.isFinite
            && (supersededAt == nil || supersededAt!.timeIntervalSince1970.isFinite)
            && (conflictedAt == nil || conflictedAt!.timeIntervalSince1970.isFinite)
    }
}

/// A bounded snapshot from the AO daemon. `projectNames` only supplies display
/// labels; association always uses exact IDs.
public struct AOSnapshot: Sendable, Equatable {
    public var instanceID: String
    public var observedAt: Date
    public var projectNames: [String: String]
    public var sessions: [AOHostObservation]
    public var available: Bool
    /// Exact native handles re-read from the current local AO store. These
    /// identify existing rows; they never supply turn results or read receipts.
    public var nativeIdentities: [AONativeIdentity] = []

    public init(instanceID: String, observedAt: Date, projectNames: [String: String],
                sessions: [AOHostObservation], available: Bool = true) {
        self.instanceID = instanceID
        self.observedAt = observedAt
        self.projectNames = projectNames
        self.sessions = sessions
        self.available = available
    }
}

/// One display transition produced by an AO snapshot. `before` is nil only for
/// a newly created placeholder, so startup history never emits a notification.
public struct AOHostTransition: Sendable, Equatable {
    public let before: AgentSession?
    public let after: AgentSession

    public init(before: AgentSession?, after: AgentSession) {
        self.before = before
        self.after = after
    }
}

/// Pure AO fact → existing AgentPet state mapping. No AO state ever maps to a
/// successful result: only a native hook result may do that.
public enum AOHostMapping {
    /// Project grouping uses AO's own project ID and session kind, not a
    /// guessed parent or a user-maintained member list. Standalone sessions
    /// have no shared project and must never collapse into one artificial team.
    public static func projectGroup(for observation: AOHostObservation) -> AOOrchestration? {
        guard observation.projectID != standaloneProjectID,
              AOHostObservation.validID(observation.projectID) else { return nil }
        return AOOrchestration(teamID: observation.projectID,
            teamName: observation.projectName ?? observation.projectID,
            role: observation.role == .orchestrator ? .lead : .teammate)
    }

    public static func agentKind(for harness: String) -> AgentKind {
        switch harness {
        case "codex": return .codex
        case "claude", "claude-code": return .claude
        case "opencode", "opencode-v2": return .opencode
        case "pi": return .pi
        case "agy", "antigravity": return .antigravity
        case "dsh", "deepseek-harness": return .dsh
        case "grok": return .grok
        case "cursor": return .cursor
        case "copilot": return .copilot
        case "kiro": return .kiroCLI
        case "droid": return .droid
        default: return .unknown
        }
    }

    public static func state(for observation: AOHostObservation) -> AgentState {
        guard observation.available else { return .idle }
        if observation.isExited { return .idle }
        if observation.isWaiting { return .waiting }
        if observation.isWorking { return .working }
        return .idle
    }

    public static func message(for observation: AOHostObservation) -> String {
        guard observation.available else { return "AO 不可达，状态未知" }
        if observation.isExited {
            return observation.displayStatus == "Interrupted" ? "AO 会话已中断" : "AO 会话已退出"
        }
        if observation.isWaiting {
            return observation.activity == .waitingInput ? "等待用户输入" : "等待人工处理"
        }
        if observation.isWorking { return "工作中" }
        if observation.isNoSignal { return "AO 无信号，结果未知" }
        if observation.isPullRequestState {
            if let label = displayStatusLabel(observation.displayStatus) {
                return "PR 状态：" + label
            }
            if let status = statusLabel(observation.status) {
                return "PR 状态：" + status
            }
            return "PR 状态更新"
        }
        return "结果未知"
    }

    private static func displayStatusLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw {
        case "Working": return "工作中"
        case "Blocked": return "等待人工处理"
        case "Exited": return "已退出"
        case "No signal": return "无信号"
        case "Interrupted": return "已中断"
        case "Awaiting PR": return "等待 PR"
        case "Fixing CI failures": return "修复 CI"
        case "Addressing comments": return "处理评审意见"
        case "Needs review": return "待评审"
        case "Review scheduled": return "已安排评审"
        case "Reviewing": return "评审中"
        case "Review failed": return "评审失败"
        case "Review pending": return "评审待定"
        case "Draft": return "草稿"
        case "CI failing": return "CI 失败"
        case "Commented": return "已评论"
        case "Changes requested": return "请求修改"
        case "Needs human review": return "需要人工评审"
        case "Mergeable": return "可合并"
        case "Approved": return "已批准"
        case "Merged": return "已合并"
        case "Closed without merge": return "未合并关闭"
        case "Terminated": return "已终止"
        default: return raw
        }
    }

    private static func statusLabel(_ raw: String) -> String? {
        switch raw {
        case "pr_open": return "PR 开放"
        case "draft": return "草稿"
        case "ci_failed": return "CI 失败"
        case "review_pending": return "评审待定"
        case "changes_requested": return "请求修改"
        case "commented": return "已评论"
        case "approved": return "已批准"
        case "mergeable": return "可合并"
        case "merged": return "已合并"
        default: return nil
        }
    }

    public static func defaultTitle(for observation: AOHostObservation) -> String {
        let role = observation.role == .orchestrator ? "AO Leader" : "AO Worker"
        return role + " · " + String(observation.sessionID.prefix(12))
    }

    public static let standaloneProjectID = "__standalone__"

    public static func placeholderID(_ sessionID: String) -> String {
        "ao:" + sessionID
    }

    public static func placeholderSession(for observation: AOHostObservation) -> AgentSession {
        let kind = agentKind(for: observation.harness)
        let state = state(for: observation)
        var session = AgentSession(
            id: placeholderID(observation.sessionID),
            agentKind: kind,
            project: observation.projectName ?? observation.projectID,
            title: observation.displayName ?? defaultTitle(for: observation),
            state: state,
            message: message(for: observation),
            source: .passive,
            updatedAt: max(observation.updatedAt, observation.observedAt),
            stateSince: observation.activityAt ?? observation.updatedAt,
            createdAt: observation.createdAt
        )
        if kind == .unknown { session.agentName = observation.harness }
        session.aoBinding = AOBinding(sessionID: observation.sessionID,
                                      projectID: observation.projectID,
                                      agentKind: kind,
                                      origin: .hostObservation,
                                      boundAt: observation.observedAt)
        session.aoObservation = observation
        session.notificationVersion = state == .waiting ? 1 : 0
        session.displayRevision = 1
        session.turnStartedAt = state == .working ? (observation.activityAt ?? observation.updatedAt) : nil
        // Freeze the timer for non-working host states; this is not a native
        // completion result and never sets taskResult.
        session.turnEndedAt = state == .working ? nil : observation.updatedAt
        return session
    }
}

/// Capture the AO coordinates that AO injects into every supervised session.
/// `AO_SESSION_ID` is the required exact identity; `AO_PROJECT_ID` is optional
/// for a standalone AO session. Neither cwd, title nor timing participates.
public enum AOHostEnvironment {
    public struct Capture: Equatable, Sendable {
        public let sessionID: String
        public let projectID: String?
        public let launchID: String?

        public init(sessionID: String, projectID: String?, launchID: String? = nil) {
            self.sessionID = sessionID
            self.projectID = projectID
            self.launchID = launchID
        }
    }

    public static func capture(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Capture? {
        guard let rawSession = environment["AO_SESSION_ID"],
              AOHostObservation.validID(rawSession) else { return nil }
        let rawProject: String?
        if let value = environment["AO_PROJECT_ID"], !value.isEmpty {
            guard AOHostObservation.validID(value) else { return nil }
            rawProject = value
        } else {
            rawProject = nil
        }
        let launch = environment["AO_RUNTIME_LAUNCH_ID"].flatMap {
            AOHostObservation.validID($0) ? $0 : nil
        }
        return Capture(sessionID: rawSession, projectID: rawProject, launchID: launch)
    }
}

/// One host-neutral Team scope derived from a verified association. AionUI
/// keeps its existing verification semantics; AO only exposes a Team scope
/// when its adapter supplied explicit orchestration evidence.
public enum HostKind: String, Codable, Sendable {
    case aionUI
    case agentOrchestrator
}

public enum HostTeamRole: String, Codable, Sendable {
    case lead
    case teammate
}

public struct HostTeamScope: Equatable, Sendable {
    public var host: HostKind
    public var teamID: String
    public var teamName: String
    /// nil when the raw host mark is known but its role is not currently
    /// verified. Such a row stays an explicit unknown Team, never a member page.
    public var role: HostTeamRole?
    public var verifiedAt: Date?
    public var instanceID: String?

    public init(host: HostKind, teamID: String, teamName: String, role: HostTeamRole?,
                verifiedAt: Date? = nil, instanceID: String? = nil) {
        self.host = host
        self.teamID = teamID
        self.teamName = teamName
        self.role = role
        self.verifiedAt = verifiedAt
        self.instanceID = instanceID
    }
}

/// A receipt for AO's own attention facts, never for a native turn. The durable
/// host identity survives daemon reconnects; `instanceID` fences the evidence
/// which introduced each waiting revision. This record grants no live role.
public struct AOAttentionReceipt: Codable, Equatable, Sendable, Identifiable {
    public var observation: AOHostObservation
    public var version: Int
    public var readThroughVersion: Int
    public var readAt: Date?
    public var waitingAt: Date?
    public var instanceID: String
    public var lastWasWaiting: Bool
    public var latestUpdatedAt: Date

    public var id: String { Self.sourceID(for: observation) }
    public var hasUnread: Bool { version > readThroughVersion }
    /// The original fact being acknowledged, not a current-availability claim.
    public var observationWithEvidence: AOHostObservation {
        var fact = observation
        fact.available = true
        fact.orchestration = nil
        return fact
    }
    public static func sourceID(for observation: AOHostObservation) -> String {
        observation.sessionID + "|" + String(observation.createdAt.timeIntervalSinceReferenceDate.bitPattern)
    }
    public var valid: Bool {
        observation.valid && AOHostObservation.validInstanceID(instanceID)
            && latestUpdatedAt.timeIntervalSince1970.isFinite
            && version >= 0 && readThroughVersion >= 0 && readThroughVersion <= version
            && (readAt == nil || readAt!.timeIntervalSince1970.isFinite)
            && (waitingAt == nil || waitingAt!.timeIntervalSince1970.isFinite)
    }
}
