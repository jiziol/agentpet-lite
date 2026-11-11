import Foundation
import Darwin

public struct LocalAgentConnectionResult: Equatable, Sendable {
    public enum Status: String, Sendable { case connected, failed, timedOut, cancelled, unsupported }
    public let status: Status
    /// A localization key, never client stderr or credential-bearing output.
    public let message: String
    /// Only protocol identity and correlated request ID; never a transcript.
    public let evidence: String
}

public final class LocalAgentTestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// No prompts, session creation, hook calls, login, real profile, or shared service.
/// Each invocation owns a temporary configuration root and a bounded process group.
public struct LocalAgentConnectionTest: Sendable {
    public var home: String
    public var environment: [String: String]
    public var executableOverrides: [AgentKind: String]
    public var timeout: TimeInterval

    public init(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
                executableOverrides: [AgentKind: String] = [:], timeout: TimeInterval = 12) {
        self.home = home; self.environment = environment
        self.executableOverrides = executableOverrides; self.timeout = timeout
    }

    public func run(_ kind: AgentKind, requestID: String, cancellation: LocalAgentTestCancellation) -> LocalAgentConnectionResult {
        func result(_ status: LocalAgentConnectionResult.Status, _ message: String, _ evidence: String = "") -> LocalAgentConnectionResult {
            .init(status: status, message: message, evidence: evidence)
        }
        if kind == .antigravity { return result(.unsupported, "connection.agyUnsupported") }
        if kind == .dsh { return result(.unsupported, "dsh.test.desktopRequired") }
        guard [.codex, .opencode, .pi].contains(kind) else { return result(.unsupported, "connection.unmaintained") }
        let command = kind == .antigravity ? "agy" : kind.rawValue
        guard let executable = executableOverrides[kind] ?? find(command) else { return result(.failed, "connection.missingCLI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ap-connect-" + UUID().uuidString)
        let deadline = Date().addingTimeInterval(timeout)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let env = try isolatedEnvironment(root)
            var args: [String]
            var request: [String: Any]?
            var protocolName: String
            var finalInput: [String: Any]?
            var version = ""
            switch kind {
            case .codex:
                args = ["app-server", "--listen", "stdio://"]
                request = ["id": requestID, "method": "initialize", "params": ["clientInfo": ["name": "agentpet_connection_test", "version": "1"]]]
                finalInput = ["method": "initialized", "params": [:]]
                protocolName = "app-server initialize"
            case .pi:
                args = ["--mode", "rpc", "--no-session", "--offline", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files", "--no-tools"]
                request = ["id": requestID, "type": "get_state"]
                protocolName = "RPC get_state"
            case .opencode:
                let bytes = try ConnectionTestProcess.exchange(executable, ["--version"], env, root, deadline, cancellation)
                let detected = try OpencodeVersion(output: String(decoding: bytes, as: UTF8.self), executable: executable)
                version = detected.version
                if detected.generation == .v2 {
                    args = ["api", "--standalone", "GET", "/api/info"]
                    request = nil; protocolName = "private HTTP GET /api/info"
                } else {
                    args = ["acp"]; request = Self.initialize(requestID); protocolName = "ACP initialize"
                }
            default:
                return result(.unsupported, "connection.unmaintained")
            }
            let response = try ConnectionTestProcess.exchange(executable, args, env, root, deadline, cancellation,
                request: request, finalInput: finalInput, accept: { object in
                    if kind == .opencode && request == nil {
                        return object["version"] as? String == version && (object["pid"] as? Int ?? 0) > 0
                    }
                    guard object["id"] as? String == requestID else { return false }
                    if object["error"] != nil || object["success"] as? Bool == false {
                        let text = String(describing: object["error"] ?? "").lowercased()
                        throw ConnectionTestProcess.Failure(text.contains("auth") || text.contains("401") || text.contains("403") ? "connection.authentication" : "connection.rejected")
                    }
                    if kind == .codex {
                        return (object["result"] as? [String: Any])?["userAgent"] as? String != nil
                    }
                    if kind == .pi {
                        guard object["type"] as? String == "response", object["command"] as? String == "get_state",
                              object["success"] as? Bool == true, let data = object["data"] as? [String: Any] else { return false }
                        return data["isStreaming"] as? Bool == false && data["messageCount"] as? Int == 0
                    }
                    guard let data = object["result"] as? [String: Any] else { return false }
                    return data["protocolVersion"] as? Int == 1 && (data["agentInfo"] as? [String: Any])?["name"] as? String != nil
                })
            guard !response.isEmpty else { throw ConnectionTestProcess.Failure("connection.invalidResponse") }
            if cancellation.isCancelled { return result(.cancelled, "connection.cancelled") }
            let acknowledgement = kind == .codex ? "initialize.result.userAgent ✓; initialized →" : kind == .pi ? "get_state.success=true; isStreaming=false; messageCount=0" : kind == .opencode && request == nil ? "GET /api/info: version=\(version); pid > 0" : "initialize.result.protocolVersion=1; agentInfo.name ✓"
            return result(.connected, "connection.connected", "\(executable)\n\(protocolName)\(version.isEmpty ? "" : " · " + version)\n\(acknowledgement)\nID: \(requestID)")
        } catch let error as ConnectionTestProcess.Failure {
            return result(error.key == "connection.timeout" ? .timedOut : error.key == "connection.cancelled" ? .cancelled : .failed, error.key)
        } catch is IntegrationSetupError {
            return result(.failed, "connection.versionUnsupported")
        } catch {
            return result(.failed, "connection.startFailed")
        }
    }

    private func find(_ command: String) -> String? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.opencode/bin"]
        return paths.filter { $0.hasPrefix("/") }.map { $0 + "/" + command }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func initialize(_ id: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "initialize", "params": ["protocolVersion": 1, "clientCapabilities": [:], "clientInfo": ["name": "agentpet_connection_test", "version": "1"]]]
    }

