import SwiftUI

/// Stable builds carry the settings/help entry only. The R5 source variant
/// enables availability; neither a saved preference nor a runtime Git lookup
/// can activate an adapter absent from this build.
enum AOExperiment {
    static let isAvailable = true
    static let preferenceKey = "agentpet.bubble.aoExperimentEnabled"
    static let officialURL = URL(string: "https://github.com/OrchestratorInc")!

    static func isActive(requested: Bool) -> Bool { isAvailable && requested }
}

struct AOExperimentSettingsRow: View {
    @ObservedObject var settings: BubbleSettings
    @State private var showingHelp = false

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Agent Orchestrator")
            SourceStatusTag("ao.experiment.badge", experimental: true)
            Button { showingHelp = true } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("ao.experiment.details"))
            .accessibilityIdentifier("ao-experiment-help")
            Spacer(minLength: 8)
            Toggle("Agent Orchestrator", isOn: Binding(
                get: { settings.aoExperimentActive },
                set: { settings.aoExperimentEnabled = $0 }))
                .labelsHidden().disabled(!AOExperiment.isAvailable)
                .accessibilityLabel(Text("ao.experiment.toggle"))
                .accessibilityIdentifier("bubble-ao-experiment")
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showingHelp) { AOExperimentHelpView() }
    }
}

struct AOExperimentHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AgentPet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(verbatim: "Agent Orchestrator").font(.title3.bold())
                Text("ao.experiment.badge").font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ao.experiment.scope").font(.callout)
                    if !AOExperiment.isAvailable {
                        Text("ao.experiment.unavailable").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("ao.experiment.permission").font(.callout)
                    ForEach(1...4, id: \.self) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(step)").font(.caption.bold()).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(Circle().fill(.blue))
                            if step == 3 {
                                Text(String(format: NSLocalizedString("ao.experiment.step.3", comment: "Running app name"), appName))
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(LocalizedStringKey("ao.experiment.step." + String(step)))
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text("ao.experiment.safety").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true).frame(maxHeight: 440)
            HStack {
                Link("OrchestratorInc", destination: AOExperiment.officialURL).font(.caption)
                Spacer()
                Button("Got it") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 500)
        .environment(\.locale, language.locale)
    }
}
