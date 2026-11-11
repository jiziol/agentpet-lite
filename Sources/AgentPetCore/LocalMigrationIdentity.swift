import Foundation
import Darwin

/// Grants compatibility only for the precise Local-to-Lite migration receipt.
public enum LocalMigrationIdentity {
    /// A copied queue and its preserved source can contain the very same file.
    /// Keep one durable copy until the normal queue reader consumes it.
    public static func removeCopiedQueueDuplicates(destination: String, source: String) {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: destination).appendingPathComponent("queue")
        let original = URL(fileURLWithPath: source).appendingPathComponent("queue")
        for directory in [target, original] {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid() else { return }
        }
        guard let names = try? fm.contentsOfDirectory(atPath: target.path), names.count <= 4096 else { return }
        for name in names where name.hasSuffix(".json") {
            let a = target.appendingPathComponent(name), b = original.appendingPathComponent(name)
            var left = stat(), right = stat()
            guard lstat(a.path, &left) == 0, lstat(b.path, &right) == 0,
                  [left, right].allSatisfy({ $0.st_mode & S_IFMT == S_IFREG && $0.st_uid == getuid()
                      && $0.st_nlink == 1 && $0.st_size <= 1_048_576 }),
                  left.st_size == right.st_size,
                  let bytes = try? Data(contentsOf: a), let saved = try? Data(contentsOf: b),
                  bytes == saved else { continue }
            try? fm.removeItem(at: a)
        }
    }

    public static func sourceRoot(destination: String, home: String, bundle: String) -> String? {
        let source = home + "/.agentpet-local"
        guard destination == home + "/.agentpet-lite", source != destination else { return nil }
        let marker = destination + "/local-migration-v1.json"
        for (path, directory) in [(source, true), (destination, true), (marker, false)] {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                  info.st_mode & 0o077 == 0,
                  directory || (info.st_nlink == 1 && info.st_size > 0 && info.st_size < 1_048_576) else { return nil }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: marker)),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["protocol"] as? Int == 1, value["status"] as? String == "copied",
              value["sourceRoot"] as? String == source, value["destinationRoot"] as? String == destination,
              value["sourceBundle"] as? String == "local.acerz.agentpet",
              value["destinationBundle"] as? String == bundle else { return nil }
        return source
    }
}

/// One process owns both identities during migration; the old GUI cannot write
/// its frozen source snapshot while Lite receives its already-loaded helpers.
public final class AgentPetInstanceLock {
    private var descriptors: [Int32] = []
    public init() {}
    deinit { release() }

    public func acquire(directories: [String]) -> Bool {
        guard descriptors.isEmpty, !directories.isEmpty else { return false }
        for directory in Set(directories).sorted() {
            do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700]) }
            catch { release(); return false }
            var info = stat()
            guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid() else { release(); return false }
            let fd = open(directory + "/instance.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { release(); return false }
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); release(); return false }
            descriptors.append(fd)
        }
        return true
    }

    public func release() {
        for fd in descriptors { close(fd) }
        descriptors.removeAll()
    }
}
