import Foundation
import CryptoKit
import Darwin

/// Serializes this process's config edits. External editors do not share this
/// lock: snapshots are rechecked just before atomic replacement, not a claim
/// of filesystem-wide compare-and-swap against uncooperative writers.
enum HookFileTransaction {
    private static let lock = NSRecursiveLock()
    struct Snapshot {
        let data: Data?
        let mode: Int
        let inode: UInt64?
    }
    private struct Manifest: Codable {
        let path: String
        let beforeSHA256: String?
        let afterSHA256: String?
        let beforeMode: Int
        let afterMode: Int
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func read(_ path: String) throws -> Snapshot {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: path) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return Snapshot(data: nil, mode: 0o600, inode: nil)
            }
            throw error
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw HookInstallerError.unsafeSettings(path: path)
        }
        return Snapshot(data: try Data(contentsOf: URL(fileURLWithPath: path)),
                        mode: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600,
                        inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
    private static func check(_ expected: Snapshot, path: String) throws {
        let actual = try read(path)
        guard actual.data == expected.data, actual.mode == expected.mode, actual.inode == expected.inode else {
            throw HookInstallerError.settingsChanged(path: path)
        }
    }
    @discardableResult
    static func update(path: String, transform: (Data?) throws -> Data?) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        let before = try read(path)
        return try commit(path: path, before: before, after: transform(before.data))
    }
    @discardableResult
    static func commit(path: String, before: Snapshot, after: Data?, mode: Int? = nil) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        try check(before, path: path)
        let outputMode = mode ?? before.mode
        guard before.data != after || (after != nil && outputMode != before.mode) else { return nil }
        let fm = FileManager.default
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent(".agentpet-backups")
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let a = try fm.attributesOfItem(atPath: root.path)
        guard a[.type] as? FileAttributeType == .typeDirectory,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (a[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw HookInstallerError.unsafeSettings(path: root.path)
        }
        let backup = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func save(_ data: Data, _ name: String) throws {
            let url = backup.appendingPathComponent(name)
            try data.write(to: url, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if let data = before.data { try save(data, "before") }
        if let after { try save(after, "after") }
        let manifest = Manifest(path: target.path, beforeSHA256: before.data.map(digest),
                                afterSHA256: after.map(digest), beforeMode: before.mode, afterMode: outputMode)
        try save(JSONEncoder().encode(manifest), "manifest.json")
        let temp = parent.appendingPathComponent(".agentpet-write-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        if let after {
            // Create private first, then set the original permissions before rename.
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(fd)
            try after.write(to: temp)
            try fm.setAttributes([.posixPermissions: outputMode], ofItemAtPath: temp.path)
        }
        try check(before, path: path)
        if after != nil {
            guard rename(temp.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else { try fm.removeItem(at: target) }
        return backup.path
    }
    static func rollback(backup: String) throws {
        lock.lock(); defer { lock.unlock() }
        let root = URL(fileURLWithPath: backup)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        func load(_ name: String, _ hash: String?) throws -> Data? {
            guard let hash else { return nil }
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            guard digest(data) == hash else { throw HookInstallerError.settingsChanged(path: backup) }
            return data
        }
        let before = try load("before", manifest.beforeSHA256)
        let after = try load("after", manifest.afterSHA256)
        let current = try read(manifest.path)
        guard current.data == after, current.data == nil || current.mode == manifest.afterMode else {
            throw HookInstallerError.settingsChanged(path: manifest.path)
        }
        try commit(path: manifest.path, before: current, after: before, mode: manifest.beforeMode)
    }
}
