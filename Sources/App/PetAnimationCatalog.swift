import Foundation
import AppKit
import ImageIO

enum PetAnimationSource: String, Codable { case native, imported }

struct PetVideoClip {
    let id: String
    let name: String
    let category: String
    let url: URL
    let poster: NSImage?
    let duration: Double
    let width: Int
    let height: Int
    var purposes: [String] = []
    var displayName: String? = nil
    var source: PetAnimationSource = .native
}

/// Pack-owned native catalog. User imports live in a separate, versioned library.
enum PetAnimationCatalog {
    static let supportedPurposes: Set<String> = ["idle", "working", "waiting", "success", "failure", "quota", "levelup", "tap", "drag", "done", "celebrate", "sleepy"]
    struct Entry: Codable, Sendable {
        let id: String
        let name: String
        let category: String
        let file: String
        let poster: String
        let duration: Double
        let width: Int
        let height: Int
        var purposes: [String]? = nil
        var displayName: String? = nil
    }
    private struct Header: Decodable { let version: Int }
    struct Loaded {
        var clips: [PetVideoClip] = []
        var issues: [String] = []
    }

    static func load(directory: URL) -> [PetVideoClip] { loadResult(directory: directory).clips }

    static func loadResult(directory: URL) -> Loaded {
        let url = directory.appendingPathComponent("animations.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Loaded() }
        do {
            guard let safe = localFile("animations.json", directory: directory),
                  (try safe.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= PetAnimationLimits.manifestBytes else { throw CatalogError.invalid }
            let data = try Data(contentsOf: safe)
            guard data.count <= PetAnimationLimits.manifestBytes, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  try JSONDecoder().decode(Header.self, from: data).version == 1,
                  let rows = root["clips"] as? [Any], rows.count <= PetAnimationLimits.clips else { throw CatalogError.invalid }
            var result = Loaded(), ids = Set<String>()
            for (index, row) in rows.enumerated() {
                do {
                    let entry = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: row, options: [.fragmentsAllowed]))
                    guard !ids.contains(entry.id) else { throw CatalogError.invalid }
                    let clip = try resolve(entry, directory: directory)
                    ids.insert(entry.id)
                    result.clips.append(clip)
                } catch { result.issues.append("animations.json 第 \(index + 1) 项：\(error.localizedDescription)") }
            }
            return result
        } catch { return Loaded(issues: ["动画清单不可用，使用该宠物原生回退：\(error.localizedDescription)"]) }
    }

    static func resolve(_ entry: Entry, directory: URL, source: PetAnimationSource = .native) throws -> PetVideoClip {
        guard !entry.id.isEmpty, entry.id.count <= 200, !entry.id.hasPrefix("sheet:"),
              !entry.name.isEmpty, entry.name.count <= 200,
              !entry.category.isEmpty, entry.category.count <= 100,
              entry.duration.isFinite, entry.duration > 0, entry.duration <= PetAnimationLimits.duration,
              (1...PetAnimationLimits.dimension).contains(entry.width), (1...PetAnimationLimits.dimension).contains(entry.height),
              let movie = localFile(entry.file, directory: directory),
              let posterURL = localFile(entry.poster, directory: directory),
              (try? posterURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }) ?? Int.max <= 16 * 1_024 * 1_024,
              let imageSource = CGImageSourceCreateWithURL(posterURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let posterWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let posterHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...PetAnimationLimits.dimension).contains(posterWidth),
              (1...PetAnimationLimits.dimension).contains(posterHeight),
              CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil,
              let poster = NSImage(contentsOf: posterURL), poster.isValid else { throw CatalogError.invalid }
        let purposes = entry.purposes ?? []
        guard purposes.count <= 9, Set(purposes).isSubset(of: supportedPurposes),
              entry.displayName.map({ !$0.isEmpty && $0.count <= 200 }) ?? true else { throw CatalogError.invalid }
        let media = try PetAnimationMedia.inspect(movie)
        return PetVideoClip(id: entry.id, name: entry.name, category: entry.category, url: movie, poster: poster,
                            duration: media.duration, width: media.width, height: media.height,
                            purposes: purposes, displayName: entry.displayName, source: source)
    }

    /// Reject absolute paths, traversal, non-files and symlinks escaping the pack.
    static func localFile(_ path: String, directory: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/").contains("..") else { return nil }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return file
    }

    private enum CatalogError: LocalizedError {
        case invalid
        var errorDescription: String? { "字段、版本、数量、路径或海报无效。" }
    }
}
