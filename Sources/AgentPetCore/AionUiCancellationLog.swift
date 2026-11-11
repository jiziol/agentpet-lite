import Foundation

/// A host acknowledgement, rather than a missing CLI process or a stored
/// `finished` flag. The native Hook revision remains the final write fence.
public struct AionUiCancellationSignal: Sendable, Equatable {
    public let conversation: AionUiConversation
    public let createdAt: Date
    public let expectedHookAt: Date
    public let turnID: String
    public let claimedAt: Date
    public let requestedAt: Date
    public let timestamp: Date
}

public enum AionUiCancellationLog {
    public enum Action: Sendable { case claimed, requested, acknowledged, restarting }
    public struct Record: Sendable {
        public let action: Action
        public let conversationID: String
        public let turnID: String?
        public let timestamp: Date
    }

    /// Only exact AionCore JSON records from its two host modules are accepted.
    /// Assistant text, generic Finish/error, idle process kills and failed
    /// cancel requests are never interpreted as a user stop.
    public static func parse(_ data: Data, observedAt: Date) -> Record? {
        guard data.count <= 4_096,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["level"] as? String == "INFO",
              let fields = json["fields"] as? [String: Any],
              let id = fields["conversation_id"] as? String, AionUiMetadata.validID(id),
              let text = json["timestamp"] as? String, text.utf8.count <= 40 else { return nil }
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let at = format.date(from: text), at <= observedAt.addingTimeInterval(1),
              observedAt.timeIntervalSince(at) <= 86_400 else { return nil }
        let action: Action
        switch (json["target"] as? String, fields["message"] as? String) {
        case ("aionui_conversation::runtime_state", "conversation runtime turn claimed"): action = .claimed
        case ("aionui_conversation::runtime_state", "conversation marked cancelling"): action = .requested
        case ("aionui_conversation::runtime_state", "conversation runtime marked restarting"): action = .restarting
        case ("aionui_conversation::service", "Stream cancel acknowledged"): action = .acknowledged
        default: return nil
        }
        let turn = fields["turn_id"] as? String
        if action == .claimed || action == .acknowledged {
            guard let turn, turn.hasPrefix("turn_"), AionUiMetadata.validID(turn) else { return nil }
        }
        return Record(action: action, conversationID: id, turnID: turn, timestamp: at)
    }
}

struct AionUiCancellationContext: Equatable, Sendable {
    let conversation: AionUiConversation
    let createdAt: Date
    let hookAt: Date
}

/// Ordering is host-turn-specific. Restart uses the same acknowledgement as
/// user cancel, so its explicit preceding marker excludes that whole turn.
struct AionUiCancellationTracker {
    private var turnID: String?
    private var claimedAt: Date?
    private var requestedAt: Date?
    private var restarting = false
    private var lastAt = Date.distantPast
    private var emittedHookAt: Date?

    mutating func consume(_ record: AionUiCancellationLog.Record, context: AionUiCancellationContext) -> AionUiCancellationSignal? {
        guard record.conversationID == context.conversation.id, record.timestamp >= lastAt else { return nil }
        lastAt = record.timestamp
        switch record.action {
        case .claimed:
            turnID = record.turnID; claimedAt = record.timestamp
            requestedAt = nil; restarting = false; emittedHookAt = nil
        case .requested:
            requestedAt = record.timestamp
        case .restarting:
            restarting = true
        case .acknowledged:
            guard !restarting, let turnID, turnID == record.turnID,
                  let claimedAt, let requestedAt, claimedAt <= requestedAt,
                  claimedAt <= context.hookAt, requestedAt <= record.timestamp,
                  record.timestamp >= context.hookAt, emittedHookAt != context.hookAt else { return nil }
            emittedHookAt = context.hookAt
            return AionUiCancellationSignal(conversation: context.conversation, createdAt: context.createdAt,
                expectedHookAt: context.hookAt, turnID: turnID, claimedAt: claimedAt,
                requestedAt: requestedAt, timestamp: record.timestamp)
        }
        return nil
    }
}

/// Internal observation points for deterministic lifecycle tests. No log content
/// is exposed, and production uses the same dispatch registration callbacks.
enum AionUiCancellationWatchCheckpoint: Sendable {
    case registered(path: String, directory: Bool, id: UUID)
    case cancelled(path: String, directory: Bool, id: UUID)
    case scanCompleted(directories: [String], files: [String], contexts: Int)
    case read(path: String, offset: UInt64, partial: Int, dropping: Bool, inode: UInt64)
}

