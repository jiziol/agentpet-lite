import Foundation

public enum SocketError: Error, Equatable {
    case create(Int32), bind(Int32), listen(Int32), configure(Int32)
    case pathTooLong, alreadyRunning
}

/// Bounded newline-delimited transport. Callbacks run serially on the IO queue
/// and must return promptly (the app enqueues work on MainActor).
public final class EventSocketServer: @unchecked Sendable {
    public struct Limits: Sendable {
        public let maxConnections: Int
        public let maxFrameBytes: Int
        public let frameTimeout: TimeInterval
        public init(maxConnections: Int = 64, maxFrameBytes: Int = 1_048_576,
                    frameTimeout: TimeInterval = 5) {
            precondition(maxConnections > 0 && maxConnections <= 1024)
            precondition(maxFrameBytes > 0 && frameTimeout.isFinite && frameTimeout > 0)
            self.maxConnections = maxConnections
            self.maxFrameBytes = maxFrameBytes
            self.frameTimeout = frameTimeout
        }
    }

    // Mutable listener and client state is confined to io.
    private final class Client: @unchecked Sendable {
        let id = UUID()
        let fd: Int32
        var source: DispatchSourceRead?
        var timer: DispatchSourceTimer?
        var buffer = Data()
        var firstFrame = true
        var closing = false
        var handoff: AgentEvent?
        var approvalToken: UUID?
        init(fd: Int32) { self.fd = fd }
    }
    private let path: String
    private let limits: Limits
    private let approvals: PendingApprovalRegistry
    private let io = DispatchQueue(label: "agentpet.socket.io")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var resources = DispatchGroup()
    private var listener: DispatchSourceRead?
    private var listenerSuspended = false
    private var generation = UUID()
    private var stopping = false
    private var clients: [UUID: Client] = [:]
    private var visibleMessage: (@Sendable (OpencodeVisibleMessage) -> Void)?
    private var dshMessage: (@Sendable (DSHVisibleMessage) -> Void)?

    public init(path: String, limits: Limits = Limits(),
                approvals: PendingApprovalRegistry = .shared) {
        self.path = path
        self.limits = limits
        self.approvals = approvals
        io.setSpecific(key: queueKey, value: true)
    }
    deinit { stop() }

