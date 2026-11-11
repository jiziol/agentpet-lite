import Foundation

public enum IntegrationConfiguration: Equatable, Sendable {
    case absent, configured, needsUpdate
}

/// Disk configuration only. Native client loading, Codex trust and runtime
/// connectivity are deliberately not inferred from the presence of a file.
public struct IntegrationInspection: Equatable, Sendable {
    public let configuration: IntegrationConfiguration
    public let clientNotice: String?
    public let installBlockReason: String?
    public init(configuration: IntegrationConfiguration, clientNotice: String?, installBlockReason: String? = nil) {
        self.configuration = configuration; self.clientNotice = clientNotice; self.installBlockReason = installBlockReason
    }
}

public enum IntegrationSetupError: LocalizedError {
    case manualReview(String)
    case recoveryFailed(String)
    public var errorDescription: String? {
        switch self {
        case .manualReview(let message): return message
        case .recoveryFailed(let message): return message
        }
    }
}

/// Explicit Install/Update/Remove operations. Does not run at app startup.
/// Injected locations let acceptance tests use real file IO without editing a
/// developer's working client configuration or trust records.
public struct AgentIntegrationSetup: @unchecked Sendable {
    public let home: String
    public let environment: [String: String]
    public let binary: String
    public let speechSocket: String
    private let detectOpencode: () throws -> OpencodeVersion

    public init(home: String = NSHomeDirectory(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                binary: String, speechSocket: String = AgentPetPaths.socketPath,
                detectOpencode: (() throws -> OpencodeVersion)? = nil) {
        self.home = home; self.environment = environment
        self.binary = binary; self.speechSocket = speechSocket
        self.detectOpencode = detectOpencode ?? { try OpencodeVersion.detect(home: home, environment: environment) }
    }

    public static func command(binary: String, kind: AgentKind) -> String {
        // Single quotes prevent substitution even for $, backticks and quotes
        // in application directory names. This is also understood by ownership.
        "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "' hook --agent " + kind.rawValue
    }

    public func spec(for kind: AgentKind) -> AgentHookSpec? {
        AgentHooks.spec(for: kind, home: home, environment: environment)
    }

    private struct Edit {
        let path: String
        let before: HookFileTransaction.Snapshot
        let after: Data?
    }

    public func inspect(_ kind: AgentKind) throws -> IntegrationInspection {
        guard let spec = spec(for: kind) else { throw HookInstallerError.unrecognizedCommand }
        try checkOtherSources(kind, spec: spec)
        let version = kind == .opencode ? Result { try detectOpencode() } : nil
        let selected = try? version?.get()
        // A missing CLI blocks installation, but must not trap an owned plugin
        // on disk or disable Remove. Still validate every known duplicate path.
        let edits = try plan(spec, install: kind != .opencode || selected != nil, generation: selected?.generation,
                             tuiNavigation: selected?.supportsTUINavigation == true)
        let hasOwned = try containsOwned(spec)
        let changed = edits.contains { $0.before.data != $0.after }
        var block: String?
        if case .failure(let error) = version { block = error.localizedDescription }
        let notice = kind == .opencode
            ? "\(selected.map { "检测到 OpenCode \($0.version)，将使用 V\($0.generation.rawValue) 插件。" } ?? block ?? "未检测到 OpenCode。")\nV1 与 V2 的插件 API 不兼容；版本变化后请 Update 接入。V2 ≥2.2.2 支持 TUI 精确导航（已验证 2.2.2）；更早 V2 仅观察。V1 重开客户端；V2 请在当前任务结束后执行 opencode reload，并重开所用 TUI 以加载导航插件。"
            : try clientNotice(kind, spec: spec)
        return IntegrationInspection(configuration: !hasOwned ? .absent : (kind == .opencode && selected == nil) ? .configured : changed ? .needsUpdate : .configured,
                                      clientNotice: notice, installBlockReason: block)
    }

    public func install(_ kind: AgentKind) throws {
        guard binary.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: binary),
              HookInstaller.isOurs(Self.command(binary: binary, kind: kind)),
              let spec = spec(for: kind) else { throw HookInstallerError.unrecognizedCommand }
        try checkOtherSources(kind, spec: spec)
        // Config and policy are shared with all Codex hooks. Never turn them on
        // implicitly, and never turn them off when removing our registration.
        if kind == .codex, try codexFeatureDisabled(spec) {
            throw IntegrationSetupError.manualReview("Codex 已关闭 hooks。请先在 Codex 配置中启用 hooks，再安装接入；应用不会修改原生信任或管理策略。")
        }
        let version = kind == .opencode ? try detectOpencode() : nil
        try commit(try plan(spec, install: true, generation: version?.generation,
                            tuiNavigation: version?.supportsTUINavigation == true))
        guard try inspect(kind).configuration == .configured else {
            throw IntegrationSetupError.manualReview("接入写入后检查未通过，请刷新并检查配置。")
        }
    }

