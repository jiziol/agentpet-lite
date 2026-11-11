import Foundation
import AgentPetCore

/// Bounded AO host observer. It reads only the official run file and the
/// loopback read API, applies a host projection to the existing store, and
/// uses AO's documented SSE change stream to invalidate that projection.
/// It never sends a model request, writes AO state, or creates a recovery
/// task.
@MainActor
final class AOHostObserver {
    typealias RunFileReader = @Sendable () -> AORunFile?
    typealias SnapshotHandler = (AOSnapshot, Date) -> [AOHostTransition]
    typealias UnavailableHandler = (Date) -> [AOHostTransition]
    typealias TransitionHandler = (AgentSession?, AgentSession) -> Void

    private let loader: any AOHostLoading
    private let readRunFile: RunFileReader
    private let applySnapshot: SnapshotHandler
    private let markUnavailable: UnavailableHandler
    private let notify: TransitionHandler
    private let refreshUI: () -> Void
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var refreshing = false
    private var stopped = false
    private var lastRun: AORunFile?
    private var lastRefreshAt = Date.distantPast
    private var unavailable = false

    init(loader: any AOHostLoading = AOAPIClient(),
         readRunFile: @escaping RunFileReader = { AORunFile.read() },
         applySnapshot: @escaping SnapshotHandler,
         markUnavailable: @escaping UnavailableHandler,
         notify: @escaping TransitionHandler = { _, _ in },
         refreshUI: @escaping () -> Void = {},
         pollInterval: TimeInterval = 5) {
        self.loader = loader
        self.readRunFile = readRunFile
        self.applySnapshot = applySnapshot
        self.markUnavailable = markUnavailable
        self.notify = notify
        self.refreshUI = refreshUI
        self.pollInterval = max(1, pollInterval)
    }

    func start() {
        guard pollTask == nil, !stopped else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                await self.refreshNow()
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        stopped = true
        pollTask?.cancel(); pollTask = nil
        eventTask?.cancel(); eventTask = nil
    }

    /// One coalesced refresh. Discovery and HTTP run off the main actor; the
    /// store projection and UI notification run on it.
    func refreshNow() async {
        guard !stopped, !refreshing else { return }
        refreshing = true
        lastRefreshAt = Date()
        let loader = self.loader
        let readRunFile = self.readRunFile
        let loaded = await Task.detached(priority: .utility) { () -> (AORunFile, AOSnapshot?)? in
            guard let run = readRunFile() else { return nil }
            let snapshot = await loader.load(run, now: Date())
            return (run, snapshot)
        }.value
        refreshing = false
        guard !stopped else { return }
        let now = Date()
        guard let loaded else {
            if !unavailable {
                unavailable = true
                deliver(markUnavailable(now))
            }
            return
        }
        let (run, snapshot) = loaded
        guard let snapshot else {
            if !unavailable {
                unavailable = true
                deliver(markUnavailable(now))
            }
            return
        }
        unavailable = false
        if lastRun?.appRunID != run.appRunID {
            lastRun = run
            restartEventStream(run)
        } else {
            lastRun = run
        }
        deliver(applySnapshot(snapshot, now))
    }

    private func deliver(_ transitions: [AOHostTransition]) {
        for transition in transitions {
            // Initial history is never a notification. A real waiting
            // transition still reaches the existing policy below.
            if transition.before != nil { notify(transition.before, transition.after) }
        }
        refreshUI()
    }

    private func restartEventStream(_ run: AORunFile) {
        eventTask?.cancel()
        let onInvalidate: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.eventInvalidated()
            }
        }
        eventTask = Task.detached(priority: .utility) {
            await Self.consumeEvents(run: run, onInvalidate: onInvalidate)
        }
    }

    /// SSE lines are consumed and parsed off the main actor. The callback only
    /// coalesces an invalidation; snapshot merging and UI refresh stay on the
    /// main actor. A non-200 response ends this stream; the bounded poll is the
    /// fallback and the next daemon generation starts a new stream.
    private nonisolated static func consumeEvents(
        run: AORunFile,
        onInvalidate: @escaping @Sendable () -> Void
    ) async {
        var backoff: TimeInterval = 1
        while !Task.isCancelled {
            guard let url = URL(string: "http://127.0.0.1:\(run.port)/api/v1/events?after=latest") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 60
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            do {
                let (bytes, response) = try await StreamSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.host == "127.0.0.1", http.url?.port == run.port else { return }
                var parser = AOSSEParser()
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.utf8.count > 16_384 {
                        parser = AOSSEParser()
                        continue
                    }
                    if let event = parser.consume(line: line), AOSSEParser.invalidates(event.type) {
                        onInvalidate()
                    }
                }
            } catch {
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch {
                return
            }
            backoff = min(backoff * 2, 30)
        }
    }

    private enum StreamSession {
        static let shared: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.waitsForConnectivity = false
            configuration.connectionProxyDictionary = [:]
            return URLSession(configuration: configuration)
        }()
    }

    private func eventInvalidated() async {
        guard !stopped, !refreshing else { return }
        // Bursts of CDC rows coalesce into one bounded snapshot read.
        if Date().timeIntervalSince(lastRefreshAt) < 0.5 { return }
        await refreshNow()
    }

}
