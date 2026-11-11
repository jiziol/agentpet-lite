import Foundation
import Darwin

/// pi-acp 0.0.33 persists the exact native UUID/session-file association here.
/// Read the bounded index only; never inspect prompts or guess IDs from filenames.
enum PiACPIdentity {
    enum Lookup: Equatable { case matched(String), notFound, ambiguous, unavailable }
    static var defaultMap: String { NSHomeDirectory() + "/.pi/pi-acp/session-map.json" }
    static let maxBytes = 1_048_576

    /// Reverse only an exact index entry; filenames and cwd never identify a UUID.
    static func sessionID(nativeID: String, path: String = defaultMap) -> String? {
        guard UUID(uuidString: nativeID) != nil, let index = loadIndex(path).0,
              let entry = index.sessions[nativeID], entry.sessionId == nativeID,
              let file = entry.sessionFile else { return nil }
        let id = "pi:" + file
        guard sessionFile(id) != nil else { return nil }
        let matches = index.sessions.filter { $0.value.sessionFile == file }
        guard matches.count == 1, matches.first?.key == nativeID else { return nil }
        return id
    }

    private struct Entry: Decodable { let sessionId: String; let sessionFile: String? }
    private struct Index: Decodable { let version: Int; let sessions: [String: Entry] }

    static func sessionFile(_ id: String) -> String? {
        guard id.hasPrefix("pi:/"), id.utf8.count <= 4100 else { return nil }
        let path = String(id.dropFirst(3))
        guard path.hasSuffix(".jsonl"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return nil }
        return path
    }

    static func read(sessionID: String, path: String = defaultMap) -> Lookup {
        guard let file = sessionFile(sessionID) else { return .notFound }
        let loaded = loadIndex(path)
        guard let index = loaded.0 else { return loaded.1 }
        var matches: [String] = []
        for (id, entry) in index.sessions where entry.sessionFile?.utf8.elementsEqual(file.utf8) == true {
            guard id == entry.sessionId, UUID(uuidString: id) != nil else { return .unavailable }
            matches.append(id)
        }
        if matches.count > 1 { return .ambiguous }
        return matches.first.map(Lookup.matched) ?? .notFound
    }
    private static func loadIndex(_ path: String) -> (Index?, Lookup) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return (nil, errno == ENOENT ? .notFound : .unavailable) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_size >= 0, before.st_size <= maxBytes else { return (nil, .unavailable) }
        var data = Data(count: Int(before.st_size) + 1)
        let size = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        var after = stat()
        guard size == Int(before.st_size), fstat(fd, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return (nil, .unavailable) }
        data.count = size
        guard let index = try? JSONDecoder().decode(Index.self, from: data), index.version == 1,
              index.sessions.count <= 4096 else { return (nil, .unavailable) }
        return (index, .notFound)
    }
}