/// Watches only the exact daily AionCore log files around today's local date.
/// Reads bounded tails/partial lines without exporting content or credentials.
public final class AionUiCancellationLogWatcher: @unchecked Sendable {
    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
        init(_ info: stat) {
            device = UInt64(truncatingIfNeeded: info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }
    private final class DirectoryWatch: @unchecked Sendable {
        let path: String
        let id = UUID()
        let identity: FileIdentity
        let source: DispatchSourceFileSystemObject
        init(path: String, identity: FileIdentity, source: DispatchSourceFileSystemObject) {
            self.path = path; self.identity = identity; self.source = source
        }
    }
    private final class FileWatch: @unchecked Sendable {
        let path: String
        var source: DispatchSourceFileSystemObject?
        var sourceID: UUID?
        var sourceIdentity: FileIdentity?
        var offset: UInt64?
        var identity: FileIdentity?
        var partial = Data()
        var droppingLine = false
        init(_ path: String) { self.path = path }
    }
    private let queue = DispatchQueue(label: "agentpet.aionui-cancellation-log", qos: .utility)
    private let root: String
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private let activateSource: @Sendable (String, Bool, DispatchSourceFileSystemObject) -> Void
    private let checkpoint: (@Sendable (AionUiCancellationWatchCheckpoint) -> Void)?
    private let handler: @Sendable (AionUiCancellationSignal) -> Void
    private var contexts: [String: AionUiCancellationContext] = [:]
    private var trackers: [String: AionUiCancellationTracker] = [:]
    private var files: [String: FileWatch] = [:]
    private var directories: [String: DirectoryWatch] = [:]

    public convenience init(root: String = NSHomeDirectory() + "/Library/Logs/AionUi", handler: @escaping @Sendable (AionUiCancellationSignal) -> Void) {
        self.init(root: root, clock: { Date() }, handler: handler)
    }

    init(root: String, clock: @escaping @Sendable () -> Date, calendar: Calendar = .current,
         activateSource: @escaping @Sendable (String, Bool, DispatchSourceFileSystemObject) -> Void = { _, _, source in source.resume() },
         checkpoint: (@Sendable (AionUiCancellationWatchCheckpoint) -> Void)? = nil,
         handler: @escaping @Sendable (AionUiCancellationSignal) -> Void) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
        self.clock = clock; self.calendar = calendar; self.activateSource = activateSource
        self.checkpoint = checkpoint; self.handler = handler
    }

    public func watch(_ session: AgentSession) {
        guard session.agentKind == .antigravity, session.state == .working || session.state == .waiting,
              let target = session.validAionUiConversation else { return }
        let context = AionUiCancellationContext(conversation: target, createdAt: session.createdAt,
            hookAt: session.antigravityEventAt ?? session.updatedAt)
        queue.async { [weak self] in
            guard let self, self.contexts[target.id] != context,
                  self.contexts[target.id] != nil || self.contexts.count < 64 else { return }
            self.contexts[target.id] = context
            // A changed Hook fence can recover an acknowledgement which raced
            // the main actor. Replay is bounded and ordered, never a whole log.
            self.trackers[target.id] = AionUiCancellationTracker()
            self.rescan(replay: target.id)
        }
    }