    private func withIO<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try io.sync(execute: body)
    }

    public func start(onVisibleMessage: @escaping @Sendable (OpencodeVisibleMessage) -> Void = { _ in },
                      onDSHVisibleMessage: @escaping @Sendable (DSHVisibleMessage) -> Void = { _ in },
                      onEvent: @escaping @Sendable (AgentEvent) -> Void) throws {
        try withIO {
            guard listener == nil, !stopping, clients.isEmpty else { throw SocketError.alreadyRunning }
            resources = DispatchGroup()
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            guard bytes.count < capacity else { throw SocketError.pathTooLong }
            withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                    for (i, byte) in bytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                    dst[bytes.count] = 0
                }
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketError.create(errno) }
            do { try Self.configure(fd) } catch { close(fd); throw error }
            unlink(path)
            let bound = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { let code = errno; close(fd); throw SocketError.bind(code) }
            if AgentPetPaths.isLocal { chmod(path, 0o600) }
            guard listen(fd, Int32(limits.maxConnections)) == 0 else {
                let code = errno; close(fd); unlink(path); throw SocketError.listen(code)
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
            generation = UUID()
            let current = generation
            source.setEventHandler { [weak self] in self?.acceptReady(fd, generation: current, onEvent: onEvent) }
            resources.enter()
            source.setCancelHandler { [resources] in close(fd); resources.leave() }
            listener = source
            visibleMessage = onVisibleMessage
            dshMessage = onDSHVisibleMessage
            source.resume()
        }
    }

    /// Outside a callback, waits for all owned descriptors to close. A callback
    /// may call stop; cancellation completes after that callback returns.
    public func stop() {
        let insideIO = DispatchQueue.getSpecific(key: queueKey) == true
        let closingResources = withIO {
            stopping = true
            visibleMessage = nil
            dshMessage = nil
            if let listener {
                if listenerSuspended { listener.resume(); listenerSuspended = false }
                listener.cancel()
                self.listener = nil
                unlink(path)
            }
            for client in Array(clients.values) { retire(client) }
            return resources
        }
        if insideIO {
            closingResources.notify(queue: io) { [weak self] in
                guard let self, self.resources === closingResources else { return }
                self.stopping = false
            }
        } else {
            closingResources.wait()
            withIO { if resources === closingResources { stopping = false } }
        }
    }

    // Includes descriptors transferred to the approval registry until closed.
    var activeConnectionCount: Int { withIO { clients.count } }

    private static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw SocketError.configure(errno) }
    }

    enum AcceptErrorAction: Equatable { case retryImmediately, backoff, stop }
    static func acceptErrorAction(errno code: Int32) -> AcceptErrorAction {
        switch code {
        case EINTR, ECONNABORTED: return .retryImmediately
        case EBADF, EINVAL, ENOTSOCK: return .stop
        default: return .backoff
        }
    }

    private func acceptReady(_ fd: Int32, generation current: UUID,
                             onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        guard listener != nil, !stopping, generation == current else { return }
        // Yield to readers and timers under a sustained connection flood.
        for _ in 0..<32 {
            let accepted = accept(fd, nil, nil)
            if accepted < 0 {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK { return }
                switch Self.acceptErrorAction(errno: code) {
                case .retryImmediately: continue
                case .stop: stop(); return
                case .backoff:
                    listener?.suspend(); listenerSuspended = true
                    io.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                        guard let self, self.generation == current, self.listenerSuspended else { return }
                        self.listenerSuspended = false
                        self.listener?.resume()
                    }
                    return
                }
            }
            guard clients.count < limits.maxConnections else { close(accepted); continue }
            do { try Self.configure(accepted) } catch { close(accepted); continue }
            addClient(accepted, onEvent: onEvent)
        }
    }

    private func addClient(_ fd: Int32, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        let client = Client(fd: fd)
        clients[client.id] = client
        resources.enter()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        client.source = source
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.readReady(client, onEvent: onEvent)
        }
        // The source owns the fd until cancellation finishes. Registering an
        // approval sooner could close/reuse a descriptor still watched by GCD.
        source.setCancelHandler { [weak self, client, resources] in
            client.source = nil
            guard let self, !client.closing, !self.stopping, let event = client.handoff,
                  let requestID = event.approvalRequestId else {
                close(fd)
                self?.clients.removeValue(forKey: client.id)
                resources.leave()
                return
            }
            let id = client.id
            let queue = self.io
            client.approvalToken = self.approvals.register(requestId: requestID, fd: fd, onClose: { [weak self] in
                queue.async { [weak self] in
                    self?.clients.removeValue(forKey: id)
                    resources.leave()
                }
            })
            onEvent(event)
        }
        let timer = DispatchSource.makeTimerSource(queue: io)
        client.timer = timer
        timer.setEventHandler { [weak self, weak client] in
            guard let self, let client, client.handoff == nil else { return }
            self.retire(client)
        }
        resetDeadline(client)
        timer.resume()
        source.resume()
    }

    private func resetDeadline(_ client: Client) {
        // Absolute deadline for this frame, not extended by partial bytes.
        client.timer?.schedule(deadline: .now() + limits.frameTimeout)
    }

    private func retire(_ client: Client) {
        guard !client.closing else { return }
        client.closing = true
        client.timer?.cancel(); client.timer = nil
        if let token = client.approvalToken { approvals.cancel(token: token) }
        else { client.source?.cancel() }
    }

    private func readReady(_ client: Client, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        guard !client.closing, client.handoff == nil, !stopping else { return }
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var remaining = 65_536
        while remaining > 0 {
            let count = read(client.fd, &chunk, min(chunk.count, remaining))
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                retire(client); return
            }
            if count == 0 {
                if !client.buffer.isEmpty { _ = emitFrame(client, terminated: false, onEvent: onEvent) }
                retire(client); return
            }
            remaining -= count
            var start = 0
            for end in 0..<count where chunk[end] == 0x0A {
                guard append(chunk[start..<end], to: client) else { return }
                guard emitFrame(client, terminated: true, onEvent: onEvent) else { return }
                start = end + 1
            }
            guard append(chunk[start..<count], to: client) else { return }
        }
    }

    private func append(_ bytes: ArraySlice<UInt8>, to client: Client) -> Bool {
        guard bytes.count <= limits.maxFrameBytes - client.buffer.count else { retire(client); return false }
        client.buffer.append(contentsOf: bytes)
        return true
    }

    private func emitFrame(_ client: Client, terminated: Bool,
                           onEvent: @escaping @Sendable (AgentEvent) -> Void) -> Bool {
        let first = client.firstFrame
        client.firstFrame = false
        let data = client.buffer
        let isSpeech = OpencodeVisibleMessage.isEnvelope(data)
        let isDSHSpeech = DSHVisibleMessage.isEnvelope(data)
        let event = isSpeech || isDSHSpeech ? nil : try? EventCoding.decoder.decode(AgentEvent.self, from: data)
        client.buffer.removeAll(keepingCapacity: true)
        resetDeadline(client)
        if isSpeech, let message = OpencodeVisibleMessage.decode(data) { visibleMessage?(message) }
        if isDSHSpeech, let message = DSHVisibleMessage.decode(data) { dshMessage?(message) }
        if let event {
            guard !RetiredAgentRegistry.ignores(event.agentKind, rawName: event.agentName) else {
                // Retired approval frames must not acquire a held socket/registry entry.
                if event.approvalRequestId != nil { retire(client); return false }
                return !client.closing && !stopping
            }
            if event.approvalRequestId != nil {
                guard first, terminated else { retire(client); return false }
                client.handoff = event
                client.timer?.cancel(); client.timer = nil
                client.source?.cancel()
                return false
            }
            onEvent(event)
        }
        return !client.closing && !stopping
    }

    public static func drainQueue(directory: String, onEvent: (AgentEvent) -> Void) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for name in names.sorted() {
            let full = (directory as NSString).appendingPathComponent(name)
            if let data = fm.contents(atPath: full) { decodeLines(data, onEvent: onEvent) }
            try? fm.removeItem(atPath: full)
        }
    }

    static func decodeLines(_ data: Data, onEvent: (AgentEvent) -> Void) {
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if !OpencodeVisibleMessage.isEnvelope(Data(line)),
               !DSHVisibleMessage.isEnvelope(Data(line)),
               let event = try? EventCoding.decoder.decode(AgentEvent.self, from: Data(line)),
               !RetiredAgentRegistry.ignores(event.agentKind, rawName: event.agentName) { onEvent(event) }
        }
    }
}