    private func isolatedEnvironment(_ root: URL) throws -> [String: String] {
        // Do not inherit provider keys, proxy credentials, runtime tokens or real config overrides.
        var env = environment.filter { ["PATH", "HOME", "USER", "LOGNAME", "LANG"].contains($0.key) }
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        for (key, suffix) in ["CFFIXED_USER_HOME": "", "CODEX_HOME": "/.codex", "XDG_CONFIG_HOME": "/.config", "XDG_DATA_HOME": "/.local/share", "XDG_CACHE_HOME": "/.cache", "XDG_STATE_HOME": "/.state", "PI_CODING_AGENT_DIR": "/.pi", "DSH_HOME": "/.dsh", "OPENCODE_TEST_HOME": "", "TMPDIR": "/tmp/"] {
            env[key] = root.path + suffix
        }
        env["PI_OFFLINE"] = "1"; env["OPENCODE_DISABLE_MODELS_FETCH"] = "true"
        env["OPENCODE_DISABLE_PROJECT_CONFIG"] = "true"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try Data("[analytics]\nenabled = false\n".utf8).write(to: root.appendingPathComponent(".codex/config.toml"))
        return env
    }
}

/// Process groups use the same bounded shutdown approach as the existing DSH installer.
/// Protocol stdout and diagnostics stay separate; neither raw stream reaches the UI.
enum ConnectionTestProcess {
    struct Failure: Error { let key: String; init(_ key: String) { self.key = key } }

    static func exchange(_ executable: String, _ arguments: [String], _ environment: [String: String], _ directory: URL,
                         _ deadline: Date, _ cancellation: LocalAgentTestCancellation,
                         request: [String: Any]? = nil, finalInput: [String: Any]? = nil,
                         accept: (([String: Any]) throws -> Bool)? = nil) throws -> Data {
        if cancellation.isCancelled { throw Failure("connection.cancelled") }
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { throw Failure("connection.startFailed") }
        defer { input.filter { $0 >= 0 }.forEach { close($0) } }
        guard pipe(&output) == 0 else { throw Failure("connection.startFailed") }
        defer { output.filter { $0 >= 0 }.forEach { close($0) } }
        guard pipe(&errors) == 0 else { throw Failure("connection.startFailed") }
        defer { errors.filter { $0 >= 0 }.forEach { close($0) } }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for (from, to) in [(input[0], STDIN_FILENO), (output[1], STDOUT_FILENO), (errors[1], STDERR_FILENO)] {
            posix_spawn_file_actions_adddup2(&actions, from, to)
        }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        for fd in input + output + errors { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, argv, envp) == 0 else { throw Failure("connection.startFailed") }
        close(input[0]); input[0] = -1; close(output[1]); output[1] = -1; close(errors[1]); errors[1] = -1
        var reaped = false, status: Int32 = 0
        defer {
            if input[1] >= 0 { close(input[1]); input[1] = -1 }
            // Give EOF a chance to dispose the interface, then terminate only this group.
            let grace = Date().addingTimeInterval(0.25)
            while !reaped && Date() < grace {
                reaped = waitpid(pid, &status, WNOHANG) == pid
                if !reaped { usleep(10_000) }
            }
            kill(-pid, SIGTERM)
            if !reaped { usleep(50_000) }
            kill(-pid, SIGKILL)
            if !reaped { _ = waitpid(pid, &status, 0) }
        }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            let sent = data.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }
            guard sent == data.count else { throw Failure("connection.unreachable") }
        }
        if let request { try send(request) }
        else { close(input[1]); input[1] = -1 }
        for fd in [output[0], errors[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var captured = Data(), pending = Data(), diagnostics = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            if cancellation.isCancelled { throw Failure("connection.cancelled") }
            if Date() >= deadline { throw Failure("connection.timeout") }
            for fd in [output[0], errors[0]] {
                while true {
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count <= 0 { break }
                    if fd == errors[0] { diagnostics.append(contentsOf: bytes.prefix(count)) }
                    else { captured.append(contentsOf: bytes.prefix(count)); pending.append(contentsOf: bytes.prefix(count)) }
                    guard captured.count + diagnostics.count <= 262_144 else { throw Failure("connection.outputLimit") }
                }
            }
            if let accept {
                while let end = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: end); pending.removeSubrange(...end)
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if try accept(object) {
                        if let finalInput { try send(finalInput) }
                        return Data(line)
                    }
                }
            }
            if reaped {
                if accept == nil && status == 0 { return captured }
                let text = String(decoding: diagnostics, as: UTF8.self).lowercased()
                throw Failure(text.contains("unauthorized") || text.contains("auth_required") || text.contains("401") || text.contains("403") ? "connection.authentication" : "connection.unreachable")
            }
            if waitpid(pid, &status, WNOHANG) == pid { reaped = true; continue }
            usleep(10_000)
        }
    }
}
