import Foundation
import Darwin

// R0 characterization and R1 regression cases. All resources are temporary;
// no application, native agent, user configuration, or real history is used.
@main
struct ReliabilityProbe {
    static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { target in
                for (index, byte) in bytes.enumerated() { target[index] = CChar(bitPattern: byte) }
                target[bytes.count] = 0
            }
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(status == 0)
        return fd
    }

    static func commands(_ settings: [String: Any]) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        let root = URL(fileURLWithPath: "/tmp/ap-audit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("events.sock").path
        let server = EventSocketServer(path: path)
        let received = DispatchSemaphore(value: 0)
        try server.start { event in
            if event.sessionId == "audit-only-event" { received.signal() }
        }
        let blocker = connect(path)
        let fragment = Data("{".utf8)
        _ = fragment.withUnsafeBytes { write(blocker, $0.baseAddress, $0.count) }
        Thread.sleep(forTimeInterval: 0.15)
        let normal = connect(path)
        var data = try EventCoding.encoder.encode(AgentEvent(sessionId: "audit-only-event", agentKind: .codex, eventName: "Stop", timestamp: Date()))
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(normal, $0.baseAddress, $0.count) }
        close(normal)
        let deliveredWhileBlocked = received.wait(timeout: .now() + 0.6) == .success
        close(blocker)
        let deliveredAfterRelease = received.wait(timeout: .now() + 2) == .success
        server.stop()

        let foreign = "/tmp/third-party-agent-audit-hook"
        let settings: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "*", "hooks": [
            ["type": "command", "command": "/tmp/agentpet hook --agent claude"],
            ["type": "command", "command": foreign]
        ]]]]]
        let installed = HookInstaller.install(into: settings, command: "/tmp/agentpet-local hook --agent claude", events: ["PreToolUse"])
        let removed = HookInstaller.uninstall(from: settings, events: ["PreToolUse"])

        let history = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let historyFile = history.appendingPathComponent(formatter.string(from: now) + ".json")
        let original = Data("[{\"sessionId\":\"audit-prior-record\",\"truncated\":".utf8)
        try original.write(to: historyFile)
        let archive = SessionArchiveStore(baseURL: history)
        let session = AgentSession(id: "audit-new-record", agentKind: .codex, state: .done, source: .hook, updatedAt: now)
        archive.archive(session, startedAt: now, endedAt: now)
        let after = try Data(contentsOf: historyFile)

        let args = Array(CommandLine.arguments.dropFirst())
        let mode = args.first ?? "--baseline"
        guard mode == "--baseline" || mode == "--regression" else {
            fputs("Usage: checks [--baseline|--regression] [socket|hooks|history]\n", stderr); exit(2)
        }
        let selected = args.count > 1 ? [args[1]] : ["socket", "hooks", "history"]
        let fixed: [String: Bool] = [
            "socket": deliveredWhileBlocked,
            "hooks": commands(installed).contains(foreign) && commands(removed).contains(foreign),
            "history": original == after
        ]
        guard selected.allSatisfy({ fixed[$0] != nil }) else { exit(2) }
        let validBaseline = (deliveredAfterRelease || deliveredWhileBlocked) &&
            selected.allSatisfy { fixed[$0] == false }
        let success = mode == "--baseline" ? validBaseline : selected.allSatisfy { fixed[$0] == true }
        let result: [String: Any] = [
            "mode": mode, "selected": selected, "expectation_met": success,
            "desired_behavior": fixed,
            "known_failures": selected.filter { fixed[$0] == false },
            "socket_delivered_after_blocker_closed": deliveredAfterRelease,
            "classification": mode == "--baseline" ? "known defects reproduced; not regression success" : "desired regression behavior",
            "isolation": "temporary socket, in-memory hook config, synthetic temporary history"
        ]
        let report = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: report, as: UTF8.self))
        exit(success ? 0 : 1)
    }
}
