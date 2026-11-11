import Foundation
import Darwin

/// Detect the executable the local CLI will use; never invoke a login shell.
public struct OpencodeVersion: Equatable, Sendable {
    public enum Generation: Int, Sendable { case v1 = 1, v2 = 2 }
    public let version: String
    public let generation: Generation
    public let executable: String

    /// Navigation targets this public API contract; older V2 keeps observing.
    public var supportsTUINavigation: Bool {
        let parts = version.split(separator: ".").prefix(3).compactMap { Int($0) }
        return generation == .v2 && parts.count == 3 && (parts[1] > 2 || parts[1] == 2 && parts[2] >= 2)
    }

    public init(output: String, executable: String) throws {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^(?:opencode[ \\t]+v?)?([12])\\.([0-9]+)\\.([0-9]+)(?:[-+][A-Za-z0-9.-]+)?$"
        guard let match = text.range(of: pattern, options: .regularExpression) else {
            throw IntegrationSetupError.manualReview("无法识别或暂不支持该 OpenCode 版本。请使用 OpenCode V1（≥1.18.34）或 V2（≥2.0.29）后重试。")
        }
        let value = String(text[match]).replacingOccurrences(of: "^opencode[ \\t]+v?", with: "", options: .regularExpression)
        let parts = value.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" }).prefix(3).compactMap { Int($0) }
        guard parts.count == 3, let generation = Generation(rawValue: parts[0]),
              generation == .v1 ? (parts[1] > 18 || parts[1] == 18 && parts[2] >= 34) : (parts[1] > 0 || parts[2] >= 29) else {
            throw IntegrationSetupError.manualReview("该 OpenCode 版本过旧。接入需要 V1 ≥1.18.34 或 V2 ≥2.0.29。")
        }
        self.version = value; self.generation = generation; self.executable = executable
    }

    public static func detect(home: String, environment: [String: String]) throws -> Self {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.opencode/bin", home + "/.local/bin"]
        var seen = Set<String>()
        guard let executable = paths.filter({ $0.hasPrefix("/") }).map({ $0 + "/opencode" })
            .first(where: { seen.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw IntegrationSetupError.manualReview("未找到本机 OpenCode CLI，无法选择 V1/V2 插件。请先安装 OpenCode，再 Refresh。")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("agentpet-oc-version-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw IntegrationSetupError.manualReview("无法创建 OpenCode 版本检测的临时文件。")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = ["--version"]
        // Keep the real HOME. Version discovery must not load or rewrite a profile.
        task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        task.standardOutput = handle; task.standardError = FileHandle.nullDevice; task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { throw IntegrationSetupError.manualReview("无法运行 OpenCode --version，请检查本机 CLI。") }
        let deadline = Date().addingTimeInterval(2)
        while task.isRunning && Date() < deadline { usleep(10_000) }
        if task.isRunning {
            task.terminate(); usleep(50_000)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            throw IntegrationSetupError.manualReview("OpenCode 版本检测超时，未安装接入。")
        }
        guard task.terminationStatus == 0, let bytes = try? Data(contentsOf: output), bytes.count <= 4096,
              let text = String(data: bytes, encoding: .utf8) else {
            throw IntegrationSetupError.manualReview("OpenCode --version 执行失败，未安装接入。")
        }
        return try Self(output: text, executable: executable)
    }
}
