import Foundation
#if !SOCKET_PORTABLE
@testable import AgentPetCore
#endif

/// Shared by XCTest and the CLT-compatible runner. Only temporary sockets and
/// synthetic events are used; no daemon, native agent or user config is touched.
enum SocketTransportScenarios {
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class Checks {
        var count = 0
        func expect(_ value: Bool, _ message: String) throws {
            count += 1
            guard value else { throw Failure(description: message) }
        }
    }
    final class WeakServer {
        weak var value: EventSocketServer?
        init(_ value: EventSocketServer?) { self.value = value }
    }
    final class Events: @unchecked Sendable {
        private let condition = NSCondition()
        private var values: [AgentEvent] = []
        func append(_ event: AgentEvent) { condition.lock(); values.append(event); condition.broadcast(); condition.unlock() }
        var all: [AgentEvent] { condition.lock(); defer { condition.unlock() }; return values }
        func wait(_ count: Int, timeout: TimeInterval = 2) -> Bool {
            condition.lock(); defer { condition.unlock() }
            let end = Date().addingTimeInterval(timeout)
            while values.count < count { if !condition.wait(until: end) { return values.count >= count } }
            return true
        }
    }
    final class Peer {
        let fd: Int32
        private var closed = false
        init(_ path: String) throws {
            guard let fd = EventSender.connectedSocket(path: path) else { throw Failure(description: "connect failed") }
            self.fd = fd
        }
        init(fd: Int32) { self.fd = fd }
        deinit { finish() }
        func finish() { if !closed { closed = true; close(fd) } }
        @discardableResult func send(_ data: Data) -> Bool { EventSender.writeAll(data, fd: fd) }
        func receive(timeout: TimeInterval = 1) -> Data? {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: 1024)
            let n = read(fd, &bytes, bytes.count)
            if n < 0 { return errno == ECONNRESET ? Data() : nil }
            return Data(bytes.prefix(n))
        }
    }
    static func path() -> String { "/tmp/ap-r11-" + UUID().uuidString + ".sock" }
    static func event(_ id: String, approval: String? = nil) -> AgentEvent {
        AgentEvent(sessionId: id, agentKind: .codex, eventName: "working",
                   approvalRequestId: approval, timestamp: Date(timeIntervalSince1970: 123))
    }
    static func line(_ id: String, approval: String? = nil) throws -> Data { try EventSender.encodeLine(event(id, approval: approval)) }
    static func until(_ body: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(2)
        while !body() { if Date() >= end { return false }; Thread.sleep(forTimeInterval: 0.005) }
        return true
    }
    static func pair() throws -> (Peer, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw Failure(description: "socketpair failed") }
        return (Peer(fd: fds[0]), fds[1])
    }

    static func framing() throws -> Int {
        let check = Checks(), events = Events(), p = path()
        let server = EventSocketServer(path: p)
        defer { server.stop() }
        try server.start { events.append($0) }
        let stalled = try Peer(p)
        stalled.send(Data("{".utf8))
        let normal = try Peer(p)
        normal.send(try line("without-eof"))
        try check.expect(events.wait(1), "incomplete peer blocked another connection / complete frame waited for EOF")
        try check.expect(events.all == [event("without-eof")], "event metadata changed")
        let wire = try line("split")
        normal.send(wire.prefix(wire.count / 2))
        Thread.sleep(forTimeInterval: 0.03)
        try check.expect(events.all.count == 1, "partial frame delivered early")
        normal.send(wire.suffix(wire.count - wire.count / 2))
        try check.expect(events.wait(2), "fragmented frame not delivered")
        var batch = Data("\ninvalid-json\n".utf8)
        for i in 0..<80 { batch.append(try line("multi-\(i)")) }
        normal.send(batch)
        try check.expect(events.wait(82), "multiline stream lost events")
        try check.expect(events.all.dropFirst(2).map(\.sessionId) == (0..<80).map { "multi-\($0)" }, "per-connection event order changed")
        let eof = try Peer(p)
        eof.send(try EventCoding.encoder.encode(event("eof-tail")))
        eof.finish()
        try check.expect(events.wait(83) && events.all.last?.sessionId == "eof-tail", "EOF tail compatibility lost")
        var large = event("large-valid")
        large.message = String(repeating: "x", count: 200_000)
        normal.send(try EventSender.encodeLine(large))
        try check.expect(events.wait(84) && events.all.last == large, "frame spanning read budgets was lost")
        server.stop()
        try check.expect(stalled.receive()?.isEmpty == true && normal.receive()?.isEmpty == true, "stop did not close reading peers")
        try check.expect(server.activeConnectionCount == 0, "stop leaked connection slots")
        return check.count
    }

    static func limits() throws -> Int {
        let check = Checks(), events = Events(), p = path()
        let wire = try line("boundary")
        let server = EventSocketServer(path: p, limits: .init(maxConnections: 2, maxFrameBytes: wire.count - 1, frameTimeout: 2))
        defer { server.stop() }
        try server.start { events.append($0) }
        let exact = try Peer(p)
        exact.send(wire)
        try check.expect(events.wait(1), "exact frame limit rejected")
        let excessive = try Peer(p)
        excessive.send(Data(repeating: 65, count: wire.count))
        try check.expect(excessive.receive()?.isEmpty == true, "oversized unterminated frame not closed")
        try check.expect(until { server.activeConnectionCount == 1 }, "oversized frame did not release capacity")
        let excessiveLine = try Peer(p)
        excessiveLine.send(Data(repeating: 65, count: wire.count) + Data([10]))
        try check.expect(excessiveLine.receive()?.isEmpty == true, "oversized newline frame not closed")
        try check.expect(until { server.activeConnectionCount == 1 }, "newline rejection did not release capacity")
        let two = try Peer(p)
        two.send(wire)
        try check.expect(events.wait(2), "capacity not reusable after rejection")
        let excessConnection = try Peer(p)
        try check.expect(excessConnection.receive()?.isEmpty == true, "connection bound not enforced")
        try check.expect(server.activeConnectionCount == 2, "rejected connection consumed a slot")
        exact.finish()
        try check.expect(until { server.activeConnectionCount == 1 }, "EOF did not release slot")
        let reuse = try Peer(p)
        var many = Data()
        for _ in 0..<10 { many.append(wire) }
        reuse.send(many)
        try check.expect(events.wait(12), "frame bound incorrectly applied to whole stream")
        try check.expect(events.all.count == 12, "invalid frame emitted an event")
        return check.count
    }

    static func deadlines() throws -> Int {
        let check = Checks(), events = Events(), p = path()
        let server = EventSocketServer(path: p, limits: .init(frameTimeout: 0.4))
        defer { server.stop() }
        try server.start { events.append($0) }
        let slow = try Peer(p)
        slow.send(Data("{".utf8))
        for _ in 0..<3 { Thread.sleep(forTimeInterval: 0.1); slow.send(Data(" ".utf8)) }
        try check.expect(slow.receive(timeout: 0.25)?.isEmpty == true, "byte trickle extended absolute frame deadline")
        try check.expect(events.all.isEmpty, "timeout decoded an incomplete frame")
        let idle = try Peer(p)
        try check.expect(idle.receive(timeout: 0.8)?.isEmpty == true, "idle connection did not expire")
        let active = try Peer(p)
        for i in 0..<4 {
            active.send(try line("active-\(i)"))
            try check.expect(events.wait(i + 1), "valid frame did not renew next-frame deadline")
            Thread.sleep(forTimeInterval: 0.15)
        }
        return check.count
    }

    static func lifecycle() throws -> Int {
        let check = Checks(), events = Events(), p = path()
        let server = EventSocketServer(path: p)
        try server.start { events.append($0) }
        let unstarted = EventSocketServer(path: p)
        unstarted.stop()
        try check.expect(FileManager.default.fileExists(atPath: p), "unstarted server removed another listener path")
        do { try server.start { _ in }; throw Failure(description: "second start was accepted") }
        catch SocketError.alreadyRunning { }
        for turn in 0..<12 {
            let peer = try Peer(p)
            peer.send(try line("restart-\(turn)"))
            try check.expect(events.wait(turn + 1), "restart failed to accept events")
            server.stop()
            try check.expect(peer.receive()?.isEmpty == true && server.activeConnectionCount == 0, "stop did not finish descriptor cleanup")
            try check.expect(!FileManager.default.fileExists(atPath: p), "socket path survived stop")
            try server.start { events.append($0) }
        }
        let writers = DispatchGroup()
        for i in 0..<24 {
            writers.enter()
            DispatchQueue.global().async {
                defer { writers.leave() }
                if let peer = try? Peer(p), let data = try? line("parallel-\(i)") { peer.send(data) }
            }
        }
        try check.expect(writers.wait(timeout: .now() + 3) == .success && events.wait(36), "parallel send lost events")
        try check.expect(Set(events.all.suffix(24).map(\.sessionId)).count == 24, "parallel events duplicated")
        server.stop(); server.stop()
        try check.expect(server.activeConnectionCount == 0, "repeated stop was not idempotent")
        let transitions = DispatchGroup(), failures = Events()
        for i in 0..<30 {
            transitions.enter()
            DispatchQueue.global().async {
                defer { transitions.leave() }
                if i % 3 != 0 { server.stop(); return }
                do { try server.start { _ in } }
                catch SocketError.alreadyRunning { }
                catch { failures.append(event("unexpected-start-error")) }
            }
        }
        try check.expect(transitions.wait(timeout: .now() + 5) == .success, "concurrent start/stop deadlocked")
        server.stop()
        try check.expect(failures.all.isEmpty && server.activeConnectionCount == 0, "concurrent lifecycle corrupted listener state")
        let didStop = DispatchSemaphore(value: 0)
        let reentrantPath = path()
        let callbackServer = EventSocketServer(path: reentrantPath)
        try callbackServer.start { [weak callbackServer] _ in callbackServer?.stop(); didStop.signal() }
        let callbackPeer = try Peer(reentrantPath)
        callbackPeer.send(try line("stop-in-callback"))
        try check.expect(didStop.wait(timeout: .now() + 2) == .success, "stop in callback deadlocked")
        callbackServer.stop()
        let lifetimePath = path()
        var temporary: EventSocketServer? = EventSocketServer(path: lifetimePath)
        let weakServer = WeakServer(temporary)
        try temporary?.start { _ in }
        let blocked = try Peer(lifetimePath)
        blocked.send(Data("{".utf8))
        temporary = nil
        try check.expect(until { weakServer.value == nil }, "read sources retain server forever")
        try check.expect(blocked.receive()?.isEmpty == true, "deinit leaked active descriptor")
        return check.count
    }

    static func approvals() throws -> Int {
        let check = Checks(), events = Events(), p = path()
        let registry = PendingApprovalRegistry()
        let server = EventSocketServer(path: p, limits: .init(maxConnections: 2, frameTimeout: 0.1), approvals: registry)
        defer { server.stop() }
        try server.start { events.append($0) }
        for (index, decision) in [ApprovalDecision.allow, .deny, .ask].enumerated() {
            let peer = try Peer(p), id = UUID().uuidString
            peer.send(try line(id, approval: id))
            try check.expect(events.wait(index + 1), "approval frame not delivered")
            Thread.sleep(forTimeInterval: 0.15)
            try check.expect(registry.resolve(requestId: id, decision: decision), "read deadline closed approval connection")
            try check.expect(peer.receive() == Data("{\"decision\":\"\(decision.rawValue)\"}\n".utf8), "approval reply changed")
            try check.expect(!registry.resolve(requestId: id, decision: decision), "approval resolved twice")
            try check.expect(until { server.activeConnectionCount == 0 }, "approval slot leaked")
        }
        let a = try Peer(p), b = try Peer(p)
        a.send(try line("pending-A", approval: "pending-A"))
        b.send(try line("pending-B", approval: "pending-B"))
        try check.expect(until { events.all.count == 5 }, "parallel approvals not delivered")
        let rejected = try Peer(p)
        try check.expect(rejected.receive()?.isEmpty == true, "approval descriptors escaped connection bound")
        server.stop()
        let ask = Data("{\"decision\":\"ask\"}\n".utf8)
        try check.expect(a.receive() == ask && b.receive() == ask, "stop must return pending approvals to native ask")
        try check.expect(server.activeConnectionCount == 0, "stop leaked approval descriptors")
        let (oldPeer, oldFD) = try pair()
        let token = registry.register(requestId: "reused", fd: oldFD, timeout: 0.15)
        let (newPeer, newFD) = try pair()
        registry.register(requestId: "reused", fd: newFD, timeout: 1)
        try check.expect(oldPeer.receive() == ask, "duplicate request leaked old fd")
        registry.cancel(token: token)
        Thread.sleep(forTimeInterval: 0.25)
        try check.expect(registry.resolve(requestId: "reused", decision: .deny), "old token or timeout closed newer registration")
        try check.expect(newPeer.receive() == Data("{\"decision\":\"deny\"}\n".utf8), "new registration reply not delivered")
        let (timeoutPeer, timeoutFD) = try pair()
        registry.register(requestId: "timeout", fd: timeoutFD, timeout: 0.05)
        try check.expect(timeoutPeer.receive() == ask, "daemon approval timeout did not return ask")
        try check.expect(!registry.resolve(requestId: "timeout", decision: .allow), "timed-out registration remained open")
        let roundTripPath = path()
        let roundTrip = EventSocketServer(path: roundTripPath, approvals: registry)
        defer { roundTrip.stop() }
        try roundTrip.start { event in
            if let id = event.approvalRequestId, let decision = ApprovalDecision(rawValue: id) {
                registry.resolve(requestId: id, decision: decision)
            }
        }
        for decision in [ApprovalDecision.allow, .deny, .ask] {
            try check.expect(EventSender.sendAndAwaitReply(event("native-helper", approval: decision.rawValue), socketPath: roundTripPath, timeout: 1) == decision, "EventSender approval round trip failed")
        }
        let gone = try Peer(roundTripPath)
        gone.send(try line("gone", approval: "gone"))
        try check.expect(until { roundTrip.activeConnectionCount == 1 }, "disconnected approval not registered")
        gone.finish()
        try check.expect(until { registry.resolve(requestId: "gone", decision: .allow) }, "closed peer could not be retired")
        try check.expect(until { roundTrip.activeConnectionCount == 0 }, "closed approval peer leaked slot")
        let (orphan, orphanFD) = try pair()
        var shortLived: PendingApprovalRegistry? = PendingApprovalRegistry()
        shortLived?.register(requestId: "owner-lifetime", fd: orphanFD, timeout: 30)
        shortLived = nil
        try check.expect(orphan.receive()?.isEmpty == true, "registry deinit leaked descriptor")
        let (closedPeer, closedFD) = try pair()
        closedPeer.finish()
        try check.expect(!EventSender.writeAll(Data("reply\n".utf8), fd: closedFD), "closed peer write must fail without SIGPIPE")
        close(closedFD)
        return check.count
    }

    static func runAll() throws -> Int {
        var total = 0
        for (name, run) in [("framing", framing), ("limits", limits), ("deadlines", deadlines), ("lifecycle", lifecycle), ("approvals", approvals)] {
            print("CHECK: socket \(name)"); fflush(stdout)
            let n = try run(); total += n
            print("PASS: socket \(name), \(n) checks"); fflush(stdout)
        }
        return total
    }
}
