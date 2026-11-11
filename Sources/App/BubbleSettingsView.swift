import SwiftUI
import AgentPetCore

/// Content/lifetime settings. Shared appearance lives only in General / Pet display.
struct BubbleSettingsView: View {
    var isPreviewOpen = false
    var onTogglePreview: () -> Void = {}

    @ObservedObject private var settings = BubbleSettings.shared
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var idle = IdleSpeechSettings.shared
    @State private var customDraft = ""
    @State private var editingCustom = false
    @State private var previewIndex = 0

    private var retentionOptions: [ReadResultRetention] {
        let offered: [ReadResultRetention] = [.oneSecond, .threeSeconds, .fiveSeconds, .tenSeconds]
        // Keep a previously chosen legacy duration selectable until changed.
        return offered.contains(settings.readResultRetention) ? offered : offered + [settings.readResultRetention]
    }
    private var draftLines: [String] { IdleSpeechSettings.validLines(customDraft) }
    private var previewLines: [String] { editingCustom ? draftLines : idle.lines }

    var body: some View {
        Form {
            Section("Preview") {
                Button(action: onTogglePreview) {
                    Label(isPreviewOpen ? "Hide task and bubble preview" : "Task and bubble preview", systemImage: "sparkles.tv")
                }
                .accessibilityIdentifier("task-bubble-preview")
                hint("Use sample tasks to preview the pet and task bubble. This does not test Agent connections.")
            }
            Section("Task bubble") {
                Picker("Read result retention", selection: $settings.readResultRetention) {
                    ForEach(retentionOptions, id: \.self) { value in Text(value.displayName).tag(value) }
                }.accessibilityIdentifier("read-result-retention")
                HStack {
                    Text("Task bubble click-through")
                    Spacer()
                    ColorSwitch(isOn: $settings.taskBubbleClickThrough)
                        .accessibilityIdentifier("task-bubble-click-through")
                        .accessibilityLabel("Task bubble click-through")
                        .accessibilityValue(settings.taskBubbleClickThrough ? "On" : "Off")
                }
                hint("Double-click the pet to toggle. While a task needs approval or attention, the bubble stays clickable.")
                hint("Tasks are always on. Running, waiting and unread tasks remain visible.")
            }
            Section("Agent messages") {
                Picker("Message display duration", selection: $settings.messageDuration) {
                    ForEach(BubbleSettings.messageDurations, id: \.self) { value in
                        Text(String(format: NSLocalizedString("%d seconds", comment: ""), Int(value))).tag(value)
                    }
                }.accessibilityIdentifier("agent-message-duration")
                hint("Public replies are always on: up to 6 messages, 20 characters each. A full feed moves the oldest message out early.")
            }
            Section("Superchat") {
                HStack {
                    Text("Show Superchat")
                    Spacer()
                    ColorSwitch(isOn: $settings.superchatEnabled).accessibilityIdentifier("superchat-enabled")
                        .accessibilityLabel("Show Superchat")
                        .accessibilityValue(settings.superchatEnabled ? "On" : "Off")
                }
                hint("Quota notices show for 8 seconds. Pomodoro alerts stay until confirmation or the next phase. Turning this off keeps Agent messages and the timer running.")
            }
            Section("Pet idle chatter") {
                if !pet.showIdleMessage { hint("Idle chatter is hidden. Enable it in General / Pet display.") }
                Picker("Message source", selection: Binding(
                    get: { editingCustom ? IdleSpeechSettings.Source.custom : .builtin },
                    set: { value in
                        editingCustom = value == .custom
                        previewIndex = 0
                        if value == .builtin { idle.source = .builtin }
                    })) {
                    Text("Built-in").tag(IdleSpeechSettings.Source.builtin)
                    Text("Custom").tag(IdleSpeechSettings.Source.custom)
                }.pickerStyle(.segmented).accessibilityIdentifier("idle-message-source")
                if editingCustom {
                    TextEditor(text: $customDraft).font(.body).frame(height: 105)
                        .accessibilityIdentifier("idle-custom-editor")
                    HStack {
                        hint("One phrase per line. Apply to use it only while idle.")
                        Spacer()
                        Button("Apply") { if idle.applyCustom(customDraft) { previewIndex = 0 } }
                            .disabled(draftLines.isEmpty).accessibilityIdentifier("idle-custom-apply")
                    }
                    if draftLines.isEmpty { Text("Add at least one non-empty phrase.").font(.caption).foregroundStyle(.orange) }
                } else {
                    Picker("Speech style", selection: $idle.style) {
                        ForEach(WhaleSpeechStyle.allCases) { Text($0.displayName).tag($0) }
                    }.accessibilityIdentifier("idle-speech-style")
                    hint("Random chatter every 20 seconds; 15 local phrases per style. Tasks, Agent replies and Superchat take priority.")
                }
                HStack {
                    if !previewLines.isEmpty {
                        PetReactionBubble(text: previewLines[previewIndex % previewLines.count])
                    }
                    Spacer()
                }.padding(.vertical, 4)
                    .task {
                        while !Task.isCancelled {
                            do { try await Task.sleep(nanoseconds: UInt64(IdleSpeechRotation.interval * 1_000_000_000)) }
                            catch { return }
                            let count = previewLines.count
                            if count > 1 {
                                let previous = previewIndex % count
                                previewIndex = (0..<count).filter { $0 != previous }.randomElement() ?? previous
                            }
                        }
                    }
            }
            Section {
                DisclosureGroup("Advanced filters") {
                    Picker("Include states", selection: $settings.minStateFilter) {
                        ForEach(MinStateFilter.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    hint("Visible sources affect task rows and public replies; they do not stop session tracking.")
                    ForEach(AgentCatalog.all.filter { $0.kind != .claude }, id: \.kind) { agent in
                        agentSourceToggle(agent)
                        if agent.kind == .dsh {
                            Toggle(isOn: $settings.showDSHTUI) {
                                HStack(spacing: 8) {
                                    Text(verbatim: "DSH TUI")
                                    SourceStatusTag("source.tag.unsupported")
                                }
                            }
                            .accessibilityIdentifier("bubble-dsh-tui")
                            .accessibilityLabel(Text("DSH TUI · " + NSLocalizedString("source.tag.unsupported", comment: "")))
                        }
                    }
                    AOExperimentSettingsRow(settings: settings)
                    // One independent switch for AionUI Teams: default on, never
                    // affected by the per-agent rows above, hides the whole Team.
                    Toggle(isOn: $settings.showAionUiTeams) {
                        HStack(spacing: 8) {
                            Text("AionUI Team")
                            SourceStatusTag("source.tag.maintenanceEnded")
                        }
                    }
                        .accessibilityIdentifier("bubble-aionui-team")
                        .accessibilityLabel(Text("AionUI Team · " + NSLocalizedString("source.tag.maintenanceEnded", comment: "")))
                    ForEach(AgentCatalog.all.filter { $0.kind == .claude }, id: \.kind) { agent in
                        agentSourceToggle(agent)
                    }
                }.accessibilityIdentifier("bubble-advanced-filters")
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .onAppear { customDraft = idle.customLines.joined(separator: "\n"); editingCustom = idle.source == .custom }
        .onChange(of: idle.style) { _ in previewIndex = 0 }
    }
    private func agentSourceToggle(_ agent: AgentIntegration) -> some View {
        Toggle(isOn: Binding(
            get: { !settings.hiddenKinds.contains(agent.kind) },
            set: { show in
                if show { settings.hiddenKinds.remove(agent.kind) }
                else { settings.hiddenKinds.insert(agent.kind) }
            })) {
                HStack(spacing: 8) {
                    Text(agent.displayName)
                    if agent.kind == .claude { SourceStatusTag("source.tag.unmaintained") }
                }
            }
            .accessibilityLabel(Text(agent.displayName + (agent.kind == .claude
                ? " · " + NSLocalizedString("source.tag.unmaintained", comment: "") : "")))
    }
    private func hint(_ key: LocalizedStringKey) -> some View { Text(key).font(.caption).foregroundStyle(.secondary) }
}

/// Shared source-status styling belongs to the stable settings UI; host
/// experiments reuse it without changing source visibility or capabilities.
struct SourceStatusTag: View {
    let title: LocalizedStringKey
    var experimental = false

    init(_ title: LocalizedStringKey, experimental: Bool = false) {
        self.title = title
        self.experimental = experimental
    }

    var body: some View {
        Text(title).font(.caption2.weight(.medium)).fixedSize()
            .foregroundStyle(experimental ? Color.orange : Color.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill((experimental ? Color.orange : Color.secondary).opacity(0.10)))
    }
}
