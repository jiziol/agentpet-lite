import Foundation

/// The v1 wire envelope stays independent of the in-memory coordination model.
struct SessionSnapshotDTO: Codable, Sendable {
    var version = 1
    var sessions: [AgentSession]
    /// Optional v1 extension: source receipts are stored once, independently of
    /// whichever native/AO-only row currently presents them. No role is restored.
    var aoAttentionRecords: [AOAttentionReceipt]? = nil

    static func includes(_ session: AgentSession) -> Bool {
        // AO-only rows are live projection of the daemon and are rebuilt after
        // launch; persisting them would let a stale role/row revive.
        if session.isAOPlaceholder { return false }
        return session.agentKind == .codex || session.agentKind == .antigravity ||
        session.agentKind == .opencode || session.agentKind == .dsh || session.agentKind == .pi || session.humanRequests != nil
    }
}

public struct SnapshotSaveStatus: Sendable {
    public let requestedRevision: UInt64
    public let committedRevision: UInt64
    public let error: String?
    public var isFlushed: Bool { requestedRevision == committedRevision && error == nil }
}

/// One serial writer and at most one pending value. Revisions are in-memory
/// coordination metadata, never a change to the legacy v1 file schema.
final class SessionRepository: @unchecked Sendable {
    /// Strict upper bound shared by admission on read and encoded writes.
    static let snapshotByteLimit = 4_194_304
    typealias Writer = @Sendable (URL, Data) throws -> Void
    private struct Save: Sendable {
        let url: URL
        let snapshot: SessionSnapshotDTO
        let revision: UInt64
    }
    private let queue = DispatchQueue(label: "agentpet.session-snapshot")
    private let lock = NSLock()
    private let coalesces: Bool
    private let writer: Writer
    private var location: URL?
    private var diagnostic: String?
    private var canPersist = true
    private var requested: UInt64 = 0
    private var committed: UInt64 = 0
    private var pending: Save?
    private var scheduled = false

    init(coalesces: Bool = false, writer: @escaping Writer = { try $1.write(to: $0, options: .atomic) }) {
        self.coalesces = coalesces; self.writer = writer
    }

    var url: URL? {
        get { lock.withLock { location } }
        set {
            // A path change cannot redirect an already admitted snapshot.
            _ = flush()
            lock.withLock { location = newValue }
        }
    }
    var error: String? { lock.withLock { diagnostic } }
    var status: SnapshotSaveStatus {
        lock.withLock { SnapshotSaveStatus(requestedRevision: requested, committedRevision: committed, error: diagnostic) }
    }

    func load() -> SessionSnapshotDTO? {
        _ = flush()
        return queue.sync {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                  size.intValue < Self.snapshotByteLimit,
                  let data = try? Data(contentsOf: url),
                  data.count < Self.snapshotByteLimit,
                  let snapshot = try? JSONDecoder().decode(SessionSnapshotDTO.self, from: data),
                  snapshot.version == 1 else {
                lock.withLock {
                    canPersist = false; pending = nil
                    diagnostic = "未读记录无法读取，已保留原文件"
                }
                return nil
            }
            return snapshot
        }
    }

    func save(_ snapshot: SessionSnapshotDTO) {
        let enqueue = lock.withLock { () -> Bool in
            guard canPersist, let location else { return false }
            requested += 1
            pending = Save(url: location, snapshot: snapshot, revision: requested)
            if scheduled { return false }
            scheduled = true
            return true
        }
        if enqueue { queue.async { self.runScheduled() } }
        // Compatibility callers retain immediate reads. Production opts into
        // coalescing explicitly and flushes at its shutdown boundary.
        if !coalesces { _ = flush() }
    }

    private func runScheduled() {
        let attempted = writePending()
        let again = lock.withLock { () -> Bool in
            // Retain a failed latest value without spinning. A new revision or
            // an explicit flush retries it after the external failure is fixed.
            if let pending, pending.revision != attempted {
                return true
            }
            scheduled = false
            return false
        }
        if again { queue.async { self.runScheduled() } }
    }

    @discardableResult
    private func writePending() -> UInt64? {
        guard let save = lock.withLock({ () -> Save? in
            let value = pending; pending = nil; return value
        }) else { return nil }
        let data: Data
        do { data = try JSONEncoder().encode(save.snapshot) }
        catch {
            fail(save, message: "未读记录编码失败")
            return save.revision
        }
        // Never replace a readable snapshot with bytes this loader will reject.
        // Keep the complete latest value retryable, without trimming receipts or
        // claiming a commit. runScheduled retries only for a newer revision.
        guard data.count < Self.snapshotByteLimit else {
            fail(save, message: "未读记录超过快照容量（须小于 4 MiB），未保存最新记录，已保留原文件")
            return save.revision
        }
        try? FileManager.default.createDirectory(at: save.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try writer(save.url, data)
            lock.withLock {
                committed = max(committed, save.revision)
                diagnostic = nil
            }
        } catch { fail(save, message: "未读记录保存失败") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: save.url.path)
        return save.revision
    }

    private func fail(_ save: Save, message: String) {
        lock.withLock {
            diagnostic = message
            if pending == nil || pending!.revision < save.revision { pending = save }
        }
    }

    /// Wait for the serial writer, then attempt the newest admitted value once.
    /// Failure is visible and remains retryable; no retry loop or main-actor callback.
    @discardableResult
    func flush() -> SnapshotSaveStatus {
        _ = queue.sync { writePending() }
        return status
    }
}
