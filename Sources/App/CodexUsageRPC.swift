import Foundation
import Darwin

/// Short-lived official stdio connection. No thread/turn/login methods are sent.
/// Runs on the usage probe's utility task, never on the UI thread.
enum CodexUsageRPC {
    static func executable() -> URL? {
        for path in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func read(executable: URL, arguments: [String] = ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"],
                     timeout: TimeInterval = 8) -> [String: Any]? {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            data.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: data); return true }
            catch { return false }
        }
        guard send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "agentpet_quota", "version": "1"]]]) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Data(), total = 0, requested = false
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while Date() < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; return nil }
            guard ready > 0 else { continue }
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { return nil }
            total += count
            guard total <= 2_097_152 else { return nil }
            pending.append(contentsOf: bytes.prefix(count))
            while let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                guard line.count <= 262_144 else { return nil }
                let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                pending.removeSubrange(...end)
                guard let message else { continue }
                if message["id"] as? Int == 0 && !requested {
                    guard message["error"] == nil, message["result"] != nil,
                          send(["method": "initialized", "params": [:]]),
                          send(["id": 1, "method": "account/rateLimits/read"]) else { return nil }
                    requested = true
                } else if message["id"] as? Int == 1 && requested {
                    return message["error"] == nil ? message["result"] as? [String: Any] : nil
                }
            }
            guard pending.count <= 262_144 else { return nil }
        }
        return nil
    }
}
