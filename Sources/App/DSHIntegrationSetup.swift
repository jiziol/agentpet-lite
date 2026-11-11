import Foundation

/// Read-only DSH registration diagnostics. Lifecycle compatibility is decided by the wire protocol.
/// DSH's native manager owns installation, upgrades, package integrity and host compatibility.
struct DSHIntegrationSetup: @unchecked Sendable {
    struct Target: Codable, Equatable, Sendable { let application: URL; let home: URL }
    enum Configuration: Sendable { case absent, configured, needsUpdate, legacyManaged, legacyNamed }
    struct Inspection: Sendable {
        let configuration: Configuration
        let detail: String?
        var isInstalled: Bool { configuration != .absent }
    }
    struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let packageName = "@agentpet-lite/dsh-bridge"
    private static let package = packageName
    private static let legacyPackage = "@acerz/dsh-agentpet-bridge"
    private static let toolkit = "@acerz/dsh-toolkit"
    let target: Target
    private let isRunning: @Sendable () -> Bool
    private let fm = FileManager.default
    init(target: Target, isRunning: @escaping @Sendable () -> Bool) {
        self.target = target; self.isRunning = isRunning
    }
    private var profile: URL { target.home.appendingPathComponent("profiles/desktop", isDirectory: true) }
    var desktopIsRunning: Bool { isRunning() }
    private func fail(_ message: String) -> SetupError { SetupError(message: message) }

    private func requireRegular(_ url: URL, limit: Int = 1024 * 1024, allowHardLinks: Bool = false) throws -> Data {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (allowHardLinks || ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1),
              let size = attributes[.size] as? NSNumber, size.intValue <= limit else {
            throw fail("DSH 文件类型或大小不安全：\(url.lastPathComponent)。")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw fail("DSH 配置超过读取限制。") }
        return data
    }

