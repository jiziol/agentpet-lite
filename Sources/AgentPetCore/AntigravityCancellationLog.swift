import Foundation

/// A native cancellation acknowledgement, distinct from a persisted executor
/// result. This never derives a stop from assistant prose or generic errors.
public struct AntigravityCancellationSignal: Sendable, Equatable {
    public let sessionID: String
    public let timestamp: Date
    public let expectedHookAt: Date
}

public enum AntigravityCancellationLog {
    /// Only the server's exact conversation-cancellation record is accepted.
    /// Go's local-time prefix omits the year; select the nearest year, rejecting
    /// records outside a day of observation (including ambiguous old log tails).
    public static func parse(_ line: String, observedAt: Date, timeZone: TimeZone = .current) -> (sessionID: String, timestamp: Date)? {
        guard line.utf8.count <= 512, line.contains("] Cancelling conversation "), line.contains(" server.go:"),
              let regex = try? NSRegularExpression(pattern: #"^I(\d{2})(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{6}) +\d+ server\.go:\d+\] Cancelling conversation ([0-9a-fA-F-]{36}) \(killBackgroundTasks=(?:true|false)\)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func part(_ n: Int) -> String { String(line[Range(match.range(at: n), in: line)!]) }
        guard let id = UUID(uuidString: part(7)),
              let month = Int(part(1)), (1...12).contains(month),
              let day = Int(part(2)), (1...31).contains(day),
              let hour = Int(part(3)), (0...23).contains(hour),
              let minute = Int(part(4)), (0...59).contains(minute),
              let second = Int(part(5)), (0...59).contains(second),
              let micros = Int(part(6)) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let year = calendar.component(.year, from: observedAt)
        let candidates = (year-1...year+1).compactMap { year -> Date? in
            let components = DateComponents(year: year, month: month, day: day,
                hour: hour, minute: minute, second: second, nanosecond: micros * 1000)
            guard let at = calendar.date(from: components),
                  calendar.component(.month, from: at) == components.month,
                  calendar.component(.day, from: at) == components.day else { return nil }
            return at
        }
        guard let at = candidates.min(by: { abs($0.timeIntervalSince(observedAt)) < abs($1.timeIntervalSince(observedAt)) }),
              at <= observedAt.addingTimeInterval(1), observedAt.timeIntervalSince(at) <= 86_400 else { return nil }
        return (id.uuidString.lowercased(), at)
    }
}

/// Incrementally reads bounded native log tails. No terminal interception,
/// client changes, idle polling, or exported message/command contents.
public final class AntigravityCancellationLogWatcher: @unchecked Sendable {
    private final class FileWatch: @unchecked Sendable {
        let path: String
        var source: DispatchSourceFileSystemObject?
        var offset: UInt64?
        var inode: NSNumber?
        var partial = Data()
        var droppingLine = false
        init(_ path: String) { self.path = path }
    }
    private struct SessionWatch {
        let hookAt: Date
        var lastSignalAt: Date?
    }
    private let queue = DispatchQueue(label: "agentpet.antigravity-cancellation-log", qos: .utility)
    private let directory: String
    private let handler: @Sendable (AntigravityCancellationSignal) -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var files: [String: FileWatch] = [:]
    private var sessions: [String: SessionWatch] = [:]

