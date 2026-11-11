import Foundation
import CryptoKit

/// First-run media installation only. All preferences and care data stay in the
/// user's existing stores; installed packs and explicit choices are never replaced.
enum BundledDefaultPet {
    static let installedKey = "agentpet.bundledDefaultPet.v1"
    static let petID = "deepseek"
    static let clipCount = 33
    enum Outcome: Equatable { case installed(String), preserved, skipped }
    enum InstallError: Error { case missingResource, invalidPack }

    /// Media files that R2 needs on already-installed default packs. Values are
    /// the explicit old/new SHA256 hashes; a user-modified file is never
    /// overwritten. Metadata (`pet.json`, animations.json, bindings, care) is
    /// deliberately not in this list.
    struct MediaFile: Equatable {
        let path: String
        let oldSHA256: String?
        let newSHA256: String
    }

    static let managedMediaFiles: [MediaFile] = [
        .init(path: "videos/被鼠标拖拽悬空反馈.mov",
              oldSHA256: "d6e9a7f0842f186ba0e577c330c57a121b86c4db5216d0834bb9a4aadfcaf405",
              newSHA256: "f0bebf295e78bfcf57c808f299b85323f2f5fa29274c604774557c5823d6e2e3"),
        .init(path: "posters/被鼠标拖拽悬空反馈.png",
              oldSHA256: "b65d3f782e7ccbc280d946ff5d03370c2303e45a4b7492087cd561e74a0add52",
              newSHA256: "ff6b73a2b4c787cca87ee28a18fed54cbed609b00567ad30bbd03315d7ef27a2"),
        .init(path: "edge-peek.png", oldSHA256: nil,
              newSHA256: "404099c2922566557c3e2a8826bf1f60ca53388b4798636721891970440d8067"),
    ]

    struct MediaRefreshReport: Equatable {
        var updated: [String] = []
        var unchanged: [String] = []
        /// Existing files that are neither the known old nor the new hash.
        var blocked: [String] = []
        /// Missing/bad source or I/O failure; retried on the next launch.
        var failed: [String] = []
        var skipped = false
    }

    static var resourceDirectory: URL? {
        resourceDirectory(in: .main)
    }

    static func resourceDirectory(in application: Bundle) -> URL? {
        let resources = AppResources.bundle(in: application)
        let directory = resources?.resourceURL?
            .appendingPathComponent("DefaultPets", isDirectory: true)
            .appendingPathComponent(petID, isDirectory: true)
        guard let directory, FileManager.default.fileExists(atPath: directory.appendingPathComponent("pet.json").path) else {
            return nil
        }
        return directory
    }

    /// The caller selects the returned id only after a complete atomic install.
    /// A failed or interrupted attempt does not consume the first-run marker.
    static func installIfNeeded(resourceDirectory: URL?, petsDirectory: URL,
                                selectedPetID: String?, defaults: UserDefaults) throws -> Outcome {
        guard !defaults.bool(forKey: installedKey) else { return .skipped }
        if selectedPetID != nil {
            defaults.set(true, forKey: installedKey)
            return .preserved
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: petsDirectory.path) {
            let entries = try fm.contentsOfDirectory(at: petsDirectory, includingPropertiesForKeys: nil)
            // Preserve even unrecognised user files. Hidden staging directories
            // from an interrupted attempt are not treated as installed pets.
            if entries.contains(where: { !$0.lastPathComponent.hasPrefix(".") }) {
                defaults.set(true, forKey: installedKey)
                return .preserved
            }
        }
        guard let source = resourceDirectory,
              fm.fileExists(atPath: source.appendingPathComponent("pet.json").path) else {
            throw InstallError.missingResource
        }
        try fm.createDirectory(at: petsDirectory, withIntermediateDirectories: true)
        let staging = petsDirectory.appendingPathComponent(".bundled-default-\(UUID().uuidString)", isDirectory: true)
        // copyItem/moveItem reject existing destinations; no replacement API is used.
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        guard let pack = SpriteSlicer.loadPack(directory: staging), pack.id == petID,
              pack.clips.count == 1, pack.clips.first?.count == 1,
              pack.videoClips.count == clipCount,
              pack.videoClips.allSatisfy({ $0.poster != nil }),
              Set(pack.videoClips.flatMap(\.purposes)) == PetAnimationBindings.selectionKeys else {
            throw InstallError.invalidPack
        }
        let destination = petsDirectory.appendingPathComponent(petID, isDirectory: true)
        try fm.moveItem(at: staging, to: destination)
        defaults.set(true, forKey: installedKey)
        return .installed(petID)
    }

