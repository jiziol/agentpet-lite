import Foundation

/// Pure cancellation transitions; caller supplies evidence and clocks.
extension SessionReducer {
    /// The reader verifies the latest executor/step identity. A native step
    /// boundary, plus the exact observed Hook revision, prevents an old abort
    /// from ending a newer invocation despite Hook delivery latency.
    @discardableResult
    public func reconcileAntigravityCancellation(id: String, cancellation: AntigravityHumanInput.Cancellation) -> AgentSession? {
        guard let session = byID[id], session.agentKind == .antigravity,
              session.state == .working || session.state == .waiting,
              cancellation.expectedHookAt == nil || cancellation.expectedHookAt == (session.antigravityEventAt ?? session.updatedAt),
              cancellation.matches(stepFloor: session.antigravityStepFloor, latestHookAt: session.antigravityEventAt ?? session.updatedAt) else { return nil }
        let endedAt = max(cancellation.observedAt ?? cancellation.timestamp,
                          (session.antigravityEventAt ?? session.updatedAt).addingTimeInterval(0.000001))
        var event = AgentEvent(sessionId: id, agentKind: .antigravity, eventName: "done", message: "任务已停止", timestamp: endedAt)
        event.turnResult = .cancelled
        return apply(event, now: event.timestamp)
    }

    /// The server logs its explicit cancellation acknowledgement before the
    /// deferred SQLite save. Keep this signal tied to the exact Hook revision;
    /// it does not invent an executor identity or step index from log text.
    @discardableResult
    public func reconcileAntigravityCancellationSignal(_ signal: AntigravityCancellationSignal, observedAt: Date) -> AgentSession? {
        guard let session = byID[signal.sessionID], session.agentKind == .antigravity,
              session.state == .working || session.state == .waiting,
              signal.expectedHookAt == (session.antigravityEventAt ?? session.updatedAt),
              signal.timestamp >= signal.expectedHookAt, signal.timestamp <= observedAt.addingTimeInterval(1) else { return nil }
        var event = AgentEvent(sessionId: signal.sessionID, agentKind: .antigravity, eventName: "done",
            message: "任务已停止", timestamp: max(observedAt, signal.timestamp))
        event.turnResult = .cancelled
        return apply(event, now: event.timestamp)
    }

    /// AionUi terminates its per-turn child instead of emitting the TUI's
    /// native cancellation log. Only its exact host/turn acknowledgement may
    /// stop the matching currently observed Antigravity invocation.
    @discardableResult
    public func reconcileAionUiCancellation(_ signal: AionUiCancellationSignal, observedAt: Date) -> AgentSession? {
        let target = signal.conversation
        guard let session = byID[target.nativeSessionID], session.agentKind == .antigravity,
              session.validAionUiConversation == target, session.createdAt == signal.createdAt,
              session.state == .working || session.state == .waiting,
              signal.expectedHookAt == (session.antigravityEventAt ?? session.updatedAt),
              signal.claimedAt <= signal.expectedHookAt, signal.claimedAt <= signal.requestedAt,
              signal.requestedAt <= signal.timestamp, signal.timestamp >= signal.expectedHookAt,
              signal.timestamp <= observedAt.addingTimeInterval(1) else { return nil }
        let endedAt = max(signal.timestamp, signal.expectedHookAt.addingTimeInterval(0.000001))
        var event = AgentEvent(sessionId: session.id, agentKind: .antigravity, eventName: "done",
            message: "任务已停止", timestamp: endedAt)
        event.turnResult = .cancelled
        return apply(event, now: endedAt)
    }
}
