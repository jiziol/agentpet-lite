import Foundation

public enum CodexTurnResult: String, Codable, Sendable {
    case completed, cancelled, failed
}

/// Extracts only native lifecycle metadata, discarding message bodies.
public struct CodexLifecycle: Sendable, Equatable {
    public let turnID: String
    public let timestamp: Date
    public let startedAt: Date?
    public let result: CodexTurnResult?

    public static func parse(_ data: Data) -> CodexLifecycle? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              let type = payload["type"] as? String,
              ["task_started", "task_complete", "turn_aborted"].contains(type),
              let turnID = payload["turn_id"] as? String, !turnID.isEmpty,
              let timestamp = date(root["timestamp"]) else { return nil }
        let result: CodexTurnResult?
        switch type {
        case "task_complete":
            let error = payload["error"]
            if error == nil || error is NSNull {
                result = .completed
            } else {
                let info = (error as? [String: Any])?["codex_error_info"] as? String
                result = ["turn_aborted", "cancelled", "canceled", "interrupted"].contains(info ?? "") ? .cancelled : .failed
            }
        case "turn_aborted": result = .cancelled
        default: result = nil
        }
        return CodexLifecycle(turnID: turnID, timestamp: timestamp,
                              startedAt: date(payload["started_at"]), result: result)
    }

    static func date(_ value: Any?) -> Date? {
        if let value = value as? String {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: value) { return date }
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: value)
        }
        if let value = value as? Double {
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        }
        return nil
    }
}

/// One file watch per known session, with bounded incremental reads. No full
/// session-directory scans or polling. Optional speech copies only a bounded
/// user-visible assistant message from new records; attachment never replays it.
public final class CodexLifecycleWatcher: @unchecked Sendable {
    private final class Watch: @unchecked Sendable {
        let path: String
        let source: DispatchSourceFileSystemObject
        var offset: UInt64 = 0
        var partial = Data()
        var skippingOversizedLine = false
        var attaching = true
        var latestOnAttachment: CodexLifecycle?
        var input = CodexHumanInputTracker()
        var turnID: String?
        var turnStartedAt: Date?
        init(path: String, source: DispatchSourceFileSystemObject) {
            self.path = path; self.source = source
        }
    }
    private let queue = DispatchQueue(label: "agentpet.codex-lifecycle", qos: .utility)
    private var watches: [String: Watch] = [:]
    private let handler: @Sendable (String, CodexLifecycle) -> Void
    private let inputHandler: @Sendable (String, HumanIntervention, Date) -> Void
    private let messageHandler: @Sendable (String, CodexVisibleMessage) -> Void
    private var messagesEnabled = false

    public init(inputHandler: @escaping @Sendable (String, HumanIntervention, Date) -> Void = { _, _, _ in },
                messageHandler: @escaping @Sendable (String, CodexVisibleMessage) -> Void = { _, _ in },
                handler: @escaping @Sendable (String, CodexLifecycle) -> Void) {
        self.handler = handler; self.inputHandler = inputHandler; self.messageHandler = messageHandler
    }

    public func setMessagesEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.messagesEnabled = enabled }
    }

    public func watch(sessionID: String, path: String) {
        queue.async { [weak self] in
            guard let self, self.watches[sessionID]?.path != path else { return }
            self.watches.removeValue(forKey: sessionID)?.source.cancel()
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete], queue: self.queue)
            let watch = Watch(path: path, source: source)
            self.watches[sessionID] = watch
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self, weak watch] in
                guard let self, let watch else { return }
                if !watch.source.data.intersection([.rename, .delete]).isEmpty {
                    self.watches.removeValue(forKey: sessionID)?.source.cancel()
                    self.watch(sessionID: sessionID, path: path)
                } else { self.read(sessionID: sessionID, watch: watch) }
            }
            source.resume()
            // Find the newest lifecycle record in a bounded tail on attachment.
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber {
                watch.offset = UInt64(max(0, size.int64Value - 16_777_216))
                watch.skippingOversizedLine = watch.offset > 0
            }
            self.read(sessionID: sessionID, watch: watch)
        }
    }

    public func retain(sessionIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            for id in Array(self.watches.keys) where !sessionIDs.contains(id) {
                self.watches.removeValue(forKey: id)?.source.cancel()
            }
        }
    }

    private func read(sessionID: String, watch: Watch) {
        guard let file = FileHandle(forReadingAtPath: watch.path) else { return }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            if size < watch.offset {
                watch.offset = 0; watch.partial.removeAll(); watch.skippingOversizedLine = false
                watch.input = CodexHumanInputTracker()
                watch.turnID = nil
                watch.turnStartedAt = nil
            }
            try file.seek(toOffset: watch.offset)
            let data = try file.read(upToCount: 524_288) ?? Data()
            watch.offset += UInt64(data.count)
            watch.partial.append(data)
            var latestMessage: CodexVisibleMessage?
            while let end = watch.partial.firstIndex(of: 0x0A) {
                let line = Data(watch.partial[..<end])
                watch.partial.removeSubrange(...end)
                if watch.skippingOversizedLine { watch.skippingOversizedLine = false; continue }
                if line.count <= 1_048_576, let event = CodexLifecycle.parse(line) {
                    if event.result == nil {
                        watch.turnID = event.turnID; watch.turnStartedAt = event.timestamp; latestMessage = nil
                    }
                    if watch.attaching { watch.latestOnAttachment = event }
                    else { handler(sessionID, event) }
                }
                if messagesEnabled, !watch.attaching,
                   let message = CodexVisibleMessage.parse(line, turnID: watch.turnID, turnStartedAt: watch.turnStartedAt) {
                    latestMessage = message
                }
                if let (change, at) = watch.input.ingest(line), !watch.attaching { inputHandler(sessionID, change, at) }
            }
            if watch.partial.count > 1_048_576 {
                watch.partial.removeAll(keepingCapacity: false)
                watch.skippingOversizedLine = true
            }
            // Coalesce bursts within each bounded read, without retaining history.
            if let latestMessage { messageHandler(sessionID, latestMessage) }
            if watch.offset < size {
                queue.async { [weak self, weak watch] in
                    guard let self, let watch, self.watches[sessionID] === watch else { return }
                    self.read(sessionID: sessionID, watch: watch)
                }
            } else if watch.attaching {
                watch.attaching = false
                let pending = watch.input.pending
                if let at = pending.map(\.createdAt).max() { inputHandler(sessionID, HumanIntervention(action: .asked, requests: pending), at) }
                let resolved = watch.input.resolved
                for request in resolved.sorted(by: { $0.createdAt < $1.createdAt }) {
                    inputHandler(sessionID, HumanIntervention(action: .resolved, requests: [request]), request.createdAt)
                }
                if let event = watch.latestOnAttachment { handler(sessionID, event) }
                watch.latestOnAttachment = nil
            }
        } catch { /* A transient read failure must not change task state. */ }
    }

    deinit { for watch in watches.values { watch.source.cancel() } }
}
