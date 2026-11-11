import SwiftUI
import AgentPetCore

/// Read-only beginner guide. Installation remains an explicit action on the card.
struct DSHIntegrationHelpView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                AgentIconView(kind: .dsh, size: 26)
                Text("dsh.guide.title").font(.title3.bold())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("dsh.guide.intro").font(.callout)
                    if model.isInstalled(.dsh) {
                        Label("dsh.guide.configured", systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        step(1, "dsh.guide.prepare.title", "dsh.guide.prepare")
                        step(2, "dsh.guide.quit.title", "dsh.guide.quit")
                        step(3, "dsh.guide.install.title", "dsh.guide.install")
                        step(4, "dsh.guide.verify.title", "dsh.guide.verify")
                    }
                    Divider()
                    Text("dsh.guide.test").font(.caption).foregroundStyle(.secondary)
                    if let issue = model.integrationConflicts[.dsh] ?? model.dshState?.detail {
                        Text(NSLocalizedString(issue, comment: "DSH configuration detail")).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if model.dshNeedsUpdate || model.dshState?.configuration == .legacyNamed {
                        Text("integration.stale").font(.callout).foregroundStyle(.orange)
                    }
                    DisclosureGroup("dsh.guide.advanced") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("dsh.guide.location").font(.caption).foregroundStyle(.secondary)
                            Button("更改数据目录…") { model.chooseDSHDataDirectory() }
                                .disabled(model.dshTargetDescription == nil || model.isIntegrationBusy(.dsh) || model.isTesting(.dsh))
                            Text("dsh.guide.manual").font(.caption).foregroundStyle(.secondary)
                            Text("@agentpet-lite/dsh-bridge").font(.caption.monospaced()).textSelection(.enabled)
                            Button("dsh.manage.button") { model.openDSHManagement() }
                            if let error = model.installError { Text(error).font(.caption).foregroundStyle(.red) }
                        }.padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 510, height: 540)
        .environment(\.locale, language.locale)
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number)).font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.bold())
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
