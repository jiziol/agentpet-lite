import SwiftUI
import AgentPetCore

/// First-launch welcome: pick a pet and connect an agent in one screen.
struct OnboardingView: View {
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var imagePets = ImagePetStore.shared
    var onFinish: () -> Void

    @State private var browsing = false
    @State private var creating = false
    @State private var integrationHelp: AgentIntegrationHelpSelection?

    private var selectedPack: ImagePetPack? {
        pet.selectedPetID.flatMap { imagePets.pack(id: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                petStep
                agentStep
                notificationStep
                HStack {
                    Spacer()
                    Button("Get started") { onFinish() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.systemAccent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(EdgeInsets(top: 40, leading: 28, bottom: 28, trailing: 28))
        }
        .frame(width: 640, height: 640)
        .background(Theme.background)
        .appAppearance()
        .noFocusRing()
        .onAppear { model.refreshAsync() }
        .sheet(isPresented: $browsing) { BrowsePetsView(onClose: { browsing = false }) }
        .sheet(item: $integrationHelp) { selection in
            AgentIntegrationHelpView(kind: selection.kind, inspection: model.integrationStates[selection.kind],
                                     conflict: model.integrationConflicts[selection.kind], model: model)
        }
        .sheet(isPresented: $creating) {
            CreatePetView(
                onCreate: { id in
                    creating = false
                    imagePets.reload()
                    pet.selectedPetID = id
                },
                onCancel: { creating = false }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.systemAccent).frame(width: 34, height: 34)
                    .overlay(Image(systemName: "pawprint.fill").font(.system(size: 17)).foregroundStyle(.white))
                Text("Welcome to AgentPet Lite").font(.title2.bold()).foregroundStyle(.primary)
            }
            Text("A desktop pet that watches your AI coding agents. Two quick steps to get going.")
                .font(.callout).foregroundStyle(Color.primary.opacity(0.7))
        }
    }

    // Step 1: pet
    private var petStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepLabel(1, "Pick your pet")
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.systemAccent.opacity(0.3)))
                    if let pack = selectedPack {
                        ImageSpriteView(frames: pack.clip(0), mood: .idle,
                                        fps: pet.spriteFPS(forMood: .idle), size: 90)
                    } else {
                        Image(systemName: "pawprint.fill").font(.system(size: 40)).foregroundStyle(Color.primary.opacity(0.3))
                    }
                }
                .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedPack?.displayName ?? "Loading a starter pet…")
                        .font(.headline).foregroundStyle(.primary)
                    if let d = selectedPack?.description {
                        Text(d).font(.caption).foregroundStyle(Color.primary.opacity(0.6)).lineLimit(3)
                    }
                    HStack {
                        Button { browsing = true } label: {
                            Label("Browse pets", systemImage: "square.grid.2x2")
                        }
                        Button { creating = true } label: {
                            Label("Create pet", systemImage: "square.and.pencil")
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.systemAccent)
                }
                Spacer()
            }
        }
        .themedCard()
    }

    // Step 2: agent
    private var agentStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepLabel(2, "Connect an agent")
            Text("Install a hook so AgentPet Lite can see when an agent works, finishes, or needs you.")
                .font(.caption).foregroundStyle(Color.primary.opacity(0.6))
            ForEach(model.agents) { agent in
                AgentIntegrationCard(agent: agent, model: model) {
                    integrationHelp = .init(kind: agent.kind)
                }
            }
            if let error = model.installError { Text(error).font(.caption).foregroundStyle(.red) }
            if model.integrationNotice != nil {
                Text("操作已完成。接入说明见对应的ⓘ。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .themedCard()
    }

    // Step 3: notifications (optional)
    private var notificationStep: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable notifications").foregroundStyle(.primary)
                Text("Get alerted when an agent finishes or needs input.")
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.6))
            }
            Spacer()
            switch model.notificationState {
            case .enabled: Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            case .denied: Button("Open Settings") { model.openSystemNotificationSettings() }
            case .notDetermined: Button("Enable") { model.enableNotifications() }
            case .unavailable: Text("—").foregroundStyle(Color.primary.opacity(0.4))
            }
        }
        .themedCard()
    }

    private func stepLabel(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.systemAccent))
            Text(title).font(.headline).foregroundStyle(.primary)
        }
    }
}
