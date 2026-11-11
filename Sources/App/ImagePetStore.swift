import AppKit
import AgentPetCore

/// Loads and imports spritesheet pet packs from `~/.agentpet/pets/`.
@MainActor
final class ImagePetStore: ObservableObject {
    static let shared = ImagePetStore()

    @Published private(set) var packs: [ImagePetPack] = []
    @Published private(set) var loadingIssues: [String] = []
    @Published private(set) var importingPetIDs = Set<String>()

    /// User-chosen names per pet id, overriding the pack's catalog name (#31).
    @Published private(set) var nameOverrides: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "agentpet.petNames") as? [String: String]) ?? [:]

    private let directoryOverride: URL?
    private let animationBindings: PetAnimationBindingsStore
    init(petsDirectory: URL? = nil, bindingsStore: PetAnimationBindingsStore = .shared) {
        directoryOverride = petsDirectory
        animationBindings = bindingsStore
    }

    private var mediaRefreshes: [String: UInt64] = [:]

    private var petsDir: URL {
        directoryOverride ?? URL(fileURLWithPath: AgentPetPaths.baseDir).appendingPathComponent("pets")
    }

    func pack(id: String) -> ImagePetPack? {
        packs.first { $0.id == id }
    }

    /// The name to show for a pet: the user's custom name, else the pack's
    /// catalog name, else the id. One place so every surface agrees.
    func displayName(for id: String?) -> String {
        guard let id else { return NSLocalizedString("Your pet", comment: "") }
        if let custom = nameOverrides[id], !custom.isEmpty { return custom }
        return pack(id: id)?.displayName ?? id
    }

    /// Renames a pet (empty/blank clears the override back to the catalog name).
    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == pack(id: id)?.displayName {
            nameOverrides.removeValue(forKey: id)
        } else {
            nameOverrides[id] = String(trimmed.prefix(40))
        }
        UserDefaults.standard.set(nameOverrides, forKey: "agentpet.petNames")
    }

    /// Deletes an installed pet's folder from disk. Drops it from the in-memory
    /// list directly instead of a full `reload()`: reload re-slices every other
    /// pack's spritesheet on the main actor (heavy pixel-scan per sheet), which
    /// froze the UI when deleting with many pets installed.
    func delete(_ pack: ImagePetPack) {
        try? FileManager.default.removeItem(at: pack.directory)
        packs.removeAll { $0.id == pack.id }
    }

    /// Full synchronous reload. Used after importing a pet, where slicing every
    /// pack up front is acceptable; launch uses `loadFast` to stay responsive.
    func reload() {
        let loaded = Self.loadDirectories(Self.directories(in: petsDir))
        packs = loaded.packs.sorted { $0.displayName < $1.displayName }
        loadingIssues = loaded.issues
    }

    /// Media-only updates reuse decoded sprites and refresh just this pet.
    func reloadAnimations(for id: String) async {
        guard let index = packs.firstIndex(where: { $0.id == id }) else { return }
        let revision = (mediaRefreshes[id] ?? 0) &+ 1
        mediaRefreshes[id] = revision
        let input = UncheckedSendableBox(packs[index])
        let output = await Task.detached(priority: .userInitiated) {
            var updated = input.value
            updated.loadAnimations()
            updated.peekAsset = EdgePeekAsset.load(directory: updated.directory)
            return UncheckedSendableBox(updated)
        }.value
        guard mediaRefreshes[id] == revision,
              let current = packs.firstIndex(where: { $0.id == id }),
              packs[current].directory == output.value.directory else { return }
        var updated = output.value
        updated.animationRevision = packs[current].animationRevision &+ 1
        packs[current] = updated
    }

    func importAnimations(_ urls: [URL], for id: String, key: String) async -> PetAnimationLibrary.ImportResult {
        guard let pack = pack(id: id), !importingPetIDs.contains(id) else {
            return .init(failures: ["该宠物正在导入，或已不可用。"])
        }
        importingPetIDs.insert(id)
        defer { importingPetIDs.remove(id) }
        let bindings = animationBindings.bindings(for: pack)
        let groups = PetAnimationRemoval.groups(pack: pack, bindings: bindings)
        let directory = pack.directory
        let count = pack.videoClips.filter { $0.source == .native }.count
        let result = await Task.detached(priority: .userInitiated) {
            PetAnimationLibrary.importFiles(urls, directory: directory, key: key, seedGroups: groups, nativeCount: count)
        }.value
        await reloadAnimations(for: id)
        return result
    }

    func removeAnimations(_ ids: Set<String>, for id: String, key: String) async throws -> [String] {
        guard let pack = pack(id: id), !importingPetIDs.contains(id) else {
            throw PetAnimationImportError(reason: NSLocalizedString("This pet is busy. Try again when the current operation finishes.", comment: ""))
        }
        importingPetIDs.insert(id)
        defer { importingPetIDs.remove(id) }
        let bindings = animationBindings.bindings(for: pack)
        let input = UncheckedSendableBox(pack)
        let result = try await Task.detached(priority: .userInitiated) {
            guard let fresh = SpriteSlicer.loadPack(directory: input.value.directory), fresh.id == id else {
                throw PetAnimationImportError(reason: NSLocalizedString("The pet has no valid native fallback. Repair its pack before removing animations.", comment: ""))
            }
            return try PetAnimationLibrary.remove(ids: ids, key: key, pack: fresh, bindings: bindings)
        }.value
        await reloadAnimations(for: id)
        if let updated = self.pack(id: id) { animationBindings.set(result.binding, key: key, pack: updated) }
        return result.warnings
    }

    /// Launch path: slice only the prioritised pack synchronously so the pet and
    /// menu bar can appear immediately, then slice the remaining packs OFF the
    /// main thread and publish once. Slicing on the main actor (even chunked)
    /// starved the pet's frame timer at launch — the animation crawled until the
    /// library finished loading. Decoding happens on a background queue; only the
    /// finished, immutable packs are handed back to the main actor.
    func loadFast(priorityID: String?) {
        let dirs = Self.directories(in: petsDir)
        let priorityDir = priorityID
            .flatMap { pid in dirs.first { SpriteSlicer.manifestID(directory: $0) == pid } }
            ?? dirs.first
        let first = Self.loadDirectories(priorityDir.map { [$0] } ?? [], includeAnimations: false)
        packs = first.packs
        loadingIssues = first.issues
        if let id = first.packs.first?.id { Task { await reloadAnimations(for: id) } }
        let rest = dirs.filter { $0 != priorityDir }
        guard !rest.isEmpty else { return }
        Task.detached(priority: .utility) {
            let more = Self.loadDirectories(rest)
            let box = UncheckedSendableBox(more.packs)
            let issues = more.issues
            await MainActor.run {
                // Keep the already-shown priority pack, add the rest, sort once.
                self.packs = (self.packs + box.value).sorted { $0.displayName < $1.displayName }
                self.loadingIssues += issues
            }
        }
    }

    nonisolated private static func loadDirectories(_ directories: [URL], includeAnimations: Bool = true) -> (packs: [ImagePetPack], issues: [String]) {
        var packs: [ImagePetPack] = [], issues: [String] = []
        for directory in directories {
            if let pack = SpriteSlicer.loadPack(directory: directory, includeAnimations: includeAnimations) { packs.append(pack) }
            else { issues.append("宠物“\(directory.lastPathComponent)”无法加载：配置或原生回退素材无效，请修复宠物包后重试。") }
        }
        return (packs, issues)
    }

    private static func directories(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries.filter {
            !$0.lastPathComponent.hasPrefix(".") &&
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}

/// Carries a non-Sendable payload (sliced `ImagePetPack`s hold `NSImage`s) from
/// a background slicing task to the main actor. Safe because the packs are
/// immutable and built fresh off-thread, then only read on the main actor.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