    /// Reconciles only the fixed default pack's R2 media. This runs before the
    /// library loads on launch, so an installed whale starts using the new drag
    /// movie and optional peek art without replacing the whole pack. Existing
    /// metadata, bindings, care data and unrelated/user files are untouched.
    /// Every file is checked by hash on every launch: a partial failure is
    /// retried, while a user-modified file is reported blocked and preserved.
    static func refreshMediaIfNeeded(resourceDirectory: URL?, petsDirectory: URL,
                                     files: [MediaFile] = managedMediaFiles) -> MediaRefreshReport {
        var report = MediaRefreshReport()
        let fm = FileManager.default
        let packDirectory = petsDirectory.appendingPathComponent(petID, isDirectory: true)
        guard let resourceDirectory,
              fm.fileExists(atPath: packDirectory.appendingPathComponent("pet.json").path),
              let manifest = try? Data(contentsOf: packDirectory.appendingPathComponent("pet.json")),
              let manifestObject = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any],
              manifestObject["id"] as? String == petID,
              isRealDirectory(packDirectory) else {
            report.skipped = true
            return report
        }
        let resourceRoot = resourceDirectory.resolvingSymlinksInPath().standardizedFileURL
        let packRoot = packDirectory.resolvingSymlinksInPath().standardizedFileURL
        for file in files {
            let source = resourceRoot.appendingPathComponent(file.path).standardizedFileURL
            let destination = packRoot.appendingPathComponent(file.path).standardizedFileURL
            guard source.path.hasPrefix(resourceRoot.path + "/"),
                  destination.path.hasPrefix(packRoot.path + "/"),
                  !isSymbolicLink(source), !isSymbolicLink(destination),
                  !hasSymlinkParent(source, root: resourceRoot),
                  !hasSymlinkParent(destination, root: packRoot),
                  let sourceHash = sha256(source), sourceHash == file.newSHA256 else {
                report.failed.append(file.path)
                continue
            }
            if fm.fileExists(atPath: destination.path) {
                guard let destinationHash = sha256(destination) else {
                    report.failed.append(file.path)
                    continue
                }
                if destinationHash == file.newSHA256 {
                    report.unchanged.append(file.path)
                    continue
                }
                guard let old = file.oldSHA256, destinationHash == old else {
                    // The user (or another tool) changed this file: preserve it.
                    report.blocked.append(file.path)
                    continue
                }
            }
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                guard let data = try? Data(contentsOf: source) else {
                    report.failed.append(file.path)
                    continue
                }
                try data.write(to: destination, options: .atomic)
                guard sha256(destination) == file.newSHA256 else {
                    report.failed.append(file.path)
                    continue
                }
                report.updated.append(file.path)
            } catch {
                report.failed.append(file.path)
            }
        }
        return report
    }

    private static func sha256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Checks every intermediate directory between the pack root and the file.
    /// A symlinked `videos/` must not redirect the atomic write outside the pack.
    private static func hasSymlinkParent(_ url: URL, root: URL) -> Bool {
        var current = url.deletingLastPathComponent()
        while current.path != root.path, current.path.hasPrefix(root.path + "/") {
            if isSymbolicLink(current) { return true }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return false
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