    public func retain(conversationIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            self.contexts = self.contexts.filter { conversationIDs.contains($0.key) }
            self.trackers = self.trackers.filter { conversationIDs.contains($0.key) }
            if self.contexts.isEmpty {
                for watch in self.files.values { watch.source?.cancel() }
                for watch in self.directories.values { watch.source.cancel() }
                self.files.removeAll(); self.directories.removeAll()
                self.reportScan()
            } else { self.rescan() }
        }
    }

    private func identity(at path: String, type: FileAttributeType) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == type,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    private func rescan(replay: String? = nil) {
        guard !contexts.isEmpty else { return }
        var paths = Set<String>(); var parents = Set<String>([root])
        let now = clock()
        for delta in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: delta, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let year = root + String(format: "/%04d", y)
            let month = year + String(format: "/%02d", m)
            let directory = month + String(format: "/%02d", d)
            parents.formUnion([year, month, directory])
            paths.insert(directory + String(format: "/%04d-%02d-%02d.aioncore.log", y, m, d))
        }
        // If the root was deleted or has not yet been created, one existing
        // ancestor is enough to discover it. Never enumerate unrelated trees.
        if identity(at: root, type: .typeDirectory) == nil {
            var ancestor = URL(fileURLWithPath: root).deletingLastPathComponent().path
            while identity(at: ancestor, type: .typeDirectory) == nil && ancestor != "/" {
                ancestor = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
            }
            parents.insert(ancestor)
        }
        for path in Array(directories.keys) {
            guard let watch = directories[path] else { continue }
            if !parents.contains(path) || identity(at: path, type: .typeDirectory) != watch.identity {
                directories.removeValue(forKey: path)?.source.cancel()
            }
        }
        // A child's creation may precede subscription to its parent. Attach
        // shallow first and reconcile after each kernel registration completes.
        let orderedParents = parents.sorted {
            let a = URL(fileURLWithPath: $0).pathComponents.count
            let b = URL(fileURLWithPath: $1).pathComponents.count
            return a == b ? $0 < $1 : a < b
        }
        for path in orderedParents where directories[path] == nil { attachDirectory(path) }
        for path in Array(files.keys) {
            guard let watch = files[path] else { continue }
            if !paths.contains(path) || identity(at: path, type: .typeRegular) == nil {
                files.removeValue(forKey: path)?.source?.cancel()
            } else if identity(at: path, type: .typeRegular) != watch.sourceIdentity {
                watch.source?.cancel(); watch.source = nil; watch.sourceID = nil; watch.sourceIdentity = nil
            }
        }
        for path in paths.sorted() {
            guard identity(at: path, type: .typeRegular) != nil else { continue }
            let watch = files[path] ?? FileWatch(path); files[path] = watch
            if watch.source == nil { attachFile(watch) }
            if let replay { read(watch, replay: replay) }
            read(watch)
        }
        reportScan()
    }

    private func attachDirectory(_ path: String) {
        let fd = open(path, O_EVTONLY); guard fd >= 0 else { return }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { close(fd); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        let watch = DirectoryWatch(path: path, identity: FileIdentity(info), source: source)
        directories[path] = watch
        let report = checkpoint; let id = watch.id
        source.setCancelHandler { close(fd); report?(.cancelled(path: path, directory: true, id: id)) }
        source.setRegistrationHandler { [weak self, weak watch] in
            guard let self, let watch, self.directories[path] === watch else { return }
            self.checkpoint?(.registered(path: path, directory: true, id: id))
            self.rescan()
        }
        source.setEventHandler { [weak self, weak watch] in
            guard let self, let watch, self.directories[path] === watch else { return }
            if !watch.source.data.intersection([.rename, .delete]).isEmpty {
                self.directories.removeValue(forKey: path)?.source.cancel()
            }
            self.rescan()
        }
        activateSource(path, true, source)
    }

    private func attachFile(_ watch: FileWatch) {
        let path = watch.path; let fd = open(path, O_EVTONLY); guard fd >= 0 else { return }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); return }
        // On macOS ftruncate to zero reports NOTE_ATTRIB, not NOTE_WRITE.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: queue)
        let id = UUID(); watch.source = source; watch.sourceID = id; watch.sourceIdentity = FileIdentity(info)
        let report = checkpoint
        source.setCancelHandler { close(fd); report?(.cancelled(path: path, directory: false, id: id)) }
        source.setRegistrationHandler { [weak self, weak watch] in
            guard let self, let watch, self.files[path] === watch, watch.sourceID == id else { return }
            self.checkpoint?(.registered(path: path, directory: false, id: id))
            self.read(watch)
        }
        source.setEventHandler { [weak self, weak watch] in
            guard let self, let watch, self.files[path] === watch, watch.sourceID == id else { return }
            if !(watch.source?.data.intersection([.rename, .delete]).isEmpty ?? true) {
                watch.source?.cancel(); watch.source = nil; watch.sourceID = nil; watch.sourceIdentity = nil
                self.rescan()
            } else { self.read(watch) }
        }
        activateSource(path, false, source)
    }

    private func reportScan() {
        checkpoint?(.scanCompleted(directories: directories.keys.sorted(), files: files.keys.sorted(), contexts: contexts.count))
    }

    private func read(_ watch: FileWatch, replay: String? = nil) {
        guard files[watch.path] === watch, !contexts.isEmpty,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: watch.path)) else { return }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return }
        let inode = FileIdentity(info)
        // The open read handle supplies both identity and size, so rotation
        // cannot combine the old path's cursor with the new file's contents.
        guard inode == watch.sourceIdentity else {
            queue.async { [weak self] in self?.rescan() }; return
        }
        let length = UInt64(info.st_size); let limit: UInt64 = 262_144
        var offset = replay == nil ? watch.offset : nil
        var partial = replay == nil ? watch.partial : Data()
        var dropping = replay == nil && watch.droppingLine
        if offset == nil || watch.identity != inode || offset! > length || length - offset! > limit {
            offset = length > limit ? length - limit : 0; partial.removeAll(); dropping = offset! > 0
        }
        do {
            if offset! < length {
                try handle.seek(toOffset: offset!)
                let data = try handle.read(upToCount: Int(limit)) ?? Data(); offset! += UInt64(data.count)
                let now = clock()
                for byte in data {
                    if byte == 10 {
                        if !dropping, let record = AionUiCancellationLog.parse(partial, observedAt: now),
                           replay == nil || replay == record.conversationID,
                           let context = contexts[record.conversationID] {
                            var tracker = trackers[record.conversationID] ?? AionUiCancellationTracker()
                            let signal = tracker.consume(record, context: context)
                            trackers[record.conversationID] = tracker
                            if let signal { handler(signal) }
                        }
                        partial.removeAll(keepingCapacity: true); dropping = false
                    } else if !dropping {
                        if partial.count < 4_096 { partial.append(byte) }
                        else { partial.removeAll(keepingCapacity: true); dropping = true }
                    }
                }
            }
            // Persist reset state even at empty EOF. Otherwise a truncate to
            // zero keeps the previous cursor and partial line for later writes.
            if replay == nil {
                watch.offset = offset; watch.identity = inode; watch.partial = partial; watch.droppingLine = dropping
                checkpoint?(.read(path: watch.path, offset: offset!, partial: partial.count, dropping: dropping, inode: inode.inode))
            }
        } catch { }
    }

    deinit {
        for watch in files.values { watch.source?.cancel() }
        for watch in directories.values { watch.source.cancel() }
    }
}
