import Foundation
import CSQLite

/// Native CLI step metadata only. Field numbers and enum values come from the
/// installed CLI's embedded protobuf descriptors, not from assistant prose.
public enum AntigravityHumanInput {
    public struct Cancellation: Sendable, Equatable {
        public let identity: String
        public let lastStepIndex: Int
        public let timestamp: Date
        /// The Hook revision observed with this snapshot, checked again by the
        /// main actor before applying a queued callback.
        public var expectedHookAt: Date? = nil
        public var observedAt: Date? = nil

        public func matches(stepFloor: Int?, latestHookAt: Date?) -> Bool {
            if let floor = stepFloor { return lastStepIndex >= floor }
            // Older hooks/snapshots lack a native boundary. Do not broaden
            // their time fallback or guess an execution from file mtime.
            return timestamp >= (latestHookAt ?? .distantPast)
        }
    }
    public struct Snapshot: Sendable {
        public let steps: [Step]
        public let cancellation: Cancellation?
    }
    public struct Step: Sendable {
        public let index: Int
        public let status: Int
        public let identity: String
        public let round: Int
        public let kind: HumanRequest.Kind?
        public var requestID: String { "agy:\(index):\(identity):\(round):\(kind?.rawValue ?? "permission")" }
        public var terminal: Bool { [3, 4, 5, 6, 7, 12].contains(status) }
    }

