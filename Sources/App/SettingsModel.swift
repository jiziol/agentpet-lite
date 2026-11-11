import AppKit
import Foundation
@preconcurrency import UserNotifications
import AgentPetCore

/// Backs the onboarding/Settings window: notification permission status and
/// per-agent hook install state, with the actions to change them.
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    enum NotificationState: Equatable {
        case unavailable   // running as bare binary, no bundle
        case notDetermined
        case enabled
        case denied
    }

    @Published private(set) var notificationState: NotificationState = .notDetermined
    @Published private(set) var installedKinds: Set<AgentKind> = []
    @Published private(set) var usageEligibilityRevision = 0
    @Published private(set) var integrationStates: [AgentKind: IntegrationInspection] = [:]
    @Published private(set) var integrationConflicts: [AgentKind: String] = [:]
    /// Surfaced when an install/uninstall fails (e.g. an agent's settings file is
    /// not valid JSON), so the user sees why instead of a silent no-op.
    @Published var installError: String?
    @Published var integrationNotice: String?
    @Published private(set) var dshState: DSHIntegrationSetup.Inspection?
    @Published private(set) var busyIntegrations: Set<AgentKind> = []

    /// In-app notification toggle: lets users mute alerts even after granting
    /// the macOS permission. Defaults to on.
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: NotificationManager.enabledKey) }
    }

    /// Backed by `~/.agentpet/approval-gate.json` so the separate hook CLI process reads it too.
    @Published var approvalGateEnabled: Bool {
        didSet { ApprovalGateConfig.setEnabled(approvalGateEnabled) }
    }

    let agents = AgentCatalog.all
    private let setupOverride: AgentIntegrationSetup?
    private let dshSetupOverride: DSHIntegrationSetup?
    private let dshTargetKey = "agentpet.dsh.target.v1"

    init(integrationSetup: AgentIntegrationSetup? = nil, dshSetup: DSHIntegrationSetup? = nil) {
        setupOverride = integrationSetup
        dshSetupOverride = dshSetup
        notificationsEnabled = (UserDefaults.standard.object(forKey: NotificationManager.enabledKey) as? Bool) ?? true
        approvalGateEnabled = ApprovalGateConfig.isEnabled()
    }

    @Published private(set) var inspectingIntegrations = false
    @Published private(set) var connectionTests: [AgentKind: ConnectionRun] = [:]
    struct ConnectionRun {
        let id: String
        let cancellation: LocalAgentTestCancellation
        var result: LocalAgentConnectionResult?
        var dshResult: DSHReadinessResult?
    }
    private var refreshID = UUID()

    private struct InspectionSnapshot: Sendable {
        var states: [AgentKind: IntegrationInspection] = [:]
        var conflicts: [AgentKind: String] = [:]
        var dsh: DSHIntegrationSetup.Inspection?
    }

    nonisolated private static func inspect(_ setup: AgentIntegrationSetup, _ dsh: DSHIntegrationSetup?) -> InspectionSnapshot {
        var snapshot = InspectionSnapshot()
        for agent in AgentCatalog.all where agent.installation != .externalBridge {
            do { snapshot.states[agent.kind] = try setup.inspect(agent.kind) }
            catch { snapshot.conflicts[agent.kind] = NSLocalizedString(error.localizedDescription, comment: "integration error") }
        }
        if let dsh {
            do { snapshot.dsh = try dsh.inspect() }
            catch { snapshot.conflicts[.dsh] = NSLocalizedString(error.localizedDescription, comment: "integration error") }
        } else { snapshot.conflicts[.dsh] = NSLocalizedString("未找到 DSH 应用，请先安装并启动一次 DSH。", comment: "") }
        return snapshot
    }

    private func apply(_ snapshot: InspectionSnapshot, notifyUsage: Bool = true) {
        // Retain the last known state on read failure; the mutation gate still blocks it.
        for (kind, state) in snapshot.states { integrationStates[kind] = state }
        if let state = snapshot.dsh { dshState = state }
        integrationConflicts = snapshot.conflicts
        for (kind, state) in snapshot.states {
            if state.configuration == .absent { installedKinds.remove(kind) } else { installedKinds.insert(kind) }
        }
        if let state = snapshot.dsh {
            if state.isInstalled { installedKinds.insert(.dsh) } else { installedKinds.remove(.dsh) }
        }
        refreshNotificationState()
        if notifyUsage { usageEligibilityRevision += 1 }
    }

    func refresh() { apply(Self.inspect(integrationSetup, dshSetup)) }

    /// The same current inspection drives integration cards and usage eligibility.
    /// Do not authorize a collector using installedKinds retained after a failure.
    func refreshTokenUsageAccess() async -> [TokenIntegrationAccess] {
        guard busyIntegrations.isEmpty else { return [] }
        let setup = integrationSetup, dsh = dshSetup
        let snapshot = await Task.detached { Self.inspect(setup, dsh) }.value
        apply(snapshot, notifyUsage: false)
        let home = setup.home
        let roots: [(TokenSource, AgentKind, URL)] = [
            (.codex, .codex, URL(fileURLWithPath: (setup.environment["CODEX_HOME"] ?? home + "/.codex"))),
            (.opencode, .opencode, URL(fileURLWithPath: (setup.environment["XDG_DATA_HOME"] ?? home + "/.local/share") + "/opencode")),
            (.claude, .claude, URL(fileURLWithPath: home + "/.claude/projects")),
            (.dsh, .dsh, dsh?.target.home ?? URL(fileURLWithPath: home + "/.dsh"))
        ]
        return roots.map { source, kind, root in
            let known = snapshot.conflicts[kind] == nil
            let configured = kind == .dsh ? snapshot.dsh?.isInstalled == true : snapshot.states[kind]?.configuration != .absent && snapshot.states[kind] != nil
            return TokenIntegrationAccess(instance: .init(source: source, root: root), eligible: known && configured, removed: known && !configured)
        }
    }

    func refreshAsync() {
        guard !inspectingIntegrations, busyIntegrations.isEmpty else { return }
        inspectingIntegrations = true
        let id = UUID(); refreshID = id
        let setup = integrationSetup, dsh = dshSetup
        Task {
            let snapshot = await Task.detached { Self.inspect(setup, dsh) }.value
            guard refreshID == id else { return }
            apply(snapshot); inspectingIntegrations = false
        }
    }

    func configurationLabel(_ kind: AgentKind) -> String? {
        guard kind == .dsh ? dshState != nil : integrationStates[kind] != nil else { return nil }
        return isInstalled(kind) ? "已配置" : "未配置"
    }

    func canConfigure(_ kind: AgentKind) -> Bool {
        guard !inspectingIntegrations, busyIntegrations.isEmpty, !isTesting(kind) else { return false }
        if kind == .dsh { return dshSetup != nil }
        guard integrationConflicts[kind] == nil, configurationLabel(kind) != nil else { return false }
        return isInstalled(kind) || integrationStates[kind]?.installBlockReason == nil
    }

    func isTesting(_ kind: AgentKind) -> Bool { connectionTests[kind].map { $0.result == nil && $0.dshResult == nil } ?? false }

    func startConnectionTest(_ kind: AgentKind, service: LocalAgentConnectionTest = .init()) {
        guard !isTesting(kind), !isIntegrationBusy(kind) else { return }
        let id = UUID().uuidString, cancellation = LocalAgentTestCancellation()
        connectionTests[kind] = .init(id: id, cancellation: cancellation)
        if kind == .dsh {
            let setup = dshSetup
            Task {
                let result = await DSHReadinessTest.run(setup: setup, cancellation: cancellation, signal: { profile, began in
                    AppDaemon.shared.dshLiveSignals.signal(profileID: profile, since: began)
                }, health: DSHReadinessTest.discoverHealth)
                guard connectionTests[kind]?.id == id else { return }
                connectionTests[kind]?.dshResult = result
            }
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                service.run(kind, requestID: id, cancellation: cancellation)
            }.value
            guard connectionTests[kind]?.id == id else { return }
            connectionTests[kind]?.result = result
        }
    }

    func cancelConnectionTest(_ kind: AgentKind) { connectionTests[kind]?.cancellation.cancel() }

    func configureIntegrationAsync(_ kind: AgentKind) {
        guard canConfigure(kind) else { return }
        let remove = isInstalled(kind)
        if kind == .dsh { configureDSHIntegration(remove: remove); return }
        busyIntegrations.insert(kind); installError = nil; integrationNotice = nil
        let setup = integrationSetup
        Task {
            let failure = await Task.detached { () -> String? in
                do { if remove { try setup.remove(kind) } else { try setup.install(kind) }; return nil }
                catch { return error.localizedDescription }
            }.value
            installError = failure.map { NSLocalizedString($0, comment: "integration error") }
            if failure == nil { integrationNotice = NSLocalizedString("操作已完成。接入说明见对应的ⓘ。", comment: "") }
            await finishConfiguration(kind)
        }
    }

    func isInstalled(_ kind: AgentKind) -> Bool {
        installedKinds.contains(kind)
    }

    func isIntegrationBusy(_ kind: AgentKind) -> Bool { busyIntegrations.contains(kind) }

    var dshStatusLabel: String { configurationLabel(.dsh) ?? "" }
    var dshNeedsUpdate: Bool { dshState?.configuration == .needsUpdate }

    private var selectedDSHTarget: DSHIntegrationSetup.Target? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        if let data = UserDefaults.standard.data(forKey: dshTargetKey),
           let target = try? JSONDecoder().decode(DSHIntegrationSetup.Target.self, from: data) {
            return target
        }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.deepseek.dsh") else { return nil }
        let environmentHome = ProcessInfo.processInfo.environment["DSH_HOME"]
        let home: URL
        if let path = environmentHome, path.hasPrefix("/") {
            home = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh", isDirectory: true)
        }
        return .init(application: application, home: home)
    }

    private var dshSetup: DSHIntegrationSetup? {
        if let dshSetupOverride { return dshSetupOverride }
        guard let target = selectedDSHTarget else { return nil }
        return DSHIntegrationSetup(target: target,
            isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.deepseek.dsh").isEmpty })
    }

    private func saveDSHTarget(_ target: DSHIntegrationSetup.Target) {
        if let data = try? JSONEncoder().encode(target) { UserDefaults.standard.set(data, forKey: dshTargetKey) }
    }

    private func chooseDSHHome(for target: DSHIntegrationSetup.Target) -> Bool {
        guard !isIntegrationBusy(.dsh), !isTesting(.dsh) else { return false }
        let chooser = NSOpenPanel()
        chooser.title = NSLocalizedString("选择 DSH 数据目录", comment: "")
        chooser.message = NSLocalizedString("选择包含 profiles/desktop 的 DSH 数据目录。不会创建或初始化新 Profile。", comment: "")
        chooser.canChooseDirectories = true; chooser.canChooseFiles = false
        chooser.allowsMultipleSelection = false; chooser.canCreateDirectories = false
        chooser.directoryURL = target.home
        guard chooser.runModal() == .OK, let home = chooser.url else { return false }
        saveDSHTarget(.init(application: target.application, home: home))
        refresh()
        return true
    }

    var dshTargetDescription: String? {
        guard let target = selectedDSHTarget else { return nil }
        return String(format: NSLocalizedString("dsh.target.description", comment: ""), target.application.path, target.home.path)
    }

    func chooseDSHDataDirectory() {
        guard let target = selectedDSHTarget else { return }
        _ = chooseDSHHome(for: target)
    }

    func openDSHManagement() {
        guard let setup = dshSetup else { return }
        do { try setup.validateApplication() }
        catch { installError = error.localizedDescription; return }
        integrationNotice = NSLocalizedString("dsh.manage.notice", comment: "")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: setup.target.application, configuration: configuration)
    }

    private func configureDSHIntegration(remove: Bool) { openDSHManagement() }

    private func finishConfiguration(_ kind: AgentKind) async {
        let setup = integrationSetup, dsh = dshSetup
        let snapshot = await Task.detached { Self.inspect(setup, dsh) }.value
        apply(snapshot); busyIntegrations.remove(kind)
    }

    /// Re-applies hooks for already-installed agents once per app version, so
    /// existing users pick up newly-added events (e.g. SessionEnd for instant
    /// clear on quit) without manually re-installing. Idempotent and only
    /// touches our own hook entries.
    func migrateInstalledHooksIfNeeded() {
        guard !AgentPetPaths.isLocal else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let key = "agentpet.hookMigration.\(version)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for agent in agents where agent.isSupported {
            reinstallIfInstalled(agent.kind)
        }
    }

    /// Re-runs the (idempotent) install for `kind` when its hook is already on
    /// disk. Never installs for an agent the user hasn't enabled.
    private func reinstallIfInstalled(_ kind: AgentKind) {
        guard let spec = AgentHooks.spec(for: kind),
              HookInstaller.isInstalledOnDisk(path: spec.settingsPath, events: spec.events, style: spec.style)
        else { return }
        try? HookInstaller.installToDisk(command: hookCommand(for: kind),
                                         path: spec.settingsPath, events: spec.events, style: spec.style)
    }

    /// Repairs hook entries whose embedded binary path no longer matches the
    /// current executable location. Runs on every launch so hooks stay valid
    /// after the app is moved, re-downloaded, or updated via a different channel
    /// (e.g. Homebrew vs DMG).  Idempotent — only rewrites when the path differs.
    func repairStaleHookPathsIfNeeded() {
        guard !AgentPetPaths.isLocal else { return }
        let currentPath = Bundle.main.executablePath ?? ""
        guard !currentPath.isEmpty else { return }
        let expectedCommand = "\"\(currentPath)\" hook"
        for agent in agents where agent.isSupported {
            guard let spec = AgentHooks.spec(for: agent.kind) else { continue }
            guard let settings = try? HookInstaller.readSettings(path: spec.settingsPath) else { continue }
            guard HookInstaller.isInstalledOnDisk(path: spec.settingsPath,
                                                  events: spec.events,
                                                  style: spec.style) else { continue }
            // Check if any stored hook command references a different binary path.
            let needsRepair: Bool = {
                guard let hooks = settings["hooks"] as? [String: Any] else { return false }
                for event in spec.events {
                    guard let groups = hooks[event] as? [[String: Any]] else { continue }
                    for group in groups {
                        guard let inner = group["hooks"] as? [[String: Any]] else { continue }
                        for entry in inner {
                            if let cmd = entry["command"] as? String,
                               HookInstaller.isOurs(cmd),
                               !cmd.hasPrefix(expectedCommand) {
                                return true
                            }
                        }
                    }
                }
                return false
            }()
            guard needsRepair else { continue }
            try? HookInstaller.installToDisk(command: hookCommand(for: agent.kind),
                                             path: spec.settingsPath,
                                             events: spec.events,
                                             style: spec.style)
        }
    }

    private func hookCommand(for kind: AgentKind) -> String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "agentpet"
        return AgentIntegrationSetup.command(binary: path, kind: kind)
    }

    private var integrationSetup: AgentIntegrationSetup {
        setupOverride ?? AgentIntegrationSetup(binary: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "agentpet")
    }

    func configureIntegration(_ kind: AgentKind, remove: Bool = false) {
        guard !isIntegrationBusy(kind), !isTesting(kind), !inspectingIntegrations else { return }
        if kind == .dsh { configureDSHIntegration(remove: remove); return }
        installError = nil
        integrationNotice = nil
        do {
            if remove {
                try integrationSetup.remove(kind)
                integrationNotice = NSLocalizedString("已移除全局 AgentPet 接入。请重开所用客户端，使内存中已加载的接入停止生效。客户端、其他插件、用户数据与恢复备份均保留。", comment: "")
            } else {
                try integrationSetup.install(kind)
                integrationNotice = kind == .codex
                    ? NSLocalizedString("已写入 Codex 接入。请在 Codex 的 /hooks 中审阅并信任 AgentPet 项，然后重开所用客户端。", comment: "")
                    : kind == .opencode ? NSLocalizedString("已写入对应版本的 OpenCode 接入。V1 重开客户端；V2 请在当前任务结束后执行 opencode reload，再继续使用。", comment: "")
                    : "已写入接入，请重开所用客户端后使用。"
            }
        } catch {
            installError = NSLocalizedString(error.localizedDescription, comment: "integration error")
        }
        refresh()
    }

    func enableNotifications() {
        guard NotificationManager.shared.isAvailable else { return }
        Task { @MainActor in
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            self.refreshNotificationState()
        }
    }

    /// Opens System Settings to AgentPet's notification pane (used when denied).
    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshNotificationState() {
        guard NotificationManager.shared.isAvailable else {
            notificationState = .unavailable
            return
        }
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.notificationState = .enabled
            case .denied:
                self.notificationState = .denied
            default:
                self.notificationState = .notDetermined
            }
        }
    }
}
