import Foundation
import CryptoKit
import Darwin

/// A path-only diagnostic; never includes record content or decoder context.
public struct SessionArchiveFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable { case read, decode, write, unsafeFile, changed, directory, invalidRecord }
    public let path: String
    public let kind: Kind
    public var description: String { "SessionArchiveStore: \(kind.rawValue) failed at \(path); original file retained" }
}

public enum SessionArchiveResult: Sendable, Equatable {
    case archived, alreadyArchived, pending, failed
    /// Pending is durable staging, not a successful daily archive write.
    public var safelyRetained: Bool { self != .failed }
}

/// Daily JSON history with conservative failure handling and durable retries.
public final class SessionArchiveStore: @unchecked Sendable {
    public static let shared = SessionArchiveStore(
        baseURL: URL(fileURLWithPath: AgentPetPaths.baseDir).appendingPathComponent("history", isDirectory: true)
    )
    public let baseURL: URL
    private let queue = DispatchQueue(label: "com.agentpet.SessionArchiveStore")
    // Different instances of a daily store must not race read/modify/write.
    // External writers do not share this lock; a final snapshot check detects
    // observed edits, but is not a filesystem-wide atomic compare-and-swap.
    private static let fileLock = NSLock()
    private var archivedIds = Set<String>()
    private var pending: [String: SessionArchive] = [:]
    private var durablePendingIds = Set<String>()
    private var reported: [String: SessionArchiveFailure.Kind] = [:]
    private var failure: SessionArchiveFailure?
    private let dateFormatter: DateFormatter
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public init(baseURL: URL) {
        self.baseURL = baseURL.standardizedFileURL
        dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Self.utcCalendar
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        locked {
            do { try ensureDirectory(self.baseURL) } catch { report(error, at: self.baseURL, kind: .directory) }
            rebuildDedupSet()
            loadPending()
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync {
            Self.fileLock.lock(); defer { Self.fileLock.unlock() }
            return try body()
        }
    }
    public var lastFailure: SessionArchiveFailure? { locked { failure } }
    public var pendingCount: Int { locked { pending.count } }
    public var durablePendingCount: Int { locked { durablePendingIds.count } }

    /// A failure is never added to the success dedup set. The first failed
    /// record's timestamps/content are retained across retries.
    @discardableResult
    public func archive(_ session: AgentSession, startedAt: Date, endedAt: Date) -> SessionArchiveResult {
        locked {
            loadPending()
            let record = pending[session.id] ?? SessionArchive(
                sessionId: session.id, agentKind: session.agentKind, project: session.project,
                title: session.title, message: session.message, tokenCount: nil,
                startedAt: startedAt, endedAt: endedAt, duration: endedAt.timeIntervalSince(startedAt)
            )
            return attempt(record)
        }
    }

    /// Called by the daemon's existing prune cadence; also available to callers
    /// after correcting a file/permission failure. Reads are never auto-repair.
    @discardableResult
    public func retryPending() -> Int {
        retryPendingReceipts().filter { $0.result == .archived || $0.result == .alreadyArchived }.count
    }

    /// Result metadata only; the effect coordinator supplies instance identity.
    func retryPendingReceipts() -> [ArchiveRetryResult] {
        locked {
            // Include records staged by another instance, without replacing
            // this instance's first failed snapshot.
            loadPending()
            var completed: [ArchiveRetryResult] = []
            for record in Array(pending.values) {
                let result = attempt(record)
                completed.append(ArchiveRetryResult(sessionID: record.sessionId, result: result))
            }
            return completed
        }
    }

    /// Explicit error API for callers that need to distinguish failure/absence.
    public func recordsChecked(for date: Date) throws -> [SessionArchive] {
        try locked {
            let url = fileURL(for: date)
            do {
                let records = try readRecords(from: url).records
                for record in records { archivedIds.insert(record.sessionId) }
                return records
            } catch { report(error, at: url, kind: .read); throw error }
        }
    }
    /// Compatibility API for the existing history UI. Failures are diagnosed;
    /// this fallback must never be used by the append path.
    public func records(for date: Date) -> [SessionArchive] {
        (try? recordsChecked(for: date)) ?? []
    }
    public func allRecords(since date: Date) -> [SessionArchive] {
        locked {
            var current = Self.utcCalendar.startOfDay(for: date)
            let today = Date()
            var result: [SessionArchive] = []
            while current <= today {
                let url = fileURL(for: current)
                do {
                    let records = try readRecords(from: url).records
                    result.append(contentsOf: records)
                    for record in records { archivedIds.insert(record.sessionId) }
                } catch { report(error, at: url, kind: .read) }
                guard let next = Self.utcCalendar.date(byAdding: .day, value: 1, to: current) else { break }
                current = next
            }
            return result
        }
    }

    /// Corrupt/unsafe/unreadable files are never deleted by retention cleanup.
    public func pruneOlderThan(days: Int) {
        locked {
            guard days >= 0 else { return }
            let files: [URL]
            do { files = try dailyFiles() }
            catch { report(error, at: baseURL, kind: .directory); return }
            var valid: [(URL, Snapshot)] = []
            for url in files {
                do { valid.append((url, try readRecords(from: url).snapshot)) }
                catch { report(error, at: url, kind: .read) }
            }
            let latest = valid.map { $0.0.deletingPathExtension().lastPathComponent }.max()
                ?? dateFormatter.string(from: Date())
            guard let reference = dateFormatter.date(from: latest) else { return }
            let cutoff = dateFormatter.string(from: reference.addingTimeInterval(-TimeInterval(days) * 86_400))
            for (url, snapshot) in valid where url.deletingPathExtension().lastPathComponent < cutoff {
                do {
                    try check(snapshot, at: url)
                    try FileManager.default.removeItem(at: url)
                    reported.removeValue(forKey: url.path)
                } catch { report(error, at: url, kind: .write) }
            }
        }
    }

    private func attempt(_ record: SessionArchive) -> SessionArchiveResult {
        guard record.startedAt.timeIntervalSince1970.isFinite,
              record.endedAt.timeIntervalSince1970.isFinite, record.duration.isFinite else {
            report(SessionArchiveFailure(path: baseURL.path, kind: .invalidRecord), at: baseURL, kind: .invalidRecord)
            return .failed
        }
        let url = fileURL(for: record.startedAt)
        do {
            try ensureDirectory(baseURL)
            // Check the target even for a cached ID; corruption must not be
            // misreported as a successful duplicate/used to clear pending data.
            var (records, snapshot) = try readRecords(from: url)
            if archivedIds.contains(record.sessionId) || records.contains(where: { $0.sessionId == record.sessionId }) {
                archivedIds.insert(record.sessionId)
                finishPending(record.sessionId)
                return .alreadyArchived
            }
            records.append(record)
            let data: Data
            do { data = try encoder.encode(records) }
            catch { throw SessionArchiveFailure(path: url.path, kind: .write) }
            try atomicWrite(data, at: url, expected: snapshot)
            archivedIds.insert(record.sessionId)
            reported.removeValue(forKey: url.path)
            finishPending(record.sessionId)
            return .archived
        } catch {
            report(error, at: url, kind: .write)
            pending[record.sessionId] = record
            do {
                try savePending(record)
                durablePendingIds.insert(record.sessionId)
                return .pending
            } catch {
                report(error, at: pendingURL(record.sessionId), kind: .write)
                durablePendingIds.remove(record.sessionId)
                return .failed
            }
        }
    }

    private struct Snapshot {
        let data: Data?
        let inode: UInt64?
        let mode: Int
    }
    private func snapshot(at url: URL) throws -> Snapshot {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return Snapshot(data: nil, inode: nil, mode: 0o600)
            }
            throw SessionArchiveFailure(path: url.path, kind: .read)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw SessionArchiveFailure(path: url.path, kind: .unsafeFile)
        }
        guard let data = try? Data(contentsOf: url) else { throw SessionArchiveFailure(path: url.path, kind: .read) }
        return Snapshot(data: data, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                        mode: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600)
    }
    private func readRecords(from url: URL) throws -> (records: [SessionArchive], snapshot: Snapshot) {
        let captured = try snapshot(at: url)
        guard let data = captured.data else { return ([], captured) }
        guard let records = try? decoder.decode([SessionArchive].self, from: data) else {
            throw SessionArchiveFailure(path: url.path, kind: .decode)
        }
        return (records, captured)
    }
    private func check(_ expected: Snapshot, at url: URL) throws {
        let actual = try snapshot(at: url)
        guard actual.data == expected.data, actual.inode == expected.inode, actual.mode == expected.mode else {
            throw SessionArchiveFailure(path: url.path, kind: .changed)
        }
    }
    private func atomicWrite(_ data: Data, at url: URL, expected: Snapshot) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(".agentpet-archive-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SessionArchiveFailure(path: url.path, kind: .write) }
        close(fd)
        do {
            try data.write(to: temp)
            try fm.setAttributes([.posixPermissions: expected.mode], ofItemAtPath: temp.path)
            try check(expected, at: url)
            guard rename(temp.path, url.path) == 0 else { throw SessionArchiveFailure(path: url.path, kind: .write) }
        } catch let error as SessionArchiveFailure { throw error }
        catch { throw SessionArchiveFailure(path: url.path, kind: .write) }
    }
    private func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: url.path) { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else {
                throw SessionArchiveFailure(path: url.path, kind: .unsafeFile)
            }
        } catch let error as SessionArchiveFailure { throw error }
        catch { throw SessionArchiveFailure(path: url.path, kind: .directory) }
    }
    private func fileURL(for date: Date) -> URL {
        baseURL.appendingPathComponent(dateFormatter.string(from: date) + ".json")
    }
    private func dailyFiles() throws -> [URL] {
        try ensureDirectory(baseURL)
        return try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil).filter {
            let name = $0.deletingPathExtension().lastPathComponent
            guard $0.pathExtension == "json", let date = dateFormatter.date(from: name) else { return false }
            return dateFormatter.string(from: date) == name
        }
    }
    private func rebuildDedupSet() {
        do {
            for url in try dailyFiles() {
                do { for record in try readRecords(from: url).records { archivedIds.insert(record.sessionId) } }
                catch { report(error, at: url, kind: .read) }
            }
        } catch { report(error, at: baseURL, kind: .directory) }
    }
    private var pendingDirectory: URL { baseURL.appendingPathComponent(".pending", isDirectory: true) }
    private func pendingURL(_ id: String) -> URL {
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return pendingDirectory.appendingPathComponent(hash + ".json")
    }
    private func savePending(_ record: SessionArchive) throws {
        try ensureDirectory(baseURL)
        try ensureDirectory(pendingDirectory)
        let url = pendingURL(record.sessionId), captured = try snapshot(at: pendingURL(record.sessionId))
        if let data = captured.data {
            guard let old = try? decoder.decode(SessionArchive.self, from: data), old.sessionId == record.sessionId else {
                throw SessionArchiveFailure(path: url.path, kind: .decode)
            }
            pending[record.sessionId] = old // First durable record wins.
            return
        }
        try atomicWrite(encoder.encode(record), at: url, expected: captured)
    }
    private func loadPending() {
        // No pending directory is a normal, read-only no-op.
        guard FileManager.default.fileExists(atPath: pendingDirectory.path) ||
              (try? FileManager.default.destinationOfSymbolicLink(atPath: pendingDirectory.path)) != nil else { return }
        do {
            try ensureDirectory(baseURL)
            try ensureDirectory(pendingDirectory)
            let urls = try FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)
            for url in urls where url.pathExtension == "json" {
                do {
                    guard let data = try snapshot(at: url).data,
                          let record = try? decoder.decode(SessionArchive.self, from: data),
                          url.lastPathComponent == pendingURL(record.sessionId).lastPathComponent else {
                        throw SessionArchiveFailure(path: url.path, kind: .decode)
                    }
                    pending[record.sessionId] = record // First durable snapshot wins across instances.
                    durablePendingIds.insert(record.sessionId)
                } catch { report(error, at: url, kind: .read) }
            }
        } catch { report(error, at: pendingDirectory, kind: .directory) }
    }
    private func finishPending(_ id: String) {
        pending.removeValue(forKey: id)
        durablePendingIds.remove(id)
        let url = pendingURL(id)
        do {
            let captured = try snapshot(at: url)
            guard let data = captured.data else { return }
            guard let record = try? decoder.decode(SessionArchive.self, from: data), record.sessionId == id else {
                throw SessionArchiveFailure(path: url.path, kind: .decode)
            }
            try check(captured, at: url)
            try FileManager.default.removeItem(at: url)
        } catch { report(error, at: url, kind: .write) }
        // If cleanup fails, the next replay reads the completed daily record
        // and does not append it again. Pending is never a success dedup entry.
    }
    private func report(_ error: Error, at url: URL, kind: SessionArchiveFailure.Kind) {
        let value = (error as? SessionArchiveFailure) ?? SessionArchiveFailure(path: url.path, kind: kind)
        failure = value
        if reported[value.path] != value.kind { fputs(value.description + "\n", stderr) }
        reported[value.path] = value.kind
    }
}
