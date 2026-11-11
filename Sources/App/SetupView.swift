import SwiftUI
import AgentPetCore

/// Native macOS-style settings: a preferences-style toolbar of tabs over
/// grouped forms that follow the selected appearance.
struct SetupView: View {
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var imagePets = ImagePetStore.shared
    @ObservedObject private var appLang = AppLanguage.shared
    var onClose: () -> Void
    /// Asks the window to resize to a target content width so the live-preview
    /// panel can slide in on the right. Provided by SettingsWindowController.
    var onResize: (CGFloat) -> Void = { _ in }
    var focusAgentIntegrations = false

    enum Tab { case general, pet, care, bubble, about }
    @State private var tab: Tab = .general
    @State private var demoOpen = false

    private let baseWidth: CGFloat = 640
    private let demoWidth: CGFloat = 740

    private var selectedPack: ImagePetPack? {
        pet.selectedPetID.flatMap { imagePets.pack(id: $0) }
    }

    private func setDemo(_ open: Bool) {
        demoOpen = open
        onResize(open ? baseWidth + demoWidth : baseWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsColumn.frame(width: baseWidth)
            if demoOpen {
                Divider()
                SettingsDemoPanel(onClose: { setDemo(false) }).frame(width: demoWidth)
            }
        }
        .frame(width: demoOpen ? baseWidth + demoWidth : baseWidth, height: 600)
        .background(Theme.background)
        .appAppearance()
        .noFocusRing()
        .environment(\.locale, appLang.locale)
        .id(appLang.lang.rawValue)   // recreate the tree so every Text re-resolves on language change
        .onAppear { model.refreshAsync() }
        .onChange(of: tab) { selected in
            if selected != .bubble && demoOpen { setDemo(false) }
        }
    }