    public func remove(_ kind: AgentKind) throws {
        guard let spec = spec(for: kind) else { throw HookInstallerError.unrecognizedCommand }
        try checkOtherSources(kind, spec: spec)
        try commit(try plan(spec, install: false))
        guard try !containsOwned(spec) else {
            throw IntegrationSetupError.manualReview("仍检测到 AgentPet 注册，请检查配置。")
        }
    }

    private func clientNotice(_ kind: AgentKind, spec: AgentHookSpec) throws -> String? {
        if kind == .codex {
            if try codexFeatureDisabled(spec) { return "Codex 已关闭 hooks，请先在客户端配置中启用。" }
            return "安装或更新后，在 Codex 的 /hooks 中审阅并信任 AgentPet 项，再重开所用 Codex 客户端。此处不检测原生信任状态。"
        }
        if kind == .antigravity || kind == .opencode || kind == .pi {
            return "安装、更新或移除后，重开所用客户端，使接入变更生效。"
        }
        return "兼容入口，暂不维护或专项验收；变更后请重开客户端。"
    }

    private func codexFeatureDisabled(_ spec: AgentHookSpec) throws -> Bool {
        let path = (spec.settingsPath as NSString).deletingLastPathComponent + "/config.toml"
        let data = try HookFileTransaction.read(path).data
        guard let data else { return false }
        guard let text = String(data: data, encoding: .utf8) else { throw HookInstallerError.unreadableSettings(path: path) }
        return CodexHookConfig.isExplicitlyDisabled(in: text)
    }