    // Small wire reader skips unknown fields without decoding their contents.
    private struct Field { let number: Int; let bytes: Data?; let integer: UInt64? }
    private static func fields(_ data: Data) -> [Field]? {
        guard data.count <= 1_048_576 else { return nil }
        let bytes = [UInt8](data); var offset = 0; var result: [Field] = []
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { return nil }
                let byte = bytes[offset]; offset += 1
                guard shift != 63 || byte <= 1 else { return nil }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            return nil
        }
        while offset < bytes.count {
            guard result.count < 4096, let tag = varint(), tag >> 3 > 0 else { return nil }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = varint() else { return nil }
                result.append(Field(number: number, bytes: nil, integer: value))
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - offset) else { return nil }
                let end = offset + Int(length)
                result.append(Field(number: number, bytes: Data(bytes[offset..<end]), integer: nil)); offset = end
            case 1, 5:
                let length = tag & 7 == 1 ? 8 : 4
                guard offset + length <= bytes.count else { return nil }; offset += length
            default: return nil
            }
        }
        return result
    }

    public static func step(index: Int, type: Int, status: Int, metadata: Data, payload: Data) -> Step? {
        guard index >= 0, let meta = fields(metadata), let body = fields(payload),
              body.first(where: { $0.number == 1 })?.integer == UInt64(type),
              body.first(where: { $0.number == 4 })?.integer == UInt64(status) else { return nil }
        func string(_ fs: [Field], _ number: Int) -> String? {
            fs.first(where: { $0.number == number })?.bytes.flatMap { String(data: $0, encoding: .utf8) }
        }
        let call = meta.first(where: { $0.number == 4 })?.bytes.flatMap(fields) ?? []
        let identity = string(meta, 12) ?? string(call, 1)
        guard let identity, HumanIntervention.validID(identity), !identity.contains(":"), identity.utf8.count <= 160 else { return nil }
        let requested = body.first(where: { $0.number == 56 })?.bytes.flatMap(fields)
        let round = body.filter { $0.number == 147 }.count
        // Some CLI responses retain requested_interaction while recording its
        // completed response. It is not a fresh question just because the tool
        // has not left RUNNING yet. Compare opaque requests, never their text.
        let requestBytes = body.first(where: { $0.number == 56 })?.bytes
        let completedRequest = body.last(where: { $0.number == 147 })?.bytes.flatMap(fields)?.first(where: { $0.number == 1 })?.bytes
        let alreadyCompleted = requestBytes != nil && requestBytes == completedRequest
        let kind: HumanRequest.Kind?
        if [2, 9].contains(status) && !alreadyCompleted {
            if requested?.contains(where: { $0.number == 22 }) == true || (round == 0 && (type == 138 || string(call, 2) == "ask_question")) {
                kind = .choice
            } else if requested?.contains(where: { $0.number == 20 }) == true {
                kind = .reply
            } else if requested != nil || status == 9 {
                kind = .permission
            } else { kind = nil }
        } else { kind = nil }
        return Step(index: index, status: status, identity: identity, round: round, kind: kind)
    }

    public static func databasePath(sessionID: String, home: String = NSHomeDirectory() + "/.gemini/antigravity-cli") -> String? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        return home + "/conversations/" + sessionID + ".db"
    }

    /// Immutable read mode makes no journal/lock files. It is used only for a
    /// stable delete-journal snapshot: active journals/WAL and concurrent writes
    /// reject the observation, leaving the previous state unchanged.
    public static func read(path: String, trackedIndices: Set<Int> = []) -> [Step]? {
        readSnapshot(path: path, trackedIndices: trackedIndices)?.steps
    }

    public static func readSnapshot(path: String, trackedIndices: Set<Int> = []) -> Snapshot? {
        let fm = FileManager.default
        guard let before = try? fm.attributesOfItem(atPath: path),
              let size = before[.size] as? NSNumber, size.int64Value <= 67_108_864,
              !fm.fileExists(atPath: path + "-journal"), !fm.fileExists(atPath: path + "-wal") else { return nil }
        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        var db: OpaquePointer?
        guard let uri = components.string,
              sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        let indices = trackedIndices.filter { $0 >= 0 }.sorted().prefix(64).map(String.init).joined(separator: ",")
        let tracked = indices.isEmpty ? "" : " OR idx IN (\(indices))"
        let sql = "SELECT idx, step_type, status, metadata, step_payload FROM steps WHERE (status IN (2,9)\(tracked)) AND length(metadata) <= 1048576 AND length(step_payload) <= 1048576 ORDER BY idx DESC LIMIT 256"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [Step] = []; var total = 0; var code: Int32
        repeat {
            code = sqlite3_step(statement)
            guard code == SQLITE_ROW else { break }
            func blob(_ col: Int32) -> Data? {
                let count = Int(sqlite3_column_bytes(statement, col)); total += count
                guard count > 0, count <= 1_048_576, total <= 4_194_304,
                      let pointer = sqlite3_column_blob(statement, col) else { return nil }
                return Data(bytes: pointer, count: count)
            }
            guard let metadata = blob(3), let payload = blob(4) else { return nil }
            if let step = step(index: Int(sqlite3_column_int64(statement, 0)),
                               type: Int(sqlite3_column_int(statement, 1)), status: Int(sqlite3_column_int(statement, 2)),
                               metadata: metadata, payload: payload) { result.append(step) }
        } while code == SQLITE_ROW
        guard code == SQLITE_DONE else { return nil }
        let cancellation = readCancellation(db: db, total: &total)
        guard let after = try? fm.attributesOfItem(atPath: path),
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
              !fm.fileExists(atPath: path + "-journal"), !fm.fileExists(atPath: path + "-wal") else { return nil }
        return Snapshot(steps: result, cancellation: cancellation)
    }

    private static func readCancellation(db: OpaquePointer?, total: inout Int) -> Cancellation? {
        // The latest executor row can be amended after Esc, including when the
        // last step is already DONE. A canceled tool alone is not a turn abort.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM executor_metadata ORDER BY idx DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        func blob(_ s: OpaquePointer?, _ column: Int32) -> Data? {
            let count = Int(sqlite3_column_bytes(s, column)); total += count
            guard count > 0, count <= 1_048_576, total <= 4_194_304, let bytes = sqlite3_column_blob(s, column) else { return nil }
            return Data(bytes: bytes, count: count)
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let data = blob(statement, 0), let execution = fields(data),
              execution.first(where: { $0.number == 1 })?.integer == 2,
              let identityBytes = execution.first(where: { $0.number == 9 })?.bytes,
              let identity = String(data: identityBytes, encoding: .utf8), HumanIntervention.validID(identity), identity.utf8.count <= 160 else { return nil }
        // Proto3 omits scalar zero; an abort at the first step is still valid.
        let last = execution.first(where: { $0.number == 3 })?.integer ?? 0
        guard last <= UInt64(Int32.max) else { return nil }
        var latest: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT idx, metadata FROM steps ORDER BY idx DESC LIMIT 1", -1, &latest, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(latest) }
        guard sqlite3_step(latest) == SQLITE_ROW, sqlite3_column_int64(latest, 0) == Int64(last),
              let metadata = blob(latest, 1), let step = fields(metadata),
              step.first(where: { $0.number == 12 })?.bytes == identityBytes else { return nil }
        func timestamp(_ number: Int) -> Date? {
            guard let encoded = step.first(where: { $0.number == number })?.bytes, let ts = fields(encoded),
                  let seconds = ts.first(where: { $0.number == 1 })?.integer, seconds < 253_402_300_800 else { return nil }
            let nanos = ts.first(where: { $0.number == 2 })?.integer ?? 0
            guard nanos < 1_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
        }
        guard let at = [timestamp(1), timestamp(8)].compactMap({ $0 }).max() else { return nil }
        return Cancellation(identity: identity, lastStepIndex: Int(last), timestamp: at)
    }

    public static func index(requestID: String) -> Int? {
        let parts = requestID.split(separator: ":")
        guard parts.count == 5, parts[0] == "agy", let index = Int(parts[1]), index >= 0 else { return nil }
        return index
    }
}

