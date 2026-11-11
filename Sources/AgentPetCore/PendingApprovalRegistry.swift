import Foundation

/// The user's decision for a gated tool call, written back to the CLI hook.
public enum ApprovalDecision: String, Codable, Sendable {
    case allow, deny, ask
}

/// Builds the Claude Code hook JSON that carries a `PreToolUse` permission decision.
public enum ApprovalHookResponse {
    public static func json(for decision: ApprovalDecision) -> String {
        "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"\(decision.rawValue)\"}}"
    }
}

/// Tracks CLI hook connections (file descriptors) awaiting an approval
/// decision, keyed by request id, and writes the decision back when resolved.

// Known limitation (a): a timeout only resolves the CLI-side fd; it does not
// notify `SessionStore`, so the UI's pending approval clears on the next event.

// Known limitation (b): a decision after the timeout fires returns `false`
// from `resolve`, but the UI still clears — the timeout already decided.
public final class PendingApprovalRegistry: @unchecked Sendable {
    public static let shared = PendingApprovalRegistry()

    private let queue = DispatchQueue(label: "com.agentpet.pendingApprovalRegistry")
    private struct Entry {
        let token: UUID
        let fd: Int32
        let onClose: @Sendable () -> Void
    }
    private var fds: [String: Entry] = [:]

    public init() {}

    deinit {
        // Enqueued registry operations retain self until they finish; no queue
        // work can still access these entries when the last owner goes away.
        for entry in fds.values {
            close(entry.fd)
            DispatchQueue.global(qos: .utility).async(execute: entry.onClose)
        }
    }

    /// Auto-resolves to `.ask` after `timeout` — kept shorter than the CLI's
    /// read timeout so the reply lands while the peer is still reading.
    @discardableResult
    public func register(requestId: String, fd: Int32, timeout: TimeInterval = ApprovalTimeouts.daemon,
                         onClose: @escaping @Sendable () -> Void = {}) -> UUID {
        // SO_NOSIGPIPE: a write after the CLI died must not SIGPIPE the daemon.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let token = UUID()
        queue.async {
            self._resolveLocked(requestId: requestId, decision: .ask)
            self.fds[requestId] = Entry(token: token, fd: fd, onClose: onClose)
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.fds[requestId]?.token == token else { return }
            self._resolveLocked(requestId: requestId, decision: .ask)
        }
        return token
    }

    /// Cancels only the exact registration owned by the stopping transport.
    public func cancel(token: UUID) {
        queue.sync {
            guard let id = fds.first(where: { $0.value.token == token })?.key else { return }
            _resolveLocked(requestId: id, decision: .ask)
        }
    }

    /// Writes the decision to the registered fd and closes it. Returns
    /// `false` (no-op) if `requestId` isn't registered (already resolved).
    @discardableResult
    public func resolve(requestId: String, decision: ApprovalDecision) -> Bool {
        queue.sync { _resolveLocked(requestId: requestId, decision: decision) }
    }

    // Must only be called on `queue`.
    @discardableResult
    private func _resolveLocked(requestId: String, decision: ApprovalDecision) -> Bool {
        guard let entry = fds.removeValue(forKey: requestId) else { return false }
        let data = Data("{\"decision\":\"\(decision.rawValue)\"}\n".utf8)
        _ = EventSender.writeAll(data, fd: entry.fd)
        close(entry.fd)
        // Completion may call back into this registry; do not run it on its lock queue.
        DispatchQueue.global(qos: .utility).async(execute: entry.onClose)
        return true
    }
}
