import Foundation
import AppKit

/// Per-pet ownership and membership, separate from v2 playback preferences.
/// An explicit group is authoritative, so later removals never re-seed it.
enum PetAnimationLibrary {
    static let filename = "animation-library.json"
    private struct Header: Decodable { let version: Int }
    struct Document: Codable, Sendable {
        var version = 1
        var assets: [PetAnimationCatalog.Entry] = []
        var groups: [String: [String]] = [:]
    }
    struct Loaded {
        var clips: [PetVideoClip] = []
        var groups: [String: [String]] = [:]
        var issues: [String] = []
    }
    struct ImportResult: Sendable {
        var importedIDs: [String] = []
        var failures: [String] = []
    }

    static func load(directory: URL, nativeIDs: Set<String>) -> Loaded {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) else { return Loaded() }
        do {
            let root = try readRoot(directory)
            let rows = root["assets"] as! [Any]
            var result = Loaded(groups: root["groups"] as? [String: [String]] ?? [:])
            var ids = nativeIDs
            for (index, row) in rows.enumerated() {
                do {
                    let entry = try JSONDecoder().decode(PetAnimationCatalog.Entry.self, from: JSONSerialization.data(withJSONObject: row, options: [.fragmentsAllowed]))
                    try validateOwnership(entry)
                    guard !ids.contains(entry.id) else { throw invalid("重复素材 ID。") }
                    let clip = try PetAnimationCatalog.resolve(entry, directory: directory, source: .imported)
                    ids.insert(entry.id); result.clips.append(clip)
                } catch { result.issues.append("自定义动画第 \(index + 1) 项：\(error.localizedDescription)") }
            }
            return result
        } catch { return Loaded(issues: ["自定义动画清单不可用，使用原生素材：\(error.localizedDescription)"]) }
    }

    /// Caller serializes mutations for a pet. Each successful file is committed
    /// independently; failed files never roll back earlier successes.
    static func importFiles(_ urls: [URL], directory: URL, key: String,
                            seedGroups: [String: [String]], nativeCount: Int) -> ImportResult {
        var result = ImportResult()
        guard PetAnimationBindings.selectionKeys.contains(key) else { return ImportResult(failures: ["未知用途。 "]) }
        var document: Document
        do {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) {
                _ = try readRoot(directory)
                // Do not silently rewrite a damaged or newer document on import.
                document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: directory.appendingPathComponent(filename)))
                for entry in document.assets { try validateOwnership(entry) }
            } else { document = Document(groups: seedGroups) }
        } catch { return ImportResult(failures: ["导入未写入：现有自定义清单需要修复。\(error.localizedDescription)"]) }
        for (group, ids) in seedGroups where document.groups[group] == nil { document.groups[group] = ids }
        let fm = FileManager.default
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var ownedDirectory: URL?
            do {
                guard nativeCount + document.assets.count < PetAnimationLimits.clips else { throw invalid("每只宠物的视频总数上限为 512。") }
                // Check source size before copying; inspect the owned copy so
                // Finder moves or source changes cannot invalidate acceptance.
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard url.pathExtension.lowercased() == "mov" else { throw invalid("仅支持 HEVC with Alpha 的 .mov。") }
                guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0,
                      bytes <= PetAnimationLimits.movieBytes else { throw invalid("文件大小须为 1 字节至 256 MiB。") }
                let root = directory.resolvingSymlinksInPath().standardizedFileURL
                let imports = root.appendingPathComponent("animation-imports", isDirectory: true)
                guard imports.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/") else { throw invalid("导入目录越过宠物包边界。") }
                try fm.createDirectory(at: imports, withIntermediateDirectories: true)
                let uuid = UUID().uuidString.lowercased()
                let folder = imports.appendingPathComponent(uuid, isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                ownedDirectory = folder
                let movie = folder.appendingPathComponent("clip.mov")
                try fm.copyItem(at: url, to: movie)
                let info = try PetAnimationMedia.inspect(movie)
                try info.posterPNG.write(to: folder.appendingPathComponent("poster.png"), options: .atomic)
                let id = "import:\(uuid)"
                let name = String(url.deletingPathExtension().lastPathComponent.prefix(200))
                let entry = PetAnimationCatalog.Entry(id: id, name: name.isEmpty ? "动画" : name, category: "自定义",
                    file: "animation-imports/\(uuid)/clip.mov", poster: "animation-imports/\(uuid)/poster.png",
                    duration: info.duration, width: info.width, height: info.height)
                var next = document
                next.assets.append(entry)
                next.groups[key, default: []].append(id)
                let data = try JSONEncoder().encode(next)
                guard data.count <= PetAnimationLimits.manifestBytes else { throw invalid("自定义清单超过 1 MiB 上限。") }
                try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
                document = next
                ownedDirectory = nil
                result.importedIDs.append(id)
            } catch {
                if let ownedDirectory { try? fm.removeItem(at: ownedDirectory) }
                result.failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return result
    }

    struct RemovalResult {
        let binding: PetAnimationBinding
        var warnings: [String] = []
    }

    static func remove(ids: Set<String>, key: String, pack: ImagePetPack,
                       bindings: PetAnimationBindings) throws -> RemovalResult {
        let fm = FileManager.default
        let file = pack.directory.appendingPathComponent(filename)
        let exists = fm.fileExists(atPath: file.path)
        var original: Data?
        var document = Document()
        if exists {
            _ = try readRoot(pack.directory)
            original = try Data(contentsOf: file)
            document = try JSONDecoder().decode(Document.self, from: original!)
            for entry in document.assets { try validateOwnership(entry) }
        }
        var current = pack
        // The freshly-read durable document wins over an older UI snapshot.
        current.animationGroups = document.groups
        let plan = try PetAnimationRemoval.plan(ids: ids, key: key, pack: current, bindings: bindings)
        document.groups = plan.groups
        let garbage = document.assets.filter { plan.unreferencedImportedIDs.contains($0.id) }
        document.assets.removeAll { plan.unreferencedImportedIDs.contains($0.id) }
        let data = try JSONEncoder().encode(document)
        guard data.count <= PetAnimationLimits.manifestBytes else { throw invalid(NSLocalizedString("Animation library exceeds the size limit.", comment: "")) }
        if let original {
            guard try Data(contentsOf: file) == original else { throw invalid(NSLocalizedString("The animation group changed. Review your selection and try again.", comment: "")) }
        } else if fm.fileExists(atPath: file.path) {
            throw invalid(NSLocalizedString("The animation group changed. Review your selection and try again.", comment: ""))
        }
        // Membership is the commit point. A crash before preference repair is
        // safe: binding preparation filters the old IDs through these groups.
        try data.write(to: file, options: .atomic)
        var result = RemovalResult(binding: plan.binding)
        for entry in garbage {
            do { try cleanOwnedFiles(entry, directory: pack.directory) }
            catch { result.warnings.append(NSLocalizedString("Animation removed, but unused managed files could not be cleaned up:", comment: "") + " " + error.localizedDescription) }
        }
        return result
    }

    private static func cleanOwnedFiles(_ entry: PetAnimationCatalog.Entry, directory: URL) throws {
        try validateOwnership(entry)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let imports = root.appendingPathComponent("animation-imports", isDirectory: true)
        let folder = imports.appendingPathComponent(String(entry.id.dropFirst("import:".count)), isDirectory: true)
        // Never follow even an in-pack directory symlink during cleanup: it
        // could alias another asset. Only the two owned files may be removed.
        for path in [imports, folder] {
            guard (try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])).isSymbolicLink != true,
                  path.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/") else { throw invalid("Unsafe managed animation directory.") }
        }
        let owned = [folder.appendingPathComponent("clip.mov"), folder.appendingPathComponent("poster.png")]
        for path in owned {
            guard (try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])).isSymbolicLink != true,
                  (try path.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw invalid("Unsafe managed animation file.") }
        }
        for path in owned { try FileManager.default.removeItem(at: path) }
        if try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty { try FileManager.default.removeItem(at: folder) }
    }

    private static func readRoot(_ directory: URL) throws -> [String: Any] {
        guard let file = PetAnimationCatalog.localFile(filename, directory: directory),
              (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= PetAnimationLimits.manifestBytes else { throw invalid("清单路径或大小无效。") }
        let data = try Data(contentsOf: file)
        guard data.count <= PetAnimationLimits.manifestBytes, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              try JSONDecoder().decode(Header.self, from: data).version == 1,
              let assets = root["assets"] as? [Any], assets.count <= PetAnimationLimits.clips,
              let groups = root["groups"] as? [String: [String]],
              Set(groups.keys).isSubset(of: PetAnimationBindings.selectionKeys),
              groups.values.allSatisfy({ $0.count <= PetAnimationLimits.clips + 512 && $0.allSatisfy { $0.count <= 200 } }) else { throw invalid("清单版本、字段或数量无效。") }
        return root
    }
    private static func validateOwnership(_ entry: PetAnimationCatalog.Entry) throws {
        let uuid = String(entry.id.dropFirst("import:".count))
        guard entry.id.hasPrefix("import:"), UUID(uuidString: uuid) != nil,
              entry.file == "animation-imports/\(uuid)/clip.mov",
              entry.poster == "animation-imports/\(uuid)/poster.png" else { throw invalid("自定义素材的身份或自管路径无效。") }
    }
    private static func invalid(_ reason: String) -> PetAnimationImportError { .init(reason: reason) }
}
