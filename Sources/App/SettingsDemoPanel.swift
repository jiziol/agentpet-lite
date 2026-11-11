import SwiftUI
import AgentPetCore

/// A sandbox that feeds current desktop views synthetic session/receipt data.
/// Opening a row acknowledges only its sample task, never a real Agent session.
struct SettingsDemoPanel: View {
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var bubble = BubbleSettings.shared
    @ObservedObject private var idle = IdleSpeechSettings.shared
    @StateObject private var model = PetWindowModel(key: "settings-preview")
    @State private var sample = SettingsPreviewState()
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let agents = AgentCatalog.maintainedKinds
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Label("Task and bubble preview", systemImage: "sparkles.tv").font(.headline)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }.padding(14)
                Divider()
                stage
                Divider()
                sampleList
            }.frame(minWidth: 440, maxWidth: .infinity)
            Divider()
            addColumn.frame(width: 280)
        }
        .background(Theme.surface)
        .onAppear { refresh(now: Date()) }
        .onReceive(tick) { refresh(now: $0) }
        .onChange(of: pet.selectedPetID) { _ in refresh(now: Date()) }
        .onChange(of: pet.showIdleMessage) { _ in refresh(now: Date()) }
        .onChange(of: bubble.hiddenKinds) { _ in refresh(now: Date()) }
        .onChange(of: bubble.readResultRetention) { _ in refresh(now: Date()) }
        .onChange(of: idle.lines) { _ in refresh(now: Date()) }
        .onDisappear { model.stopInteraction() }
    }

    private var stage: some View {
        ScrollView {
            VStack(spacing: 4) {
                PetMessagesView(model: model, expanded: model.messageListExpanded,
                    interactionOverride: BubbleInteraction(focus: { id in
                        let now = Date()
                        sample.markRead(id, now: now)
                        refresh(now: now)
                    }))
                    .onHover { model.hoverTask($0) }
                PetSpeechView(model: model)
                PetView(model: model, size: min(max(pet.petPoint, 80), 120))
                    .onHover { model.hoverBody($0) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .frame(height: 300)
        .background(Theme.card)
        .environment(\.animationsEnabled, pet.animationsEnabled)
    }

    private var sampleList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick scenarios").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    Button("Spawn 3 working") {
                        let now = Date()
                        for kind: AgentKind in [.codex, .antigravity, .opencode] { sample.add(kind, now: now) }
                        refresh(now: now)
                    }.disabled(sample.sessions.count > SettingsPreviewState.maximumTasks - 3)
                    Button("Finish all") {
                        let now = Date()
                        for session in sample.sessions where session.state == .working || session.state == .waiting {
                            sample.setStatus(.completed, id: session.id, now: now)
                        }
                        refresh(now: now)
                    }
                    Button("Clear all") { sample.clear(); refresh(now: Date()) }
                }.controlSize(.small)
                Text("Clicking a preview task marks only that sample as read. No Agent app is opened.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Sample tasks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if sample.sessions.isEmpty {
                    Text("No sample tasks yet. Add one on the right.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(sample.sessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.title ?? "").font(.caption.weight(.semibold))
                        HStack(spacing: 6) {
                            Text(TickerFormatter.agentLabel(for: session.agentKind)).font(.caption)
                            Spacer()
                            Menu {
                                ForEach(SettingsPreviewState.Status.allCases, id: \.self) { status in
                                    Button(NSLocalizedString(status.rawValue, comment: "preview state")) {
                                        sample.setStatus(status, id: session.id, now: Date())
                                        refresh(now: Date())
                                    }
                                }
                            } label: {
                                Text(NSLocalizedString(sample.status(of: session).rawValue, comment: "preview state"))
                            }.fixedSize()
                            Button {
                                sample.markRead(session.id, now: Date()); refresh(now: Date())
                            } label: { Image(systemName: session.hasReadReceipt ? "checkmark.circle.fill" : "checkmark.circle") }
                                .help("Mark sample task as read")
                            Button {
                                sample.reply(to: session.id, duration: bubble.messageDuration, now: Date())
                                refresh(now: Date())
                            } label: { Image(systemName: "bubble.left") }
                                .help("Show sample Agent reply")
                                .disabled(session.taskResult == .failed || session.isStopped)
                            Button {
                                sample.remove(session.id, now: Date()); refresh(now: Date())
                            } label: { Image(systemName: "trash") }.help("Remove sample task")
                        }.controlSize(.small)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                }
            }.padding(14)
        }
    }

    private var addColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Add sample task", systemImage: "plus.app.fill").font(.headline).padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(agents, id: \.self) { kind in
                        HStack {
                            if let icon = AgentIcons.image(for: kind) {
                                Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                            }
                            Text(TickerFormatter.agentLabel(for: kind)).font(.callout)
                            Spacer()
                            Button("Add") { sample.add(kind, now: Date()); refresh(now: Date()) }
                                .buttonStyle(.borderedProminent).tint(Color.systemAccent).controlSize(.small)
                                .disabled(sample.sessions.count >= SettingsPreviewState.maximumTasks)
                        }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    }
                }.padding(14)
            }
        }
    }

    private func refresh(now: Date) {
        sample.advance(now: now)
        model.petID = pet.selectedPetID
        model.sessions = sample.sessions
        model.mood = MoodResolver.aggregate(sample.sessions)
        model.animationContext = PetAnimationContext(sessions: sample.sessions)
        model.speechRows = sample.visibleReplies(hiddenKinds: bubble.hiddenKinds, showTeams: bubble.showAionUiTeams, now: now)
        let visible = BubblePresentation.visible(sample.sessions, settings: bubble.presentationConfiguration)
        model.idleText = pet.showIdleMessage && visible.isEmpty && model.speechRows.isEmpty ? idle.lines.first ?? "" : ""
    }
}
