import Foundation

/// Native support and acceptance are separate facts, scoped to host/transport/version.
public enum AgentHost: String, Sendable { case terminal, codexDesktop, aionUi, zed, dshDesktop }
public enum AgentTransport: String, Sendable { case hook, tuiPlugin, extensionPlugin, acp, headless, bridge }
public enum AgentCapability: String, Sendable { case lifecycle, humanChoice, permission, manualStop, navigation }
public enum NativeSupport: String, Sendable { case available, partial, unsupported, unknown }
public enum AcceptanceStatus: String, Sendable { case verified, implementedUnverified, knownDefect, hostUnsupported, untested }

public struct CapabilityEvidence: Sendable, Equatable {
    public let capability: AgentCapability
    public let native: NativeSupport
    public let acceptance: AcceptanceStatus
    public let evidence: String
}

public struct HostIntegration: Sendable, Equatable {
    public let host: AgentHost
    public let transport: AgentTransport
    public let version: String
    public let capabilities: [CapabilityEvidence]
}

public struct AgentIntegration: Identifiable, Sendable, Equatable {
    public enum HumanInputSupport: String, Sendable { case native, partial, unavailable }
    public enum Installation: String, Sendable { case hook, localScript, externalBridge }
    public let kind: AgentKind
    public let displayName: String
    public let installation: Installation
    public let note: String?
    public let humanInputSupport: HumanInputSupport
    public let humanInputNote: String
    public let hosts: [HostIntegration]
    /// Supported means maintained adapter code exists, not that every capability passed.
    public var isSupported: Bool { true }
    public var id: String { kind.rawValue }
}

public enum AgentCatalog {
    private static func evidence(_ capability: AgentCapability, _ native: NativeSupport,
                                 _ acceptance: AcceptanceStatus, _ reference: String) -> CapabilityEvidence {
        .init(capability: capability, native: native, acceptance: acceptance, evidence: reference)
    }
    private static func terminal(_ transport: AgentTransport, version: String, evidence reference: String,
                                 verified: Bool) -> HostIntegration {
        .init(host: .terminal, transport: transport, version: version, capabilities: [
            evidence(.lifecycle, .available, verified ? .verified : .implementedUnverified, reference),
            evidence(.humanChoice, .partial, .implementedUnverified, reference),
            evidence(.permission, .partial, .implementedUnverified, reference),
            evidence(.manualStop, .unknown, .untested, reference),
            evidence(.navigation, .available, .implementedUnverified, reference)
        ])
    }
    private static let aionUi = HostIntegration(host: .aionUi, transport: .headless,
        version: "AionUi 2.2.2（agy headless）", capabilities: [
            evidence(.humanChoice, .unsupported, .hostUnsupported, "docs/maintenance-policy.md：用户反馈 ask_question 不适用"),
            evidence(.permission, .partial, .implementedUnverified, "docs/maintenance-policy.md"),
            evidence(.manualStop, .available, .verified, "docs/maintenance-policy.md：agy 思考停止单项"),
            evidence(.navigation, .available, .implementedUnverified, "docs/maintenance-policy.md：.26 宿主单项通过，未区分 agy/opencode 后端")
        ])
    private static func aionACP(_ agent: String) -> HostIntegration {
        .init(host: .aionUi, transport: .acp, version: "AionUi 2.2.2（" + agent + " ACP）", capabilities: [
            evidence(.lifecycle, .partial, .implementedUnverified, "docs/maintenance-policy.md：仅实现关联，未全验后端"),
            evidence(.humanChoice, .unsupported, .hostUnsupported, "docs/maintenance-policy.md：宿主 ask_question 不适用"),
            evidence(.permission, .partial, .implementedUnverified, "docs/maintenance-policy.md：权限独立保留"),
            evidence(.manualStop, .unknown, .untested, "docs/maintenance-policy.md：agy 单项不能泛化"),
            evidence(.navigation, .available, .implementedUnverified, "docs/maintenance-policy.md：宿主精确导航证据未全覆盖后端")
        ])
    }
    private static let zed = HostIntegration(host: .zed, transport: .acp, version: "当前本机 Zed ACP", capabilities: [
        evidence(.lifecycle, .partial, .knownDefect, "docs/maintenance-policy.md：结束后仍工作"),
        evidence(.navigation, .unknown, .knownDefect, "docs/maintenance-policy.md：不能精确跳转"),
        evidence(.humanChoice, .unknown, .untested, "docs/maintenance-policy.md"),
        evidence(.permission, .unknown, .untested, "docs/maintenance-policy.md")
    ])