/// Watches exact known databases, never enumerates conversation directories.
public final class AntigravityHumanInputWatcher: @unchecked Sendable {
    private final class Watch: @unchecked Sendable {
        let path: String
        var source: DispatchSourceFileSystemObject?
        var directorySource: DispatchSourceFileSystemObject?
        var scheduledRead: DispatchWorkItem?
        var scheduledRetry = false
        var readGeneration = 0
        var lastStamp: String?
        var pending: [HumanRequest]
        var lastCancellation: AntigravityHumanInput.Cancellation?
        var latestHookAt: Date?
        var stepFloor: Int?
        var retries = 0
        init(path: String, pending: [HumanRequest]) { self.path = path; self.pending = pending }
    }
    private let queue = DispatchQueue(label: "agentpet.antigravity-input", qos: .utility)
    private var watches: [String: Watch] = [:]
    private let handler: @Sendable (String, HumanIntervention, Date) -> Void
    private let cancellationHandler: @Sendable (String, AntigravityHumanInput.Cancellation) -> Void
    public init(cancellationHandler: @escaping @Sendable (String, AntigravityHumanInput.Cancellation) -> Void = { _, _ in }, handler: @escaping @Sendable (String, HumanIntervention, Date) -> Void) {
        self.handler = handler; self.cancellationHandler = cancellationHandler
    }

