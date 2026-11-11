import SwiftUI
import AgentPetCore
import UniformTypeIdentifiers

struct PetAnimationSettingsView: View {
    @ObservedObject private var language = AppLanguage.shared
    private let initialPack: ImagePetPack
    @ObservedObject private var library = ImagePetStore.shared
    init(pack: ImagePetPack, library: ImagePetStore = .shared, store: PetAnimationBindingsStore = .shared, removalSelection: PetAnimationRemovalSelection = .init()) {
        initialPack = pack
        _library = ObservedObject(wrappedValue: library)
        _store = ObservedObject(wrappedValue: store)
        _removal = State(initialValue: removalSelection)
    }
    private var pack: ImagePetPack { library.pack(id: initialPack.id) ?? initialPack }
    @State private var importMessage: String?
    @State private var importSuccess: ImportSuccess?
    private struct ImportSuccess: Identifiable {
        let id = UUID()
        let count: Int
    }
    @State private var targeted = false
    @State private var removal = PetAnimationRemovalSelection()
    @State private var pendingRemoval: RemovalRequest?
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var marqueeRect: CGRect?
    private struct RemovalRequest {
        let petID: String
        let key: String
        let ids: Set<String>
    }
    private var importing: Bool { library.importingPetIDs.contains(pack.id) }
    @ObservedObject private var store = PetAnimationBindingsStore.shared
    @ObservedObject private var pet = PetController.shared
    @State private var key = "working"
    @State private var hoveredID: String?
    private let keys = ["idle", "working", "waiting", "success", "failure", "quota", "levelup", "tap", "drag"]
    private var binding: PetAnimationBinding {
        store.bindings(for: pack).byKey[key] ?? .init(clipIDs: [])
    }
    private var indices: [Int] {
        let visible = Set(pack.candidateIDs(for: key) + binding.clipIDs)
        return (0..<pack.clipCount).filter { visible.contains(pack.clipID(at: $0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("pet.animation.purpose", selection: $key) {
                ForEach(keys, id: \.self) { Text(PetAnimationText.group($0)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Text("pet.animation.selectionHelp")
                .font(.caption).foregroundStyle(.secondary)
            if removal.active {
                HStack {
                    Text("Select animations to remove").font(.callout.weight(.medium)).foregroundStyle(.red)
                    Spacer()
                    Button("Cancel") { marqueeRect = nil; removal.exit() }.disabled(importing)
                }
            }
            if removal.active {
                Text("Drag to select a region. Shift-click selects a range; Shift-drag adds to the selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                if removal.active {
                    animationGrid.highPriorityGesture(marqueeGesture)
                } else { animationGrid }
                if let success = importSuccess {
                    PetAnimationImportSuccessNotice(count: success.count)
                } else {
                    Text(LocalizedStringKey(importing ? "pet.animation.importing" : "pet.animation.dropHelp"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if importing { ProgressView().controlSize(.small) }
                HStack {
                    Spacer()
                    if removal.active {
                        Button { requestRemoval(removal.ids) } label: {
                            Image(systemName: "trash").font(.title3).foregroundStyle(.red).padding(7)
                        }
                        .help("Remove selected animations")
                        .accessibilityLabel("Remove selected animations")
                        .disabled(removal.ids.isEmpty || importing)
                    }
                }.frame(height: 36).contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(targeted ? Color.systemAccent.opacity(0.08) : .clear)
            .contextMenu {
                Button("Add") { chooseFiles() }.disabled(importing || removal.active)
                Button { removal.enter() } label: { Text(NSLocalizedString("Animation Remove", comment: "animation management action")) }.disabled(importing)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !importing, !removal.active, !urls.isEmpty else { return false }
                importFiles(urls)
                return true
            } isTargeted: { targeted = $0 }
            if !pack.animationIssues.isEmpty {
                Text(pack.animationIssues.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(.vertical, 4)
        .task(id: initialPack.id) { await library.reloadAnimations(for: initialPack.id) }
        .task(id: importSuccess?.id) {
            guard let success = importSuccess else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if importSuccess?.id == success.id { importSuccess = nil }
        }
        .onChange(of: key) { _ in hoveredID = nil; marqueeRect = nil; removal.exit(); pendingRemoval = nil; importSuccess = nil }
        .onChange(of: initialPack.id) { _ in marqueeRect = nil; removal.exit(); pendingRemoval = nil; importSuccess = nil }
        .onDisappear { marqueeRect = nil; removal.exit(); pendingRemoval = nil; importSuccess = nil }
        .alert("Remove animations?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), presenting: pendingRemoval) { request in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button(role: .destructive) { confirmRemoval(request) } label: { Text(NSLocalizedString("Animation Remove", comment: "animation management action")) }
        } message: { request in
            Text(removalConfirmation(request))
        }
        .background {
            Color.clear.alert("Animations", isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } })) {
                    Button("OK") { importMessage = nil }
                } message: { Text(importMessage ?? "") }
        }
        .environment(\.locale, language.locale)
    }

    private var animationGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 10)], spacing: 10) {
            ForEach(indices, id: \.self) { index in tile(index) }
        }
        .padding(4)
        .coordinateSpace(name: "animationRemovalGrid")
        .contentShape(Rectangle())
        .onPreferenceChange(AnimationTileFramesKey.self) { tileFrames = $0 }
        .overlay(alignment: .topLeading) {
            if let rect = marqueeRect {
                Rectangle().fill(Color.red.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(Color.red, lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("animationRemovalGrid"))
            .onChanged { value in
                guard removal.active, !importing, pendingRemoval == nil else { return }
                if marqueeRect == nil {
                    removal.beginMarquee(additive: (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift))
                    hoveredID = nil
                }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                  y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.startLocation.x - value.location.x),
                                  height: abs(value.startLocation.y - value.location.y))
                marqueeRect = rect
                removal.updateMarquee(intersecting: PetAnimationRemovalSelection.intersectingIDs(rect: rect, frames: tileFrames))
            }
            .onEnded { _ in marqueeRect = nil; removal.endMarquee() }
    }

    private func removalConfirmation(_ request: RemovalRequest) -> String {
        return String(format: NSLocalizedString("Remove %ld animation(s) from “%@”? Other groups and original source files are kept.", comment: ""), request.ids.count, PetAnimationText.group(request.key))
    }

    private func requestRemoval(_ ids: Set<String>) {
        guard !importing else { return }
        do {
            _ = try PetAnimationRemoval.plan(ids: ids, key: key, pack: pack, bindings: store.bindings(for: pack))
            pendingRemoval = .init(petID: pack.id, key: key, ids: ids)
        } catch { importMessage = error.localizedDescription }
    }

    private func confirmRemoval(_ request: RemovalRequest) {
        pendingRemoval = nil
        Task { @MainActor in
            do {
                let warnings = try await library.removeAnimations(request.ids, for: request.petID, key: request.key)
                removal.exit()
                if !warnings.isEmpty { importMessage = warnings.joined(separator: "\n") }
            } catch { importMessage = error.localizedDescription }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Add", comment: "animation file picker")
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK { importFiles(panel.urls) }
        }
    }

    private func importFiles(_ urls: [URL]) {
        let petID = pack.id, group = key
        importSuccess = nil
        Task { @MainActor in
            let result = await library.importAnimations(urls, for: petID, key: group)
            if result.failures.isEmpty, !result.importedIDs.isEmpty {
                if initialPack.id == petID, key == group {
                    importSuccess = .init(count: result.importedIDs.count)
                }
                return
            }
            var message = String(format: NSLocalizedString("pet.animation.importSummary", comment: ""), result.importedIDs.count, PetAnimationText.group(group))
            if !result.failures.isEmpty {
                message += "\n\n" + result.failures.joined(separator: "\n") + "\n\n" + PetAnimationImportError.guidance
            }
            importMessage = message
        }
    }

    private func tile(_ index: Int) -> some View {
        let id = pack.clipID(at: index)
        let selected = removal.active ? removal.ids.contains(id) : binding.clipIDs.contains(id)
        let tint = removal.active ? Color.red : Color.systemAccent
        return Button {
            if removal.active {
                removal.select(id, extendingRange: (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift),
                               orderedIDs: indices.map { pack.clipID(at: $0) })
            } else { toggle(id) }
        } label: {
            VStack(spacing: 5) {
                Group {
                    if hoveredID == id, pet.animationsEnabled {
                        if let video = pack.video(for: id) {
                            PetVideoSpriteView(clip: video).frame(width: 84, height: 54)
                        } else {
                            ImageSpriteView(frames: pack.clip(index), mood: .working,
                                            fps: pet.spriteFPS(forMood: .working), size: 54)
                        }
                    } else {
                        if let image = pack.clip(index).first {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 84, height: 54)
                        } else { Image(systemName: "pawprint.fill").foregroundStyle(.secondary) }
                    }
                }.frame(width: 84, height: 54)
                Text(PetAnimationText.name(pack: pack, index: index)).font(.caption).lineLimit(2)
                    .multilineTextAlignment(.center).frame(height: 32)
            }
            .frame(maxWidth: .infinity).padding(7)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? tint.opacity(0.15) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                selected ? tint : .secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(tint).padding(5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: AnimationTileFramesKey.self,
                value: [id: geometry.frame(in: .named("animationRemovalGrid"))])
        })
        .accessibilityLabel(PetAnimationText.name(pack: pack, index: index))
        .accessibilityValue(removal.active
            ? NSLocalizedString(selected ? "Marked for removal" : "Not marked for removal", comment: "")
            : NSLocalizedString(selected ? "pet.animation.selected" : "pet.animation.notSelected", comment: ""))
        .disabled(importing)
        .contextMenu {
            if !removal.active { Button(role: .destructive) { requestRemoval([id]) } label: { Text(NSLocalizedString("Animation Remove", comment: "animation management action")) }.disabled(importing) }
        }
        .onHover { hoveredID = $0 ? id : (hoveredID == id ? nil : hoveredID) }
    }

    private func toggle(_ id: String) {
        var value = binding
        if !PetAnimationBindings.allowsMultiple(key) { value.clipIDs = [id] }
        else if value.clipIDs.contains(id) {
            if value.clipIDs.count == 1 { return }
            value.clipIDs.removeAll { $0 == id }
        } else { value.clipIDs.append(id) }
        store.set(value, key: key, pack: pack)
    }
}

/// Display-only translations: IDs, manifests, bindings and user names stay intact.
enum PetAnimationText {
    static func group(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: "pet.animation.group." + key, value: key, table: nil)
    }

    static func name(pack: ImagePetPack, index: Int, bundle: Bundle = .main) -> String {
        if index < pack.clips.count {
            return String(format: bundle.localizedString(forKey: "pet.animation.sprite", value: "Sprite clip %ld", table: nil), index + 1)
        }
        let clip = pack.videoClips[index - pack.clips.count]
        let original = clip.displayName ?? clip.name
        // Translate only the shipped DeepSeek names, never imports or custom labels.
        guard pack.id == "deepseek", clip.source == .native, clip.id == "dsh:" + clip.name,
              clip.displayName == nil || clip.displayName == clip.name ||
                (clip.name == "吃Token" && clip.displayName == "吃 Token") else { return original }
        return bundle.localizedString(forKey: "pet.animation.deepseek." + clip.id, value: original, table: nil)
    }
}

/// Inline acknowledgement: no application icon, modal window or action button.
struct PetAnimationImportSuccessNotice: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(String(format: NSLocalizedString("Import successful · %ld", comment: "animation import acknowledgement"), count))
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct AnimationTileFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
