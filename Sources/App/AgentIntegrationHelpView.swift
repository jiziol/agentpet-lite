import SwiftUI
import AgentPetCore

struct AgentIntegrationHelpSelection: Identifiable {
    let kind: AgentKind
    var id: String { kind.rawValue }
}

/// Shared by settings and onboarding; opening help never installs or trusts a hook.
struct AgentIntegrationHelpView: View {
    let kind: AgentKind
    let inspection: IntegrationInspection?
    let conflict: String?
    @ObservedObject var model: SettingsModel = .shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared

    private var name: String { AgentCatalog.all.first { $0.kind == kind }?.displayName ?? kind.rawValue }
    private var steps: [String] {
        switch kind {
        case .codex: return ["integration.install", "integration.codex", "integration.reload"]
        case .opencode: return ["integration.opencode.install", "integration.opencode", "integration.opencode.reload"]
        case .antigravity: return ["integration.install", "integration.agy", "integration.reload"]
        case .pi: return ["integration.install", "integration.pi", "integration.reload"]
        default: return ["integration.compatibility", "integration.install", "integration.reload"]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(name); Text("Integration details") }.font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if conflict != nil {
                        Text("integration.checkFailed").font(.callout).foregroundStyle(.orange)
                    }
                    if let issue = conflict ?? inspection?.installBlockReason {
                        Text(NSLocalizedString(issue, comment: "integration issue")).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if inspection?.configuration == .needsUpdate {
                        Text("integration.stale").font(.callout).foregroundStyle(.orange)
                    }
                    if let notice = inspection?.clientNotice, conflict != nil {
                        Text(NSLocalizedString(notice, comment: "client integration notice"))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        if kind == .antigravity {
                            Text("integration.agy.scope").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                                    .frame(width: 20, height: 20).background(Circle().fill(.blue))
                                Text(LocalizedStringKey(step)).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if kind == .claude {
                        Divider()
                        HStack {
                            Text("Approve Bash from the bubble")
                            Spacer()
                            ColorSwitch(isOn: $model.approvalGateEnabled)
                                .accessibilityLabel(Text("Approve Bash from the bubble"))
                                .accessibilityIdentifier("claude-approval-gate")
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 480)
            HStack {
                if kind == .codex {
                    Link("Codex Hooks 官方文档", destination: URL(string: "https://learn.chatgpt.com/docs/hooks")!)
                        .font(.caption)
                } else if kind == .opencode {
                    Link("OpenCode 版本迁移说明", destination: URL(string: "https://opencode.ai/v2/docs/build/plugins/migrate-v1")!)
                        .font(.caption)
                }
                Spacer()
                Button("Got it") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .environment(\.locale, language.locale)
    }
}
