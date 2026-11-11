import Foundation
import Darwin

/// Bounded Unix navigation exchange. Call off the main actor; never launches
/// a terminal or sends answers, approval decisions, or arbitrary commands.
public enum DSHNavigation {
    public struct Receipt: Sendable {
        public let peerPID: pid_t
        public let clientID: String
        public let generation: String
    }
    private struct Request: Encodable {
        let schema = 1
        let operation = "navigate"
        let requestID: String
        let hostID: String
        let profileID: String
        let nativeSessionID: String
        let verifyOnly: Bool
    }
    private struct Reply: Decodable {
        let schema: Int
        let requestID: String
        let hostID: String
        let profileID: String
        let nativeSessionID: String
        let clientID: String
        let generation: String
        let ok: Bool
    }

    public static func select(_ target: DSHObservation, timeout: TimeInterval = 3.5, verifyOnly: Bool = false) -> Receipt? {
        guard target.valid, let path = target.navigationSocket else { return nil }
        let request = Request(requestID: UUID().uuidString, hostID: target.hostID,
            profileID: target.profileID, nativeSessionID: target.nativeSessionID, verifyOnly: verifyOnly)
        guard let (reply, peer): (Reply, pid_t) = exchange(path: path, request: request, timeout: timeout),
              reply.schema == 1, reply.ok, reply.requestID == request.requestID,
              reply.hostID == target.hostID, reply.profileID == target.profileID,
              reply.nativeSessionID == target.nativeSessionID,
              DSHObservation.validID(reply.clientID), UUID(uuidString: reply.generation) != nil else { return nil }
        return Receipt(peerPID: peer, clientID: reply.clientID, generation: reply.generation)
    }

    /// Shared bounded transport; callers validate their own versioned envelope and request identity.
    static func exchange<Request: Encodable, Reply: Decodable>(path: String, request: Request,
                                                               timeout: TimeInterval) -> (Reply, pid_t)? {
        guard timeout.isFinite, timeout > 0, timeout <= 4 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard let (fd, peer) = openPeer(path, timeout: timeout) else { return nil }
        defer { close(fd) }
        guard var data = try? JSONEncoder().encode(request) else { return nil }
        data.append(10)
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                guard wait(fd, events: Int16(POLLOUT), deadline: deadline) else { return false }
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, MSG_NOSIGNAL)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written else { return nil }
        var response = Data(); var chunk = [UInt8](repeating: 0, count: 1024)
        while response.count <= 8192 {
            guard wait(fd, events: Int16(POLLIN), deadline: deadline) else { return nil }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return nil }
            response.append(contentsOf: chunk.prefix(count))
            guard response.count <= 8192 else { return nil }
            if let newline = response.firstIndex(of: 10) {
                guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(response[..<newline])) else { return nil }
                return (reply, peer)
            }
        }
        return nil
    }

    /// Connect and verify Unix peer credentials only. No navigation frame,
    /// Client selection, model request or read acknowledgement is sent.
    public static func probePeer(_ target: DSHObservation, timeout: TimeInterval = 0.2) -> pid_t? {
        guard target.valid, let path = target.navigationSocket,
              let (fd, peer) = openPeer(path, timeout: timeout) else { return nil }
        close(fd)
        return peer
    }

    private static func openPeer(_ path: String, timeout: TimeInterval) -> (Int32, pid_t)? {
        guard safeEndpoint(path), timeout.isFinite, timeout > 0, timeout <= 4 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var retained = false
        defer { if !retained { close(fd) } }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on))) == 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: 104) { output in
                for (index, byte) in bytes.enumerated() { output[index] = byte }
                output[bytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS, wait(fd, events: Int16(POLLOUT), deadline: deadline) else { return nil }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return nil }
        }
        var uid: uid_t = 0; var gid: gid_t = 0
        var peer: pid_t = 0
        var size = socklen_t(MemoryLayout.size(ofValue: peer))
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0, peer > 0 else { return nil }
        retained = true
        return (fd, peer)
    }

    static func safeEndpoint(_ path: String) -> Bool {
        guard DSHObservation.validSocket(path), path.hasPrefix("/tmp/agentpet-dsh-\(getuid())/") else { return false }
        let directory = (path as NSString).deletingLastPathComponent
        let root = (directory as NSString).deletingLastPathComponent
        for (item, kind, mode) in [(root, mode_t(S_IFDIR), mode_t(0o700)),
                                  (directory, mode_t(S_IFDIR), mode_t(0o700)),
                                  (path, mode_t(S_IFSOCK), mode_t(0o600))] {
            var info = stat()
            guard lstat(item, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & mode_t(S_IFMT) == kind, info.st_mode & 0o777 == mode else { return false }
        }
        return true
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) -> Bool {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, Int32(ceil(remaining * 1000)))
            if result < 0 && errno == EINTR { continue }
            // POLLHUP may accompany readable data after the server's reply.
            return result > 0 && item.revents & events != 0
        }
    }

    /// Resolve the actual Unix peer's ancestry, not a claimed application PID.
    public static func processAncestors(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []; var current = pid
        for _ in 0..<16 {
            guard current > 1, !result.contains(current) else { break }
            var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
            var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0,
                  size == MemoryLayout<kinfo_proc>.size, info.kp_eproc.e_ucred.cr_uid == getuid() else { return [] }
            result.append(current); current = info.kp_eproc.e_ppid
        }
        return result
    }
}
