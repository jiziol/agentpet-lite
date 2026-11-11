import SwiftUI
import AgentPetCore

/// One shared contract in settings and onboarding. Test never drives configuration.
struct AgentIntegrationCard: View {
    let agent: AgentIntegration
    @ObservedObject var model: SettingsModel
    var showHelp: () -> Void
    @State private var showingTest = false
    @State private var showingDSHHelp = false

    var body: some View {
        HStack(spacing: 8) {
            AgentIconView(kind: agent.kind, size: 20).frame(width: 24, height: 24)
            Text(agent.displayName).font(.callout.weight(.medium))
                .lineLimit(1).minimumScaleFactor(0.85).help(agent.displayName)
            if let label = model.configurationLabel(agent.kind) {
                Text(LocalizedStringKey(label)).font(.caption).fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.10)))
            }
            Button {
                if agent.kind == .dsh { showingDSHHelp = true } else { showHelp() }
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(model.integrationConflicts[agent.kind] == nil ? Color.secondary : Color.orange)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Integration details"))
            .accessibilityIdentifier("integration-help-\(agent.kind.rawValue)")
            Spacer(minLength: 0)
            if model.inspectingIntegrations || model.isIntegrationBusy(agent.kind) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14)
                    .accessibilityLabel(Text("Checking configuration"))
            }
            Button {
                model.startConnectionTest(agent.kind); showingTest = true
            } label: { Text(verbatim: "Test").frame(width: 42) }
                .disabled(model.isTesting(agent.kind) || model.isIntegrationBusy(agent.kind))
                .accessibilityIdentifier("integration-test-\(agent.kind.rawValue)")
            Button {
                model.configureIntegrationAsync(agent.kind)
            } label: { Text(verbatim: agent.kind == .dsh ? NSLocalizedString("dsh.manage.button", comment: "") : model.isInstalled(agent.kind) ? "Remove" : "Install").frame(minWidth: 58) }
                .disabled(!model.canConfigure(agent.kind))
                .accessibilityIdentifier("integration-configure-\(agent.kind.rawValue)")
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showingDSHHelp) { DSHIntegrationHelpView(model: model) }
        .sheet(isPresented: $showingTest) {
            AgentConnectionTestView(kind: agent.kind, name: agent.displayName, model: model)
        }
    }
}

struct AgentConnectionTestView: View {
    let kind: AgentKind
    let name: String
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                AgentIconView(kind: kind, size: 24)
                Text(name + " · Test").font(.headline)
            }
            if let run = model.connectionTests[kind] {
                if let result = run.dshResult {
                    Label {
                        Text(LocalizedStringKey("dsh.test.status." + result.status.rawValue)).font(.headline)
                    } icon: {
                        Image(systemName: result.status == .connected ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(result.status == .connected ? Color.green : Color.orange)
                    }
                    Text(LocalizedStringKey("dsh.test.next." + result.status.rawValue)).font(.callout)
                    ForEach(Array(result.checks.enumerated()), id: \.offset) { _, check in
                        VStack(alignment: .leading, spacing: 3) {
                            Label {
                                Text(LocalizedStringKey("dsh.test.check." + check.key
                                    + (check.key == "running" && !check.passed ? ".failed" : "")))
                            } icon: {
                                Image(systemName: check.passed ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(check.passed ? Color.green : Color.orange)
                            }
                            if !check.detail.isEmpty {
                                Text(NSLocalizedString(check.detail, comment: "DSH check detail")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.font(.callout)
                    }
                    if !result.evidence.isEmpty {
                        Text(result.evidence).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } else if let result = run.result {
                    Label {
                        Text(LocalizedStringKey("connection.status." + result.status.rawValue)).font(.headline)
                    } icon: {
                        Image(systemName: result.status == .connected ? "checkmark.circle.fill" : result.status == .cancelled ? "stop.circle" : "exclamationmark.circle")
                            .foregroundStyle(result.status == .connected ? Color.green : Color.orange)
                    }
                    if result.status != .connected {
                        Text(LocalizedStringKey(result.message)).font(.callout)
                    }
                    if !result.evidence.isEmpty {
                        Text(result.evidence).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text(LocalizedStringKey(kind == .dsh ? "dsh.test.testing" : "connection.testing")) }
                }
                if kind != .dsh { Text("connection.scope").font(.caption).foregroundStyle(.secondary) }
                Text(LocalizedStringKey("connection.scope." + kind.rawValue))
                    .font(.caption).foregroundStyle(.secondary)
                Text("ID: " + run.id).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Spacer()
                if model.isTesting(kind) {
                    Button("Cancel") { model.cancelConnectionTest(kind) }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Test again") { model.startConnectionTest(kind) }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22).frame(width: 450)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { model.cancelConnectionTest(kind) }
        .environment(\.locale, language.locale)
    }
}
