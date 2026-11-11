import SwiftUI
import AppKit

/// Lite product information, bundled licenses, and retained source credits.
struct AboutTabView: View {
    private let upstream = URL(string: "https://github.com/ntd4996/agentpet")!
    private let animations = URL(string: "https://github.com/PC2005-cloud/dsh-pet")!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ApplicationIconView(size: 72)
                    Text("AgentPet Lite").font(.title2.bold())
                    Text("A local desktop companion for your coding agents.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                LabeledContent("Version", value: appVersion)
            }

            Section("Licenses") {
                LabeledContent("Source code", value: "MIT")
                Button("View bundled licenses") {
                    guard let resources = Bundle.main.resourceURL else { return }
                    NSWorkspace.shared.open(resources.appendingPathComponent("Licenses"))
                }
                Text("Third-party assets have their own licenses. The source code license does not cover all artwork.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Acknowledgements") {
                Link(destination: upstream) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "AgentPet · Nguyễn Thành Đạt (@ntd4996)")
                        Text(verbatim: "github.com/ntd4996/agentpet")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Link(destination: animations) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Whale girl animations · PC2005-cloud/dsh-pet")
                        Text(verbatim: "github.com/PC2005-cloud/dsh-pet")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("The whale girl animation assets are for non-commercial use. Keep the original project link when presenting or distributing derivatives.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