    /// Do not claim complete removal when a second known global source contains
    /// AgentPet. Unknown inline TOML or client settings must be reviewed by the
    /// user instead of being rewritten by a JSON/plugin installer.
    private func checkOtherSources(_ kind: AgentKind, spec: AgentHookSpec) throws {
        if kind == .codex, let custom = environment["CODEX_HOME"], !custom.isEmpty, !custom.hasPrefix("/") {
            throw IntegrationSetupError.manualReview("CODEX_HOME 必须为绝对路径，请先确认 CLI 与应用使用相同配置目录。")
        }
        if kind == .opencode {
            if let custom = environment["OPENCODE_CONFIG_DIR"], !custom.isEmpty {
                throw IntegrationSetupError.manualReview("检测到 OPENCODE_CONFIG_DIR 自定义目录。当前按钮仅管理标准全局目录，请人工确认接入位置。")
            }
            if environment["OPENCODE_CONFIG_CONTENT"]?.localizedCaseInsensitiveContains("agentpet") == true {
                throw IntegrationSetupError.manualReview("OPENCODE_CONFIG_CONTENT 中存在 AgentPet 引用，请先人工确认，避免重复接入。")
            }
        }
        let candidates: [String]
        switch kind {
        case .codex: candidates = [(spec.settingsPath as NSString).deletingLastPathComponent + "/config.toml"]
        case .antigravity: candidates = [home + "/.gemini/antigravity-cli/settings.json"]
        case .opencode:
            let root = ((spec.settingsPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            candidates = ["config.json", "opencode.json", "opencode.jsonc"].map { root + "/" + $0 }
                + [environment["OPENCODE_CONFIG"]].compactMap { $0 }
        default: candidates = []
        }
        for path in candidates {
            guard let data = try HookFileTransaction.read(path).data else { continue }
            guard let text = String(data: data, encoding: .utf8) else { throw HookInstallerError.unreadableSettings(path: path) }
            if kind == .codex {
                if CodexHookConfig.hasAgentPetHookReference(in: text) {
                    throw IntegrationSetupError.manualReview("Codex 的 hooks／notify 配置中存在 AgentPet 引用：\(path)。请先确认是否为额外接入，避免重复上报或移除不完整。")
                }
                continue
            }
            let active = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
            if active.localizedCaseInsensitiveContains("agentpet"), kind == .opencode || active.contains("hook") {
                throw IntegrationSetupError.manualReview("另一个全局配置中存在 AgentPet 接入：\(path)。请先人工确认，避免重复上报或移除不完整。")
            }
        }
    }

    private func pluginPaths(_ spec: AgentHookSpec) -> [String] {
        guard spec.style == .opencodePlugin else { return [spec.settingsPath] }
        let root = ((spec.settingsPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        // v1 loads both spellings. Examine known AgentPet names only, never
        // enumerate/delete unrelated plugins or project directories.
        return [spec.settingsPath] + ["plugin", "plugins"].flatMap { dir in
            ["js", "ts"].map { root + "/" + dir + "/agentpet." + $0 }
        }.filter { $0 != spec.settingsPath } + tuiPaths(spec)
    }

    private func tuiPaths(_ spec: AgentHookSpec) -> [String] {
        let root = ((spec.settingsPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return ["index.js", "tui.js", "package.json"].map { root + "/plugins/agentpet-lite/" + $0 }
    }

    private func ownsPlugin(_ text: String, path: String, spec: AgentHookSpec) -> Bool {
        if path == tuiPaths(spec)[1] { return OpencodeTUIPlugin.isOwned(text) }
        if path == tuiPaths(spec)[2] { return text == OpencodeTUIPlugin.manifest }
        return OpencodePlugin.isOwned(text)
    }

    private func checkTUIDirectory(_ spec: AgentHookSpec) throws {
        let directory = (tuiPaths(spec)[0] as NSString).deletingLastPathComponent
        let parent = (directory as NSString).deletingLastPathComponent
        for path in [(parent as NSString).deletingLastPathComponent, parent, directory] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw HookInstallerError.unsafeSettings(path: path) }
        }
        if FileManager.default.fileExists(atPath: directory) {
            let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            guard Set(files).isSubset(of: ["index.js", "tui.js", "package.json", ".agentpet-backups"]) else {
                throw HookInstallerError.foreignPlugin(path: directory)
            }
        }
    }

    private func plan(_ spec: AgentHookSpec, install: Bool, generation: OpencodeVersion.Generation? = nil,
                      tuiNavigation: Bool = false) throws -> [Edit] {
        if spec.style == .opencodePlugin || spec.style == .piExtension {
            if spec.style == .opencodePlugin { try checkTUIDirectory(spec) }
            return try pluginPaths(spec).map { path in
                let before = try HookFileTransaction.read(path)
                if let data = before.data {
                    guard let text = String(data: data, encoding: .utf8),
                          spec.style == .opencodePlugin ? ownsPlugin(text, path: path, spec: spec) : PiPlugin.isOwned(text) else {
                        throw HookInstallerError.foreignPlugin(path: path)
                    }
                }
                let after: Data?
                if spec.style == .opencodePlugin, install, tuiNavigation {
                    let parts = tuiPaths(spec)
                    if path == parts[0] { after = Data(OpencodePlugin.source(binary: binary, speechSocketPath: speechSocket, generation: .v2).utf8) }
                    else if path == parts[1] { after = Data(OpencodeTUIPlugin.source(speechSocketPath: speechSocket).utf8) }
                    else if path == parts[2] { after = Data(OpencodeTUIPlugin.manifest.utf8) }
                    else { after = nil }
                } else {
                    after = install && path == spec.settingsPath
                        ? Data((spec.style == .opencodePlugin ? OpencodePlugin.source(binary: binary, speechSocketPath: speechSocket, generation: generation ?? .v1) : PiPlugin.source(binary: binary)).utf8) : nil
                }
                return Edit(path: path, before: before, after: after)
            }
        }
        guard spec.style == .claudeNested || spec.style == .antigravityNested else { throw HookInstallerError.unrecognizedCommand }
        let before = try HookFileTransaction.read(spec.settingsPath)
        let old = try decode(before.data, path: spec.settingsPath)
        let cleaned = try clean(old, spec: spec)
        let new: [String: Any]
        if install {
            try HookInstaller.validateRetiredSettings(cleaned, spec: spec)
            if spec.style == .antigravityNested,
               let group = cleaned[HookInstaller.antigravityGroup] as? [String: Any], group["enabled"] as? Bool == false {
                throw IntegrationSetupError.manualReview("agy 的 agentpet 组已禁用，请先人工确认该组配置。")
            }
            let command = Self.command(binary: binary, kind: spec.kind)
            new = spec.style == .claudeNested ? HookInstaller.install(into: cleaned, command: command, events: spec.events)
                : HookInstaller.installAntigravity(into: cleaned, command: command, events: spec.events)
        } else { new = cleaned }
        let same = try encoded(normalizeCommands(old, kind: spec.kind)) == encoded(normalizeCommands(new, kind: spec.kind))
        return [Edit(path: spec.settingsPath, before: before, after: same ? before.data : try encoded(new))]
    }

    private func decode(_ data: Data?, path: String) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HookInstallerError.unreadableSettings(path: path) }
        return object
    }
    private func encoded(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    private func normalizeCommands(_ value: Any, kind: AgentKind) -> Any {
        if var object = value as? [String: Any] {
            for (key, value) in object { object[key] = normalizeCommands(value, kind: kind) }
            if let command = object["command"] as? String,
               HookCommandOwnership.words(command) == [binary, "hook", "--agent", kind.rawValue] {
                object["command"] = Self.command(binary: binary, kind: kind)
            }
            return object
        }
        if let array = value as? [Any] { return array.map { normalizeCommands($0, kind: kind) } }
        return value
    }

    private func clean(_ old: [String: Any], spec: AgentHookSpec) throws -> [String: Any] {
        var result = old
        let keys = spec.style == .antigravityNested ? old.keys.sorted() : ["hooks"]
        for key in keys {
            guard let value = old[key] else { continue }
            guard var map = value as? [String: Any] else {
                if key == "hooks" || key == HookInstaller.antigravityGroup { throw HookInstallerError.unsupportedShape(path: spec.settingsPath) }
                continue
            }
            for (event, entries) in map {
                guard let array = entries as? [Any] else {
                    if containsCommand(entries) { throw HookInstallerError.unsupportedShape(path: spec.settingsPath) }
                    continue
                }
                let kept = HookInstaller.removingOwnedGroups(array, allowDirect: spec.style == .antigravityNested)
                // An owned command buried in an unsupported shape must not
                // disappear from status while remaining active on disk.
                if containsCommand(kept) { throw HookInstallerError.unsupportedShape(path: spec.settingsPath) }
                if !NSArray(array: kept).isEqual(to: array) {
                    if kept.isEmpty { map.removeValue(forKey: event) } else { map[event] = kept }
                }
            }
            if map.isEmpty, !NSDictionary(dictionary: map).isEqual(to: value as? [String: Any] ?? [:]) { result.removeValue(forKey: key) }
            else { result[key] = map }
        }
        return result
    }

    private func containsCommand(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if let command = object["command"] as? String, HookInstaller.isOurs(command) { return true }
            return object.values.contains(where: containsCommand)
        }
        if let array = value as? [Any] { return array.contains(where: containsCommand) }
        return false
    }

    private func containsOwned(_ spec: AgentHookSpec) throws -> Bool {
        if spec.style == .opencodePlugin || spec.style == .piExtension {
            return try pluginPaths(spec).contains { try HookFileTransaction.read($0).data != nil }
        }
        let settings = try decode(HookFileTransaction.read(spec.settingsPath).data, path: spec.settingsPath)
        if spec.style == .claudeNested { return settings["hooks"].map(containsCommand) ?? false }
        return containsCommand(settings)
    }

    private func commit(_ edits: [Edit]) throws {
        var backups: [String] = []
        do {
            for edit in edits {
                if let backup = try HookFileTransaction.commit(path: edit.path, before: edit.before, after: edit.after) { backups.append(backup) }
            }
        } catch {
            var failed = false
            for backup in backups.reversed() {
                do { try HookFileTransaction.rollback(backup: backup) } catch { failed = true }
            }
            if failed { throw IntegrationSetupError.recoveryFailed("接入修改失败，且部分文件因外部改动无法自动恢复。请检查 .agentpet-backups；已保留恢复备份。原始错误：\(error.localizedDescription)") }
            throw error
        }
    }
}