    private var settingsColumn: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .general:
                    GeneralTab(model: model, pet: pet, focusAgentIntegrations: focusAgentIntegrations)
                case .pet:
                    PetTab(pet: pet, imagePets: imagePets, model: model, selectedPack: selectedPack)
                case .care:
                    CareTabView()
                case .bubble:
                    BubbleSettingsView(isPreviewOpen: demoOpen, onTogglePreview: { setDemo(!demoOpen) })
                case .about:
                    AboutTabView()
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            TabButton(icon: "gearshape.fill", label: "General", selected: tab == .general) { tab = .general }
            TabButton(icon: "pawprint.fill", label: "Pet", selected: tab == .pet) { tab = .pet }
            TabButton(icon: "fork.knife", label: "Care", selected: tab == .care) { tab = .care }
            TabButton(icon: "bubble.left.and.bubble.right.fill", label: "Bubble", selected: tab == .bubble) { tab = .bubble }
            TabButton(icon: "heart.fill", label: "About", selected: tab == .about) { tab = .about }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

private struct TabButton: View {
    let icon: String
    let label: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19))
                Text(label).font(.system(size: 11))
            }
            .frame(width: 78, height: 48)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.systemAccent.opacity(0.22) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.systemAccent.opacity(0.55) : .clear, lineWidth: 1))
            .foregroundStyle(selected ? Color.systemAccent : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SoundRow: View {
    let title: LocalizedStringKey
    @Binding var enabled: Bool
    let customPath: String
    let onPlay: () -> Void
    let onUpload: () -> Void
    let onReset: () -> Void

    private var sourceLabel: String {
        customPath.isEmpty ? "Default" : (customPath as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                ColorSwitch(isOn: $enabled)
            }
            HStack(spacing: 8) {
                Text(sourceLabel)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { onPlay() } label: { Image(systemName: "play.circle") }.buttonStyle(.plain)
                Button("Upload…") { onUpload() }.controlSize(.small)
                if !customPath.isEmpty {
                    Button("Default") { onReset() }.controlSize(.small)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
    }
}

// MARK: - General (merged setup + general)

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var pet: PetController
    var focusAgentIntegrations = false
    @ObservedObject private var sound = SoundSettings.shared
    @ObservedObject private var appLang = AppLanguage.shared
    @ObservedObject private var statusBar = StatusBarController.shared
    @ObservedObject private var bubble = BubbleSettings.shared
    @ObservedObject private var petWindow = PetWindowController.shared
    @ObservedObject private var imagePets = ImagePetStore.shared
    // Local mirror of the system login-item state so the toggle re-renders
    // reliably (the SMAppService status isn't observable on its own).
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var integrationHelp: AgentIntegrationHelpSelection?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section("Language") {
                    Picker("Language", selection: $appLang.lang) {
                        ForEach(AppLanguage.Lang.allCases) { l in
                            Text(l.label).tag(l)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Application appearance") {
                    Picker("Theme", selection: $bubble.theme) {
                        ForEach(BubbleSettings.Theme.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)
                }

                Section("Launch") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at login")
                            Text("AgentPet Lite starts automatically when you sign in.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ColorSwitch(isOn: Binding(
                            get: { launchAtLogin },
                            set: { newValue in
                                LoginItem.setEnabled(newValue)
                                launchAtLogin = LoginItem.isEnabled
                            }))
    }
                }

                Section("Menu bar") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide AgentPet Lite menu bar icon")
                            Text("You can show the icon again here or open Settings from the pet's Status panel.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ColorSwitch(isOn: $statusBar.menuBarHidden)
                            .accessibilityIdentifier("settings-hide-menu-bar")
                    }
                    HStack {
                        Text("Show chat on menu bar")
                        Spacer()
                        ColorSwitch(isOn: $statusBar.showChatOnMenuBar)
                    }
                }

                Section("Pet display") {
                    HStack {
                        Text("Show pet"); Spacer(); ColorSwitch(isOn: $petWindow.isVisible)
                    }
                    HStack(spacing: 8) {
                        Text("Pet size")
                        Slider(value: $pet.petPoint, in: PetController.minPoint...PetController.maxPoint)
                            .accessibilityIdentifier("pet-size")
                        Text("\(Int(pet.petPoint))").monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        ForEach(PetController.presets, id: \.0) { preset in
                            Button(preset.0) { pet.animateSize(to: preset.1) }.buttonStyle(.bordered)
                        }
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Animation effects")
                            Text("Pet motion and related bubble/clock effects. Tasks, alerts and countdowns continue when off.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); ColorSwitch(isOn: $pet.animationsEnabled)
                    }
                    if let pack = pet.selectedPetID.flatMap({ imagePets.pack(id: $0) }), !pack.clips.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sprite animation speed")
                                Text("Sprite clips only; idle is capped at 2 fps. Videos play at their original speed.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Slider(value: $pet.animationFPS, in: 1...12, step: 1).frame(width: 120)
                            Text("\(Int(pet.animationFPS)) fps").monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        }.disabled(!pet.animationsEnabled)
                    }
                    Picker("Bubble font size", selection: $bubble.fontSize) {
                        Text("S").tag(BubbleSettings.FontSize.small)
                        Text("M").tag(BubbleSettings.FontSize.medium)
                        Text("L").tag(BubbleSettings.FontSize.large)
                    }.pickerStyle(.segmented).accessibilityIdentifier("bubble-font-size")
                    opacityRow("Bubble background opacity", value: $bubble.opacity, range: BubbleSettings.opacityRange, id: "bubble-opacity")
                    opacityRow("Bubble text opacity", value: $bubble.textOpacity, range: BubbleSettings.textOpacityRange, id: "bubble-text-opacity")
                    Text("Text opacity affects bubble text and Agent prefixes only. Icons, status lights and progress bars keep their colors.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Show idle message"); Spacer(); ColorSwitch(isOn: $pet.showIdleMessage)
                    }
                }

                Section("Notifications") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notificationTitle)
                            Text(notificationDetail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        notificationButton
                    }
                }

                Section("Sounds") {
                    SoundRow(title: "When an agent finishes",
                             enabled: $sound.doneEnabled,
                             customPath: sound.doneCustomPath,
                             onPlay: { sound.play(.done) },
                             onUpload: { sound.upload(for: .done) },
                             onReset: { sound.resetToDefault(.done) })
                    SoundRow(title: "When an agent needs input",
                             enabled: $sound.waitingEnabled,
                             customPath: sound.waitingCustomPath,
                             onPlay: { sound.play(.waiting) },
                             onUpload: { sound.upload(for: .waiting) },
                             onReset: { sound.resetToDefault(.waiting) })
                }

                Section("Agent integrations") {
                    VStack(spacing: 8) {
                        ForEach(model.agents) { agent in
                            AgentIntegrationCard(agent: agent, model: model) {
                                integrationHelp = .init(kind: agent.kind)
                            }
                        }
                    }
                    if let err = model.installError {
                        Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if model.integrationNotice != nil {
                        Text("操作已完成。接入说明见对应的ⓘ。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Refresh") { model.refreshAsync() }.disabled(model.inspectingIntegrations || !model.busyIntegrations.isEmpty)
                }
                .id("agent-integrations")

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                }

                Section {
                    Button("Quit AgentPet Lite") { NSApplication.shared.terminate(nil) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .sheet(item: $integrationHelp) { selection in
                AgentIntegrationHelpView(kind: selection.kind, inspection: model.integrationStates[selection.kind],
                                         conflict: model.integrationConflicts[selection.kind], model: model)
            }
            .task {
                if focusAgentIntegrations {
                    await Task.yield()
                    proxy.scrollTo("agent-integrations", anchor: .top)
                }
            }

        }
    }



    private func opacityRow(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, id: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: 0.05).accessibilityIdentifier(id)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var notificationTitle: String {
        switch model.notificationState {
        case .enabled: return model.notificationsEnabled ? NSLocalizedString("Notifications on", comment: "") : NSLocalizedString("Notifications muted", comment: "")
        case .denied: return NSLocalizedString("Notifications denied", comment: "")
        case .unavailable: return NSLocalizedString("Notifications unavailable", comment: "")
        case .notDetermined: return NSLocalizedString("Enable notifications", comment: "")
        }
    }

    private var notificationDetail: String {
        switch model.notificationState {
        case .unavailable: return NSLocalizedString("Available once installed as AgentPet Lite.app", comment: "")
        case .denied: return NSLocalizedString("Turn on in System Settings to get alerts", comment: "")
        case .enabled: return model.notificationsEnabled
            ? NSLocalizedString("Alerts when an agent finishes or needs input", comment: "")
            : NSLocalizedString("Muted, the toggle turns alerts back on", comment: "")
        case .notDetermined: return NSLocalizedString("Alerts when an agent finishes or needs input", comment: "")
        }
    }

    @ViewBuilder private var notificationButton: some View {
        switch model.notificationState {
        case .enabled:
            // Permission granted: an in-app toggle lets the user mute without
            // revoking the system permission.
            ColorSwitch(isOn: $model.notificationsEnabled)
        case .denied:
            Button("Open Settings") { model.openSystemNotificationSettings() }
        case .notDetermined:
            Button("Enable") { model.enableNotifications() }
        case .unavailable:
            EmptyView()
        }
    }
}

