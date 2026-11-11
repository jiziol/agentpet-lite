import Foundation
import CryptoKit

/// One serial, bounded owner for committed-response observations. Text never
/// enters the persistent lifecycle queue. There is no idle polling or per-token Task.
public final class AntigravitySpeechWatcher: @unchecked Sendable {
    private final class Watch: @unchecked Sendable {
        let path: String
        let transcriptPath: String?
        let joinedAt: Date
        var boundary: AntigravityVisibleMessage.Boundary
        var sources: [String: DispatchSourceFileSystemObject] = [:]
        var work: DispatchWorkItem?
        var ticket = 0
        var retries = 0
        var step: AntigravityPublicResponse.Step?
        var hostRow: String?
        var wasHosted = false
        var signature: Data?
        var deliveredBoundary: AntigravityVisibleMessage.Boundary?
        var revision = 0
        var withdrawn = false
        var hostWaitUntil: Date?
        init(path: String, boundary: AntigravityVisibleMessage.Boundary) {
            self.path = path; self.boundary = boundary; joinedAt = Date()
            transcriptPath = AntigravityCompletedTranscript.path(database: path, sessionID: boundary.sessionID)
        }
    }
    private let queue = DispatchQueue(label: "agentpet.agy-speech", qos: .utility)
    private var watches: [String: Watch] = [:]
    private var hostSources: [String: DispatchSourceFileSystemObject] = [:]
    private let database: String
    private let handler: @Sendable (String, AntigravityVisibleMessage) -> Void
    public init(database: String = AionUiMetadata.defaultDatabase,
                handler: @escaping @Sendable (String, AntigravityVisibleMessage) -> Void) {
        self.database = database; self.handler = handler
    }
    public func watch(path: String, boundary: AntigravityVisibleMessage.Boundary) {
        queue.async { [weak self] in
            guard let self else { return }
            let id = boundary.sessionID
            if let watch = self.watches[id] {
                guard watch.path == path else { return }
                if watch.boundary != boundary {
                    watch.boundary = boundary
                    self.schedule(id, watch)
                }
                return
            }
            guard self.watches.count < 64 else { return }
            let watch = Watch(path: path, boundary: boundary)
            self.watches[id] = watch
            self.attach(id, watch); self.attachHost(); self.schedule(id, watch)
        }
    }
    private func source(_ path: String, action: @escaping @Sendable () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY); guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete], queue: queue)
        s.setCancelHandler { close(fd) }; s.setEventHandler(handler: action); s.resume()
        return s
    }
    private func attach(_ id: String, _ watch: Watch) {
        let directory = (watch.path as NSString).deletingLastPathComponent
        let transcriptPaths = watch.transcriptPath.map { [(($0 as NSString).deletingLastPathComponent), $0] } ?? []
        for path in [directory, watch.path] + transcriptPaths where watch.sources[path] == nil {
            watch.sources[path] = source(path) { [weak self, weak watch] in
                guard let self, let watch, self.watches[id] === watch else { return }
                if !(watch.sources[path]?.data.intersection([.delete, .rename]).isEmpty ?? true) {
                    watch.sources.removeValue(forKey: path)?.cancel()
                }
                self.attach(id, watch); self.schedule(id, watch)
            }
        }
    }
    private func attachHost() {
        guard !watches.isEmpty else { return }
        for path in [(database as NSString).deletingLastPathComponent, database, database + "-wal"] where hostSources[path] == nil {
            hostSources[path] = source(path) { [weak self] in
                guard let self else { return }
                if !(self.hostSources[path]?.data.intersection([.delete, .rename]).isEmpty ?? true) {
                    self.hostSources.removeValue(forKey: path)?.cancel()
                }
                self.attachHost()
                let now = Date()
                for (id, watch) in self.watches where (watch.hostWaitUntil ?? .distantPast) > now
                    || ((watch.boundary.hosted || watch.wasHosted) && (watch.step?.completedAt.addingTimeInterval(10) ?? .distantPast) > now) {
                    self.schedule(id, watch)
                }
            }
        }
    }
    private func schedule(_ id: String, _ watch: Watch, retry: Bool = false) {
        guard watch.work == nil else { return }
        watch.ticket += 1; let ticket = watch.ticket
        let work = DispatchWorkItem { [weak self, weak watch] in
            guard let self, let watch, self.watches[id] === watch, watch.ticket == ticket else { return }
            watch.work = nil
            let now = Date()
            let transcript = watch.transcriptPath.flatMap { AntigravityCompletedTranscript.read(path: $0, boundary: watch.boundary) }
            let source = transcript.map { AntigravityPublicResponse.Snapshot(step: $0, cancelled: false) }
                ?? AntigravityPublicResponse.read(path: watch.path, boundary: watch.boundary)
            guard let snapshot = source else {
                if watch.retries < 6 {
                    watch.retries += 1; self.schedule(id, watch, retry: true)
                }
                return
            }
            watch.retries = 0
            guard !snapshot.cancelled, let step = snapshot.step,
                  step.completedAt >= max(watch.joinedAt, watch.boundary.enabledAt),
                  step.completedAt <= now.addingTimeInterval(2) else { self.withdraw(id, watch, now: now); return }
            let same = watch.step?.index == step.index && watch.step?.executionID == step.executionID
            if !same { watch.hostRow = nil; watch.signature = nil; watch.withdrawn = false }
            // A source event can only establish a fresh committed item. Host
            // revisions of an already established item cannot renew its UI life.
            guard same || step.completedAt.addingTimeInterval(5) > now else { return }
            guard let host = AntigravityHostVisibility.read(nativeID: id, step: step,
                startedAt: watch.boundary.startedAt, knownRow: watch.hostRow,
                previouslyHosted: watch.wasHosted || watch.boundary.hosted, database: self.database) else {
                    watch.hostWaitUntil = step.completedAt.addingTimeInterval(5)
                    return
                }
            watch.hostWaitUntil = nil
            watch.wasHosted = watch.wasHosted || !host.id.isEmpty
            watch.step = AntigravityPublicResponse.Step(index: step.index, executionID: step.executionID,
                completedAt: step.completedAt, text: "") // No full-body retention.
            watch.hostRow = host.id.isEmpty ? nil : host.id
            guard let text = host.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.withdraw(id, watch, now: now); return
            }
            guard step.completedAt.addingTimeInterval(5) > now else { return }
            let short = String(text.prefix(320))
            let signature = Data(SHA256.hash(data: Data(short.utf8)))
            guard !watch.withdrawn, signature != watch.signature || watch.deliveredBoundary != watch.boundary else { return }
            watch.signature = signature; watch.deliveredBoundary = watch.boundary; watch.revision += 1
            self.handler(id, AntigravityVisibleMessage(boundary: watch.boundary, executionID: step.executionID,
                stepIndex: step.index, timestamp: step.completedAt, revision: watch.revision, mode: .snapshot, text: short))
        }
        watch.work = work
        queue.asyncAfter(deadline: .now() + (retry ? 0.15 : 0.05), execute: work)
    }
    private func withdraw(_ id: String, _ watch: Watch, now: Date) {
        guard let step = watch.step, !watch.withdrawn else { return }
        watch.withdrawn = true; watch.revision += 1
        handler(id, AntigravityVisibleMessage(boundary: watch.boundary, executionID: step.executionID,
            stepIndex: step.index, timestamp: now, revision: watch.revision, mode: .withdraw, text: ""))
    }
    public func retain(sessionIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            for id in Array(self.watches.keys) where !sessionIDs.contains(id) {
                if let w = self.watches.removeValue(forKey: id) { w.work?.cancel(); w.sources.values.forEach { $0.cancel() } }
            }
            if self.watches.isEmpty { self.hostSources.values.forEach { $0.cancel() }; self.hostSources.removeAll() }
        }
    }
    deinit {
        for w in watches.values { w.work?.cancel(); w.sources.values.forEach { $0.cancel() } }
        hostSources.values.forEach { $0.cancel() }
    }
}
