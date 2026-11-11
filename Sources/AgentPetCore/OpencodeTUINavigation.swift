import Foundation
import Darwin

/// Session selection and terminal identity are one receipt. No V2 terminal
/// fields are taken from the server observer's inherited environment.
public enum OpencodeTUINavigation {
    public enum Result: Sendable {
        case selected(TerminalInfo.Captured)
        case unsupported, unavailable, ambiguous, failed
    }
    public struct Endpoint: Codable, Sendable {
        public let schema: Int
        public let version: String
        public let pid: Int32
        public let instance: String
        public let nonce: String
        public let socket: String
        public let project: String
        public let program: String
        public let tty: String
        public let updatedAt: Double
    }

    public static func select(_ session: AgentSession, base: String = AgentPetPaths.baseDir,
                              legacySelection: (AgentSession) -> Bool = { OpencodeNavigation.select(session: $0) }) -> Result {
        if session.opencodeNavigationSocket != nil, legacySelection(session) {
            return .selected(.init(program: session.terminalProgram, tty: session.terminalTTY, focusURL: session.terminalFocusURL))
        }
        // Persisted V1 socket fields can survive a native-session migration.
        // Only the precise V2 ownership/selection handshake may replace them.
        let result = navigate(session, base: base)
        if case .unsupported = result, session.opencodeNavigationSocket != nil { return .failed }
        return result
    }

    /// Read and validate bounded, private metadata only. The socket handshake
    /// proves the same live instance before any selection can occur.
    public static func endpoints(base: String = AgentPetPaths.baseDir, now: Date = Date(),
                                 live: (Int32) -> Bool = { kill($0, 0) == 0 }) -> [Endpoint] {
        let directory = URL(fileURLWithPath: base).appendingPathComponent("opencode-tui")
        guard privateNode(base, type: .typeDirectory), privateNode(directory.path, type: .typeDirectory),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              files.count <= 64 else { return [] }
        return files.compactMap { file in
            guard file.lastPathComponent.range(of: "^instance-[0-9]+-[a-f0-9]{16}\\.json$", options: .regularExpression) != nil,
                  privateNode(file.path, type: .typeRegular),
                  let bytes = try? Data(contentsOf: file), bytes.count <= 4096,
                  let row = try? JSONDecoder().decode(Endpoint.self, from: bytes), row.schema == 1,
                  let version = try? OpencodeVersion(output: row.version, executable: ""), version.supportsTUINavigation,
                  row.pid > 1, live(row.pid), row.updatedAt.isFinite,
                  abs(now.timeIntervalSince1970 - row.updatedAt) <= 20,
                  row.instance.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
                  row.nonce.range(of: "^[a-f0-9]{48}$", options: .regularExpression) != nil,
                  ["iTerm.app", "Apple_Terminal"].contains(row.program), TerminalInfo.concreteTTY(row.tty) != nil,
                  row.project.hasPrefix("/"), row.project.utf8.count <= 4096,
                  file.lastPathComponent == "instance-\(row.pid)-\(row.instance.prefix(16)).json",
                  row.socket == URL(fileURLWithPath: base).appendingPathComponent("oc2-\(row.pid)-\(row.instance.prefix(16)).sock").path,
                  row.socket.utf8.count < 104, privateNode(row.socket, type: .typeSocket) else { return nil }
            return row
        }
    }

    public static func navigate(_ session: AgentSession, base: String = AgentPetPaths.baseDir) -> Result {
        guard OpencodeHookPayload.validSessionID(session.id) else { return .failed }
        guard let project = session.project else { return .unavailable }
        // Foundation can shorten /private/tmp back to /tmp on macOS. Match
        // node:fs realpathSync with POSIX realpath on both sides instead.
        guard let path = realpath(project, nil) else { return .unavailable }
        let canonical = String(cString: path)
        free(path)
        let bases = [base] + (base == AgentPetPaths.baseDir ? [AgentPetPaths.migratedLocalDir].compactMap { $0 } : [])
        let rows = bases.flatMap { endpoints(base: $0) }.filter { $0.project == canonical }
        guard !rows.isEmpty else { return .unsupported }
        let deadline = Date().addingTimeInterval(3)
        var owners: [Endpoint] = []
        for row in rows {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.1, let reply = request(row, sessionID: session.id, action: "probe", timeout: min(0.6, remaining)) else { return .failed }
            if reply["owns"] as? Bool == true && reply["ok"] as? Bool == true { owners.append(row) }
        }
        guard owners.count <= 1 else { return .ambiguous }
        guard let target = owners.first else { return .unavailable }
        guard let reply = request(target, sessionID: session.id, action: "select"), reply["ok"] as? Bool == true,
              let route = reply["route"] as? [String: Any], route["type"] as? String == "session",
              route["sessionID"] as? String == session.id else { return .failed }
        return .selected(.init(program: target.program, tty: target.tty, focusURL: nil))
    }

    private static func privateNode(_ path: String, type: FileAttributeType) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path), a[.type] as? FileAttributeType == type,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { return false }
        return type != .typeRegular || (a[.referenceCount] as? NSNumber)?.intValue == 1
    }

    private static func request(_ target: Endpoint, sessionID: String, action: String, timeout seconds: Double = 2) -> [String: Any]? {
        guard let fd = EventSender.connectedSocket(path: target.socket) else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              var bytes = try? JSONSerialization.data(withJSONObject: ["action": action, "sessionID": sessionID,
                "nonce": target.nonce, "instance": target.instance, "expiresAt": Date().timeIntervalSince1970 + max(0.1, seconds - 0.1)]) else { return nil }
        bytes.append(10)
        guard EventSender.writeAll(bytes, fd: fd) else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while !data.contains(10), data.count <= 4096 {
            let size = read(fd, &buffer, buffer.count)
            guard size > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(size))
        }
        guard data.count <= 4096, let end = data.firstIndex(of: 10),
              let reply = try? JSONSerialization.jsonObject(with: data[..<end]) as? [String: Any],
              reply["instance"] as? String == target.instance, reply["nonce"] as? String == target.nonce,
              reply["pid"] as? Int32 == target.pid, reply["sessionID"] as? String == sessionID,
              reply["ok"] is Bool else { return nil }
        return reply
    }
}