    public func watch(sessionID: String, path: String, pending: [HumanRequest] = [], latestHookAt: Date? = nil, stepFloor: Int? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if let watch = self.watches[sessionID] {
                if watch.latestHookAt != latestHookAt || watch.stepFloor != stepFloor {
                    watch.latestHookAt = latestHookAt; watch.stepFloor = stepFloor
                    watch.lastStamp = nil; watch.lastCancellation = nil
                    self.schedule(sessionID, watch)
                }
                return
            }
            guard self.watches.count < 64 else { return }
            let watch = Watch(path: path, pending: pending.filter { AntigravityHumanInput.index(requestID: $0.id) != nil })
            watch.latestHookAt = latestHookAt; watch.stepFloor = stepFloor
            self.watches[sessionID] = watch
            let dirFD = open((path as NSString).deletingLastPathComponent, O_EVTONLY)
            if dirFD >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write], queue: self.queue)
                watch.directorySource = source; source.setCancelHandler { close(dirFD) }
                source.setEventHandler { [weak self, weak watch] in
                    guard let self, let watch else { return }; self.schedule(sessionID, watch)
                }; source.resume()
            }
            self.attach(sessionID, watch)
            self.schedule(sessionID, watch)
        }
    }
    private func attach(_ id: String, _ watch: Watch) {
        guard watch.source == nil else { return }
        let fd = open(watch.path, O_EVTONLY); guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        watch.source = source; source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self, weak watch] in
            guard let self, let watch else { return }
            if !(watch.source?.data.intersection([.rename, .delete]).isEmpty ?? true) { watch.source?.cancel(); watch.source = nil }
            self.schedule(id, watch)
        }; source.resume()
    }
    private func schedule(_ id: String, _ watch: Watch, retryDelay: TimeInterval? = nil) {
        if retryDelay == nil {
            // New writes (including journal removal at commit) get a fresh,
            // immediate attempt, even while a backed-off retry is pending.
            watch.retries = 0
            if watch.scheduledRead != nil && !watch.scheduledRetry { return }
            watch.scheduledRead?.cancel()
        } else if watch.scheduledRead != nil { return }
        watch.scheduledRetry = retryDelay != nil
        watch.readGeneration += 1
        let generation = watch.readGeneration
        let work = DispatchWorkItem { [weak self, weak watch] in
            guard let self, let watch, self.watches[id] === watch,
                  watch.readGeneration == generation else { return }
            watch.scheduledRead = nil; self.attach(id, watch)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: watch.path),
                  let modified = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? NSNumber, let inode = attrs[.systemFileNumber] as? NSNumber else { return }
            let stamp = "\(inode):\(size):\(modified.timeIntervalSince1970)"
            guard stamp != watch.lastStamp else { return }
            guard let snapshot = AntigravityHumanInput.readSnapshot(path: watch.path, trackedIndices: Set(watch.pending.compactMap { AntigravityHumanInput.index(requestID: $0.id) })) else {
                // A coalesced write may still be inside the delete-journal
                // transaction. Retry briefly without scanning or idle polling.
                if watch.retries < 6 {
                    let delay = min(0.025 * pow(2, Double(watch.retries)), 0.4)
                    watch.retries += 1
                    self.schedule(id, watch, retryDelay: delay)
                }
                return
            }
            watch.retries = 0
            watch.lastStamp = stamp
            if let cancellation = snapshot.cancellation, cancellation.matches(stepFloor: watch.stepFloor, latestHookAt: watch.latestHookAt) {
                if cancellation != watch.lastCancellation {
                    watch.lastCancellation = cancellation
                    var observation = cancellation
                    observation.expectedHookAt = watch.latestHookAt
                    observation.observedAt = Date()
                    self.cancellationHandler(id, observation)
                }
                watch.pending = []
                return
            }
            watch.lastCancellation = nil
            let steps = snapshot.steps
            let at = Date()
            let ended = watch.pending.filter { request in
                guard let index = AntigravityHumanInput.index(requestID: request.id), let step = steps.first(where: { $0.index == index }) else { return false }
                let parts = request.id.split(separator: ":")
                guard parts.count == 5, String(parts[2]) == step.identity, let round = Int(parts[3]) else { return false }
                return step.terminal || step.round > round
            }
            if !ended.isEmpty {
                watch.pending.removeAll { request in ended.contains(where: { $0.id == request.id }) }
                self.handler(id, HumanIntervention(action: .resolved, requests: ended), at)
            }
            let asked = steps.filter { step in step.kind != nil && !watch.pending.contains(where: { $0.id == step.requestID }) }
                .sorted { $0.index < $1.index }.prefix(max(0, 64 - watch.pending.count))
                .map { HumanRequest(id: $0.requestID, kind: $0.kind!, createdAt: at) }
            if !asked.isEmpty { watch.pending.append(contentsOf: asked); self.handler(id, HumanIntervention(action: .asked, requests: asked), at) }
        }
        watch.scheduledRead = work
        queue.asyncAfter(deadline: .now() + (retryDelay ?? 0), execute: work)
    }
    public func retain(sessionIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            for id in Array(self.watches.keys) where !sessionIDs.contains(id) {
                if let watch = self.watches.removeValue(forKey: id) { watch.scheduledRead?.cancel(); watch.source?.cancel(); watch.directorySource?.cancel() }
            }
        }
    }
    deinit { for watch in watches.values { watch.scheduledRead?.cancel(); watch.source?.cancel(); watch.directorySource?.cancel() } }
}