    /// Single maintained list for settings, onboarding, discovery, preview and editing.
    public static let all: [AgentIntegration] = [
        .init(kind: .codex, displayName: "Codex", installation: .localScript,
              note: "在设置中 Install／Update；保留原生 Hook 信任步骤",
              humanInputSupport: .native, humanInputNote: "原生选择/答复和权限；能力按宿主记录", hosts: [
                terminal(.hook, version: "当前本机 Codex CLI", evidence: "docs/maintenance-policy.md", verified: true),
                .init(host: .codexDesktop, transport: .hook, version: "Codex 桌面 26.930.21537（历史核对版本）", capabilities: [
                    evidence(.lifecycle, .available, .verified, "docs/maintenance-policy.md"),
                    evidence(.navigation, .available, .implementedUnverified, "docs/maintenance-policy.md：精确页面视觉验收未通过"),
                    evidence(.humanChoice, .available, .implementedUnverified, "docs/maintenance-policy.md"),
                    evidence(.permission, .available, .implementedUnverified, "docs/maintenance-policy.md"),
                    evidence(.manualStop, .available, .implementedUnverified, "docs/maintenance-policy.md")
                ]), aionACP("Codex"), zed
              ]),
        .init(kind: .antigravity, displayName: "Antigravity CLI (agy)", installation: .localScript,
              note: "在设置中 Install／Update；保留 ~/.gemini 原生路径",
              humanInputSupport: .partial, humanInputNote: "原生 CLI 只读观察；AionUi 选择不适用，权限另列", hosts: [
                terminal(.hook, version: "当前本机 agy", evidence: "docs/maintenance-policy.md", verified: true), aionUi, zed
              ]),
        .init(kind: .opencode, displayName: "OpenCode", installation: .localScript,
              note: "Install 前识别本机版本，分别安装 V1/V2 插件；两代 API 不兼容",
              humanInputSupport: .native, humanInputNote: "V1 原生问题/权限，V2 原生表单/权限；真实宿主矩阵未全验", hosts: [
                terminal(.tuiPlugin, version: "V1 1.18.34/1.19.0；V2 2.0.29", evidence: "docs/agent-integrations.md", verified: false), aionACP("opencode")
              ]),
        .init(kind: .dsh, displayName: "DSH", installation: .externalBridge,
              note: "使用独立 bridge；安装、更新与移除由 DSH 原生插件管理器负责",
              humanInputSupport: .native, humanInputNote: "按独立 bridge 的实际协议与能力确认人工待办；宿主行为须分别验证", hosts: [
                .init(host: .dshDesktop, transport: .bridge, version: "AgentPet bridge protocol v1",
                      capabilities: [.lifecycle, .humanChoice, .permission, .manualStop, .navigation].map {
                        evidence($0, .available, .implementedUnverified, "docs/dsh-bridge-protocol.md；连接按实例与能力确认，不以插件包版本判兼容；长期、多窗口和休眠须专项验证")
                      })
              ]),
        .init(kind: .claude, displayName: "Claude Code", installation: .hook,
              note: "保留现有适配；本地原生专项未验", humanInputSupport: .partial,
              humanInputNote: "问题/权限/MCP 输入；无请求 ID 权限仅基础提醒，未宣称验收通过", hosts: [
                terminal(.hook, version: "既有适配，未锁定原生验收版本", evidence: "docs/maintenance-policy.md", verified: false)
              ]),
        .init(kind: .pi, displayName: "Pi", installation: .hook,
              note: "维护 Pi 原生扩展和通用接入；AionUI 专用适配停止维护", humanInputSupport: .partial,
              humanInputNote: "需 ui_prompt_start/end 原生事件；人工交互仍需按宿主验收", hosts: [
                terminal(.extensionPlugin, version: "Pi 1.3.0", evidence: "docs/agent-integrations.md：原生 RPC 隔离检查；终端逐项矩阵待验", verified: false),
                .init(host: .aionUi, transport: .acp, version: "AionUi 2.2.2／pi-acp 0.0.33／Pi 1.3.0", capabilities: [
                    evidence(.lifecycle, .available, .verified, "docs/maintenance-policy.md：正常运行／完成用户确认，不含全部异常场景"),
                    evidence(.navigation, .available, .verified, "docs/agent-integrations.md：对应 Pi 会话真实点击通过"),
                    evidence(.humanChoice, .partial, .implementedUnverified, "docs/maintenance-policy.md：宿主人机交互待验"),
                    evidence(.permission, .partial, .implementedUnverified, "docs/maintenance-policy.md：宿主权限交互待验"),
                    evidence(.manualStop, .available, .implementedUnverified, "docs/maintenance-policy.md：原生 RPC 隔离取消通过；宿主待验")
                ])
              ])
    ]
    public static var maintainedKinds: [AgentKind] { all.map(\.kind) }
    public static func isMaintained(_ kind: AgentKind) -> Bool { all.contains { $0.kind == kind } }
}
