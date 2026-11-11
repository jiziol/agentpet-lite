import Foundation

public enum SessionCompletionEffect: Sendable, Equatable {
    case notification(title: String, body: String)
    case waitingSound
    case completionSound
    case completionMeal
    case completedSessionUsage
}

/// This policy is pure. Call sites retain their distinct native-result gates:
/// notably agy cancellation watchers are silent and bare Codex Stop is gated.
public enum SessionNotificationPolicy {
    public static func effects(before: AgentState?, session: AgentSession) -> [SessionCompletionEffect] {
        guard !session.isOpencodeSubagent, !session.isCodexInternalTask, !session.isDSHBackend, session.state != before else { return [] }
        let project = session.project.map { ($0 as NSString).lastPathComponent } ?? session.id
        switch session.state {
        case .waiting:
            return [.notification(title: "\(project) needs input", body: session.message ?? "Waiting for you"), .waitingSound]
        case .done:
            if session.agentKind == .dsh && (session.dshDisconnectedAt != nil || session.dsh?.result == .unknown) {
                return [.notification(title: "DSH 任务结果未知", body: "请检查原客户端")]
            }
            if session.agentKind == .opencode && session.opencodeDisconnectedAt != nil {
                return [.notification(title: "opencode 会话连接中断", body: "任务结果未知，请检查原客户端")]
            }
            if let result = session.taskResult, result != .completed {
                return [.notification(title: result == .cancelled ? "任务已停止" : "任务失败", body: session.title ?? project)]
            }
            return [.notification(title: "\(project) finished", body: "Agent completed its turn"),
                    .completionSound, .completionMeal, .completedSessionUsage]
        default: return []
        }
    }
}

/// Incremental transcript readers own token/cursor deduplication. The receipt
/// describes actual usage, including cancelled/failed work, never a success meal.
public struct SessionUsageReceipt: Sendable {
    public let sessionID: String
    public let eventAt: Date
    public let tokens: Int
    public let project: String?
    public let agent: String
    public let costUSD: Double
    public init(sessionID: String, eventAt: Date, tokens: Int, project: String?, agent: String, costUSD: Double = 0) {
        self.sessionID = sessionID; self.eventAt = eventAt; self.tokens = tokens
        self.project = project; self.agent = agent; self.costUSD = costUSD
    }
}