    private func requireDirectory(_ url: URL) throws {
        guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw fail("DSH 目标必须是实际目录，不能是链接。")
        }
    }

    private func rejectLinkedAncestors(_ url: URL) throws {
        // Canonicalize the system's /var and /tmp aliases before walking below them.
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/var/") || path == "/var" { path = "/private" + path }
        if path.hasPrefix("/tmp/") || path == "/tmp" { path = "/private" + path }
        var current = URL(fileURLWithPath: path)
        while current.path != "/" {
            if let attributes = try? fm.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw fail("DSH 目标路径包含链接，已停止自动操作。")
            }
            current.deleteLastPathComponent()
        }
    }

    private func json(_ url: URL, allowHardLinks: Bool = false) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: requireRegular(url, allowHardLinks: allowHardLinks)) as? [String: Any] else {
            throw fail("DSH 配置不是 JSON 对象。")
        }
        return value
    }

    private func applicationInfo() throws -> [String: Any] {
        (try PropertyListSerialization.propertyList(from: requireRegular(target.application.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]) ?? [:]
    }

    func validateApplication() throws {
        guard target.application.isFileURL, target.home.isFileURL, target.application.pathExtension == "app" else {
            throw fail("请选择 DSH 桌面应用和明确的数据目录。")
        }
        try rejectLinkedAncestors(target.application)
        try requireDirectory(target.application)
        let info = try applicationInfo()
        guard info["CFBundleIdentifier"] as? String == "com.deepseek.dsh",
              info["CFBundleExecutable"] as? String == "DeepSeek Harness" else {
            throw fail("请选择官方 DSH macOS 桌面应用。")
        }
    }
    func validateProfile() throws {
        try rejectLinkedAncestors(target.home)
        try requireDirectory(target.home)
        // Registration files are optional diagnostics, not a runtime prerequisite.
        if fm.fileExists(atPath: profile.path) {
            try rejectLinkedAncestors(profile); try requireDirectory(profile)
        }
    }
    /// pnpm symlinks are permitted only when their resolved package stays in this Profile.
    private func installedPackage(_ name: String) throws -> [String: Any]? {
        let modules = profile.appendingPathComponent("node_modules", isDirectory: true)
        guard fm.fileExists(atPath: modules.path) else { return nil }
        try requireDirectory(modules)
        let scope = modules.appendingPathComponent(String(name.split(separator: "/")[0]), isDirectory: true)
        if fm.fileExists(atPath: scope.path) { try requireDirectory(scope) }
        let packageURL = modules.appendingPathComponent(name, isDirectory: true)
        guard (try? packageURL.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil else { return nil }
        let resolved = packageURL.resolvingSymlinksInPath().standardizedFileURL
        let root = profile.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard resolved.path.hasPrefix(root) else { throw fail("DSH 插件链接指向目标 Profile 外，已停止自动操作。") }
        try requireDirectory(resolved)
        // A registered package with a damaged/missing manifest is repairable by
        // the official package manager. Its resolved directory is still confined.
        return (try? json(resolved.appendingPathComponent("package.json"), allowHardLinks: true)) ?? [:]
    }

    private func directDependencies(_ manifest: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for key in ["dependencies", "devDependencies", "optionalDependencies"] {
            if let values = manifest[key] as? [String: String] { result.merge(values) { _, new in new } }
        }
        return result
    }

    func inspect() throws -> Inspection {
        try validateApplication()
        try validateProfile()
        guard fm.fileExists(atPath: profile.appendingPathComponent("package.json").path) else {
            return Inspection(configuration: .absent, detail: nil)
        }
        let manifest = try json(profile.appendingPathComponent("package.json"))
        let dependencies = directDependencies(manifest)
        guard let dsh = manifest["dsh"] as? [String: Any],
              let settings = dsh["profile"] as? [String: Any],
              let bundles = settings["bundles"] as? [String], Set(bundles).count == bundles.count else {
            throw fail("DSH Profile 的 bundle 配置缺失或重复，请先在 DSH 中处理。")
        }
        let toolkit = try installedPackage(Self.toolkit)
        let toolkitDependencies = toolkit.map(directDependencies) ?? [:]
        if dependencies[Self.toolkit] != nil || bundles.contains(Self.toolkit) {
            guard let toolkit else { throw fail("DSH toolkit 已登记但安装内容缺失，请先在 DSH 中修复。") }
            guard toolkit["name"] as? String == Self.toolkit else { throw fail("DSH toolkit 包身份不符。") }
            let bundle = (toolkit["dsh"] as? [String: Any])?["bundle"] as? [String: Any]
            guard let patch = bundle?["patch"] as? String,
                  !patch.hasPrefix("/"), !patch.contains("\\"),
                  !patch.split(separator: "/").contains("..") else {
                throw fail("无法确认 DSH toolkit 的组件范围，请先在 DSH 中检查。")
            }
            let patchURL = profile.appendingPathComponent("node_modules/\(Self.toolkit)/\(patch)").resolvingSymlinksInPath()
            guard patchURL.path.hasPrefix(profile.resolvingSymlinksInPath().path + "/") else {
                throw fail("DSH toolkit patch 指向 Profile 外。")
            }
            let patchText = String(decoding: try requireRegular(patchURL, allowHardLinks: true), as: UTF8.self)
            if [Self.package, Self.legacyPackage].contains(where: { toolkitDependencies[$0] != nil || patchText.contains($0) }) {
                return Inspection(configuration: .legacyManaged,
                    detail: "现有 toolkit 包含 AgentPet bridge；请先在 DSH 拆分旧组合，避免重复加载。Lite 不会卸载其他 toolkit 功能。")
            }
        }
        let installed = try installedPackage(Self.package)
        let direct = dependencies[Self.package] != nil
        let selected = bundles.contains(Self.package)
        let legacy = try installedPackage(Self.legacyPackage)
        let legacyDirect = dependencies[Self.legacyPackage] != nil
        let legacySelected = bundles.contains(Self.legacyPackage)
        guard legacyDirect == legacySelected else {
            throw fail("旧名 AgentPet bridge 的安装与启用记录不一致，请先在 DSH 插件管理器中处理。")
        }
        let userPatch = profile.appendingPathComponent("cordis.patch.yml")
        if (try? userPatch.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil,
           String(decoding: try requireRegular(userPatch), as: UTF8.self).contains(Self.legacyPackage) {
            throw fail("DSH 用户 patch 仍引用旧包名；请先在原生插件管理器中保留配置并迁移到 @agentpet-lite/dsh-bridge，再操作。")
        }
        if legacyDirect || legacy != nil {
            guard !direct, !selected, installed == nil else {
                throw fail("发现新旧两种 AgentPet bridge，请先在 DSH 中处理重复注册，避免同一组件加载两次。")
            }
            guard legacyDirect else { throw fail("发现未直接登记的旧名 bridge，请先确认它所属的 DSH bundle。") }
            if let name = legacy?["name"] as? String, name != Self.legacyPackage {
                throw fail("旧名 AgentPet bridge 包身份不符，已停止自动操作。")
            }
            return Inspection(configuration: .legacyNamed,
                detail: "当前为旧名独立包 @acerz/dsh-agentpet-bridge。请在 DSH 原生插件管理器迁移至新包；其他 toolkit 功能和配置保留。")
        }
        guard direct == selected else {
            throw fail("AgentPet bridge 的安装与启用记录不一致，请先在 DSH 插件管理器中处理。")
        }
        guard direct else {
            // An unregistered package could still be contributed by an unknown bundle.
            guard installed == nil else { throw fail("发现非 Lite 直接管理的 bridge 包，请先确认它所属的 DSH bundle。") }
            return Inspection(configuration: .absent, detail: nil)
        }
        guard let installed, installed["name"] as? String == Self.package,
              let version = installed["version"] as? String, !version.isEmpty, version.utf8.count <= 128 else {
            return Inspection(configuration: .needsUpdate, detail: "DSH 插件登记存在，但包信息缺失；请在 DSH 插件管理器中检查。")
        }
        // Check structural entrypoints inside this installed package. Never compare an external
        // release with an application's bundled version or file hashes.
        let patch = ((installed["dsh"] as? [String: Any])?["bundle"] as? [String: Any])?["patch"] as? String
        let client = (installed["exports"] as? [String: Any])?["./client"]
        let clientEntry = client as? String ?? (client as? [String: String])?["default"]
        let entries = [installed["main"] as? String, clientEntry, patch]
        let root = profile.appendingPathComponent("node_modules/\(Self.package)").resolvingSymlinksInPath()
        for entry in entries {
            guard let entry, !entry.hasPrefix("/"), !entry.contains("\\"),
                  !entry.split(separator: "/").contains("..") else {
                return Inspection(configuration: .needsUpdate, detail: "DSH 插件入口缺失或无效；请在 DSH 插件管理器中检查。")
            }
            let file = root.appendingPathComponent(entry).resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/") else { throw fail("DSH bridge 文件指向包外，已停止检查。") }
            guard (try? requireRegular(file, limit: 16 * 1024 * 1024, allowHardLinks: true)) != nil else {
                return Inspection(configuration: .needsUpdate, detail: "DSH 插件入口缺失或无法读取；请在 DSH 插件管理器中检查。")
            }
        }
        return Inspection(configuration: .configured, detail: nil)
    }
}