    public init(directory: String = NSHomeDirectory() + "/.gemini/antigravity-cli/log", handler: @escaping @Sendable (AntigravityCancellationSignal) -> Void) {
        self.directory = directory; self.handler = handler
    }
    public func watch(sessionID: String, latestHookAt: Date) {
        guard let uuid = UUID(uuidString: sessionID) else { return }
        let id = uuid.uuidString.lowercased()
        queue.async { [weak self] in
            guard let self else { return }
            let changed = self.sessions[id]?.hookAt != latestHookAt
            if changed {
                guard self.sessions[id] != nil || self.sessions.count < 64 else { return }
                self.sessions[id] = SessionWatch(hookAt: latestHookAt)
            }
            if self.directorySource == nil { self.attachDirectory() }
            if changed || self.files.isEmpty { self.rescan() }
        }
    }
    public func retain(sessionIDs: Set<String>) {
        let ids = Set(sessionIDs.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })
        queue.async { [weak self] in
            guard let self else { return }
            self.sessions = self.sessions.filter { ids.contains($0.key) }
            if self.sessions.isEmpty {
                self.directorySource?.cancel(); self.directorySource = nil
                for watch in self.files.values { watch.source?.cancel() }
                self.files.removeAll()
            }
        }
    }
    private func attachDirectory() {
        let fd = open(directory, O_EVTONLY); guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: queue)
        directorySource = source; source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.rescan() }; source.resume()
    }
    private func rescan() {
        guard !sessions.isEmpty,
              let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return }
        var candidates: [(String, Date)] = []
        // At most 256 direct entries and 32 native log files. Never recurse.
        for case let url as URL in enumerator.prefix(256) {
            guard url.lastPathComponent.range(of: #"^cli-\d{8}_\d{6}\.log$"#, options: .regularExpression) != nil,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date else { continue }
            candidates.append((url.path, modified))
        }
        let selected = Set(candidates.sorted { $0.1 > $1.1 }.prefix(32).map(\.0))
        for path in Array(files.keys) where !selected.contains(path) { files.removeValue(forKey: path)?.source?.cancel() }
        for path in selected {
            let watch = files[path] ?? FileWatch(path); files[path] = watch
            if watch.source == nil {
                let fd = open(path, O_EVTONLY); guard fd >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
                watch.source = source; source.setCancelHandler { close(fd) }
                source.setEventHandler { [weak self, weak watch] in
                    guard let self, let watch else { return }
                    if !(watch.source?.data.intersection([.rename, .delete]).isEmpty ?? true) {
                        watch.source?.cancel(); watch.source = nil; self.rescan()
                    } else { self.read(watch) }
                }; source.resume()
            }
            read(watch)
        }
    }
    private func read(_ watch: FileWatch) {
        guard files[watch.path] === watch, !sessions.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: watch.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: watch.path)) else { return }
        defer { try? handle.close() }
        let length = size.uint64Value
        if watch.offset == nil || watch.inode != inode || watch.offset! > length {
            watch.offset = length > 65_536 ? length - 65_536 : 0
            watch.partial.removeAll(); watch.droppingLine = watch.offset! > 0; watch.inode = inode
        }
        if length - watch.offset! > 65_536 {
            watch.offset = length - 65_536; watch.partial.removeAll(); watch.droppingLine = true
        }
        guard watch.offset! < length else { return }
        do {
            try handle.seek(toOffset: watch.offset!)
            let data = try handle.read(upToCount: 65_536) ?? Data(); watch.offset! += UInt64(data.count)
            let observedAt = Date()
            for byte in data {
                if byte == 10 {
                    if !watch.droppingLine { consume(watch.partial, observedAt: observedAt) }
                    watch.partial.removeAll(keepingCapacity: true); watch.droppingLine = false
                } else if !watch.droppingLine {
                    if watch.partial.count < 512 { watch.partial.append(byte) }
                    else { watch.partial.removeAll(keepingCapacity: true); watch.droppingLine = true }
                }
            }
        } catch { }
    }
    private func consume(_ data: Data, observedAt: Date) {
        guard let line = String(data: data, encoding: .utf8),
              let parsed = AntigravityCancellationLog.parse(line, observedAt: observedAt),
              var context = sessions[parsed.sessionID], parsed.timestamp >= context.hookAt,
              context.lastSignalAt == nil || parsed.timestamp > context.lastSignalAt! else { return }
        context.lastSignalAt = parsed.timestamp; sessions[parsed.sessionID] = context
        handler(AntigravityCancellationSignal(sessionID: parsed.sessionID, timestamp: parsed.timestamp, expectedHookAt: context.hookAt))
    }
    deinit { directorySource?.cancel(); for watch in files.values { watch.source?.cancel() } }
}