// MARK: - Pet tab

struct PetTab: View {
    @ObservedObject var pet: PetController
    @ObservedObject var imagePets: ImagePetStore
    @ObservedObject var model: SettingsModel
    let selectedPack: ImagePetPack?
    @ObservedObject private var projectSettings = ProjectPetSettings.shared
    @State private var browsing = false
    @State private var creating = false
    @State private var petQuery = ""

    private enum PetSlot: Hashable {
        case defaultPet
        case project(String)
    }
    @State private var selectedSlot: PetSlot = .defaultPet

    private var selectedSlotPetID: String? {
        switch selectedSlot {
        case .defaultPet: return pet.selectedPetID
        case .project(let path): return projectSettings.petID(forProject: path)
        }
    }

    private var selectedSlotPack: ImagePetPack? {
        selectedSlotPetID.flatMap { imagePets.pack(id: $0) }
    }

    private var filteredPacks: [ImagePetPack] {
        guard !petQuery.isEmpty else { return imagePets.packs }
        let q = petQuery.lowercased()
        return imagePets.packs.filter { $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        Form {
            // Hero card for selected slot
            Section {
                heroCard
            }

            if pet.splitPet {
                Section {
                    HStack {
                        Picker("Pet assignment", selection: $selectedSlot) {
                            Text("Default").tag(PetSlot.defaultPet)
                            ForEach(projectSettings.mappings, id: \.projectPath) { mapping in
                                Text((mapping.projectPath as NSString).lastPathComponent).tag(PetSlot.project(mapping.projectPath))
                            }
                        }
                        Button("Add project…") { addProject() }
                    }
                }
            }

            // Config panel for selected slot
            configPanel
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onChange(of: pet.splitPet) { _ in
            if !pet.splitPet, case .project = selectedSlot {
                selectedSlot = .defaultPet
            }
        }
        .onChange(of: projectSettings.mappings) { _ in
            if case .project(let path) = selectedSlot,
               !projectSettings.mappings.contains(where: { $0.projectPath == path }) {
                selectedSlot = .defaultPet
            }
        }
        .sheet(isPresented: $browsing) { BrowsePetsView(onClose: { browsing = false }) }
        .sheet(isPresented: $creating) {
            CreatePetView(onCreate: { id in creating = false; imagePets.reload(); pet.selectedPetID = id },
                          onCancel: { creating = false })
        }
    }

    // MARK: - Hero card

    @ViewBuilder private var heroCard: some View {
        HStack(spacing: 14) {
            slotPetPreview
                .frame(width: 84, height: 84)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
            VStack(alignment: .leading, spacing: 4) {
                switch selectedSlot {
                case .defaultPet:
                    HStack(spacing: 8) {
                        Text(imagePets.displayName(for: pet.selectedPetID))
                            .font(.title3.weight(.semibold))
                        if let pack = selectedPack {
                            levelBadge(for: pack.id)
                        }
                    }
                    if let desc = selectedPack?.description {
                        Text(desc).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .project(let path):
                    Text((path as NSString).lastPathComponent)
                        .font(.title3.weight(.semibold))
                    if let pack = selectedSlotPack {
                        HStack(spacing: 8) {
                            Text(pack.displayName).font(.callout).foregroundStyle(.secondary)
                            levelBadge(for: pack.id)
                        }
                    }
                    Text(path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
        }
    }

    // MARK: - Config panel (switches on selected slot)

    @ViewBuilder private var configPanel: some View {
        switch selectedSlot {
        case .defaultPet:
            defaultPetConfig
        case .project(let path):
            projectPetConfig(path: path)
        }
    }

    @ViewBuilder private var defaultPetConfig: some View {
        Section("Choose pet") {
            Text("Different pets come with different animations. When a purpose has no dedicated animation, this pet’s default animation is used. You can adjust or import animations in Animations.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(imagePets.loadingIssues, id: \.self) { issue in
                Text(issue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if imagePets.packs.isEmpty {
                Text("No pets yet. Tap Browse to add one.").foregroundStyle(.secondary)
            } else {
                if imagePets.packs.count > 4 {
                    NativeSearchField(text: $petQuery, placeholder: "Search your pets")
                }
                PetPager(packs: filteredPacks, selectedID: pet.selectedPetID,
                         onSelect: { pet.selectedPetID = $0 },
                         onDelete: { pack in
                             let wasSelected = pet.selectedPetID == pack.id
                             imagePets.delete(pack)
                             if wasSelected { pet.selectedPetID = imagePets.packs.first?.id }
                         })
            }
            HStack {
                Button { browsing = true } label: {
                    Label("Browse pets…", systemImage: "square.grid.2x2")
                }
                Button { creating = true } label: {
                    Label("Create pet…", systemImage: "square.and.pencil")
                }
            }
        }

        if let pack = selectedPack {
            Section("Animations") {
                PetAnimationSettingsView(pack: pack)
            }
        }


    }

    @ViewBuilder private func projectPetConfig(path: String) -> some View {
        Section("Choose pet") {
            Text("Different pets come with different animations. When a purpose has no dedicated animation, this pet’s default animation is used. You can adjust or import animations in Animations.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(imagePets.loadingIssues, id: \.self) { issue in
                Text(issue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if imagePets.packs.isEmpty {
                Text("No pets installed.").foregroundStyle(.secondary)
            } else {
                PetPager(packs: imagePets.packs,
                         selectedID: projectSettings.petID(forProject: path),
                         onSelect: { projectSettings.setPet(projectPath: path, petID: $0) })
            }
        }

        if let pack = selectedSlotPack {
            Section("Animations") {
                PetAnimationSettingsView(pack: pack)
            }
        }

        Section {
            Button(role: .destructive) {
                projectSettings.remove(projectPath: path)
            } label: {
                Label("Remove project", systemImage: "trash")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder private var slotPetPreview: some View {
        if let pack = selectedSlotPack {
            ImageSpriteView(frames: pack.clip(0), mood: .idle,
                            fps: pet.spriteFPS(forMood: .idle), size: 78)
        } else {
            Image(systemName: "pawprint.fill").font(.system(size: 40)).foregroundStyle(.secondary)
        }
    }

    private func levelBadge(for packID: String) -> some View {
        Text(verbatim: "Lv \(PetCare.displayLevel(forXP: PetCareController.shared.states[packID]?.xp ?? 0))")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.systemAccent.opacity(0.2)))
            .foregroundStyle(Color.systemAccent)
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let petID = pet.selectedPetID ?? imagePets.packs.first?.id ?? ""
        guard !petID.isEmpty else { return }
        projectSettings.setPet(projectPath: url.path, petID: petID)
    }
}

// MARK: - Components

/// A single static sprite frame (no TimelineView), for grids where animating
/// every cell would be janky. Only the hero preview animates.
private struct StaticFrame: View {
    let image: NSImage?
    var size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "pawprint.fill").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct PetPager: View {
    let packs: [ImagePetPack]
    let selectedID: String?
    let onSelect: (String) -> Void
    var onDelete: ((ImagePetPack) -> Void)? = nil
    @State private var page = 0

    private let perPage = 8

    var body: some View {
        let pageCount = max(1, Int(ceil(Double(packs.count) / Double(perPage))))
        let current = min(page, pageCount - 1)

        VStack(spacing: 10) {
            GeometryReader { geo in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<pageCount, id: \.self) { p in
                        grid(for: p).frame(width: geo.size.width, alignment: .top)
                    }
                }
                .offset(x: -CGFloat(current) * geo.size.width)
                .animation(.easeInOut(duration: 0.28), value: current)
            }
            .frame(height: packs.count <= 4 ? 88 : 188)
            .clipped()

            if pageCount > 1 {
                HStack(spacing: 14) {
                    arrow("chevron.left", enabled: current > 0) { page = max(0, current - 1) }
                    HStack(spacing: 5) {
                        ForEach(0..<pageCount, id: \.self) { i in
                            Circle()
                                .fill(i == current ? Color.systemAccent : .secondary.opacity(0.4))
                                .frame(width: 6, height: 6)
                        }
                    }
                    arrow("chevron.right", enabled: current < pageCount - 1) { page = min(pageCount - 1, current + 1) }
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: packs.count) { _ in page = 0 }
    }

    private func grid(for pageIndex: Int) -> some View {
        let slice = Array(packs.dropFirst(pageIndex * perPage).prefix(perPage))
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 12, alignment: .leading), count: 4),
                         alignment: .leading, spacing: 12) {
            ForEach(slice) { pack in
                PetThumb(pack: pack, selected: selectedID == pack.id,
                         select: { onSelect(pack.id) },
                         onDelete: onDelete.map { d in { d(pack) } })
            }
        }
    }

    private func arrow(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
        .disabled(!enabled)
    }
}

private struct PetThumb: View {
    let pack: ImagePetPack
    let selected: Bool
    let select: () -> Void
    var onDelete: (() -> Void)? = nil
    @State private var hovering = false

    /// This companion's display level; a never-raised pet reads as Lv 0.
    private var level: Int {
        PetCare.displayLevel(forXP: PetCareController.shared.states[pack.id]?.xp ?? 0)
    }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                StaticFrame(image: pack.clip(0).first, size: 48)
                    .frame(width: 56, height: 48)
                Text(pack.displayName).font(.caption).lineLimit(1).frame(width: 64)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.systemAccent.opacity(0.2) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.systemAccent : .secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            Text(verbatim: "Lv \(level)")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(level > 0 ? Color.systemAccent.opacity(0.85) : Color.secondary.opacity(0.45)))
                .foregroundStyle(.white)
                .offset(x: -3, y: -3)
        }
        .overlay(alignment: .topTrailing) {
            if hovering, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovering = $0 }
    }
}
