import Foundation

/// Internal input only: payloads retain each channel's native ordering evidence.
/// Do not serialize this as a replacement for AgentEvent or v1 snapshots.
public struct SessionObservation: Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        case hook(AgentEvent)
        case codexLifecycle(sessionID: String, CodexLifecycle)
        case antigravitySQLite(sessionID: String, AntigravityHumanInput.Cancellation)
        case antigravityLog(AntigravityCancellationSignal)
        case aionUiCancellation(AionUiCancellationSignal)
    }
    public let payload: Payload
    public let observedAt: Date
    public var eventAt: Date {
        switch payload {
        case .hook(let event): return event.timestamp
        case .codexLifecycle(_, let event): return event.timestamp
        case .antigravitySQLite(_, let evidence): return evidence.timestamp
        case .antigravityLog(let evidence): return evidence.timestamp
        case .aionUiCancellation(let evidence): return evidence.timestamp
        }
    }
    public init(_ payload: Payload, observedAt: Date) {
        self.payload = payload; self.observedAt = observedAt
    }
}

/// Source adapters interpret native payloads, not host routes or UI state.
public protocol SourceObservationAdapter: Sendable {
    func observe(_ event: AgentEvent, at observedAt: Date) -> SessionObservation
}
public struct HookSourceAdapter: SourceObservationAdapter {
    public init() {}
    public func observe(_ event: AgentEvent, at observedAt: Date) -> SessionObservation {
        .init(.hook(event), observedAt: observedAt)
    }
}

/// Exact host metadata lookup; AppKit navigation stays in App until R4.
public protocol HostAssociationAdapter: Sendable {
    func association(for session: AgentSession) -> AionUiMetadata.Lookup
}
public struct AionUiHostAdapter: HostAssociationAdapter {
    public init() {}
    public func association(for session: AgentSession) -> AionUiMetadata.Lookup {
        let lookup = AionUiMetadata.read(sessionID: session.id, agentKind: session.agentKind)
        if case .notFound = lookup, let known = session.validAionUiConversation {
            return AionUiMetadata.revalidate(known)
        }
        return lookup
    }
}

/// Narrow lifetime contract. The identifiers remain native session IDs for
/// source watchers and host conversation IDs for the AionUi watcher.
public protocol ObservationLifetime: AnyObject {
    func retainObservationIDs(_ ids: Set<String>)
}
extension CodexLifecycleWatcher: ObservationLifetime {
    public func retainObservationIDs(_ ids: Set<String>) { retain(sessionIDs: ids) }
}
extension AntigravityHumanInputWatcher: ObservationLifetime {
    public func retainObservationIDs(_ ids: Set<String>) { retain(sessionIDs: ids) }
}
extension AntigravityCancellationLogWatcher: ObservationLifetime {
    public func retainObservationIDs(_ ids: Set<String>) { retain(sessionIDs: ids) }
}
extension AionUiCancellationLogWatcher: ObservationLifetime {
    public func retainObservationIDs(_ ids: Set<String>) { retain(conversationIDs: ids) }
}
