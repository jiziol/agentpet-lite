import Foundation
import Darwin

/// AionUi's disposable title process is registered before it initializes Codex.
/// Identify it while the Hook is still its descendant: successful ephemeral
/// runs can exit before Codex flushes any diagnostic logs to SQLite.
public enum CodexHookOrigin {
    struct Identity: Equatable {
        let pid: Int32
        let startTicks: UInt64
    }
    private struct Registry: Decodable {
        let version: Int
        let processes: [Entry]
    }
    private struct Entry: Decodable {
        let pid: Int32
        let start_time_ticks: UInt64?
        let instance_epoch: String
        let opaque_owner_tag: String
    }

    /// AO 0.14.5 chat_spawn.go creates unpublished title/suggestion calls in
    /// <dataDir>/background-tasks/title-<MkdirTemp decimal suffix>. This is a
    /// reserved scratch workspace, not a title/prompt/model substring match.
    public static func isAOBackgroundWorkspace(_ project: String?,
                                              dataDirectory: String = NSHomeDirectory() + "/.ao/data") -> Bool {
        guard let project, project.hasPrefix("/"), dataDirectory.hasPrefix("/"),
              project == URL(fileURLWithPath: project).standardizedFileURL.path else { return false }
        let root = URL(fileURLWithPath: dataDirectory).standardizedFileURL
            .appendingPathComponent("background-tasks", isDirectory: true)
        let workspace = URL(fileURLWithPath: project)
        guard workspace.deletingLastPathComponent().path == root.path else { return false }
        let name = workspace.lastPathComponent
        guard name.hasPrefix("title-") else { return false }
        let suffix = name.dropFirst(6)
        return !suffix.isEmpty && suffix.count <= 20 && suffix.utf8.allSatisfy { (48...57).contains($0) }
    }

    public static func isAionUiTitle(home: String = NSHomeDirectory()) -> Bool {
        let chain = ancestors()
        guard !chain.isEmpty else { return false }
        let paths = [home + "/.aionui", home + "/Library/Application Support/AionUi/aionui"]
        for base in paths {
            let path = base + "/runtime/aionui-process/registry.json"
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let size = attributes[.size] as? NSNumber, size.intValue <= 262_144,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let match = titleAncestor(in: data, ancestors: chain),
                  identity(match.pid) == match else { continue }
            return true
        }
        return false
    }

    static func titleAncestor(in data: Data, ancestors: [Identity]) -> Identity? {
        guard data.count <= 262_144,
              let registry = try? JSONDecoder().decode(Registry.self, from: data),
              registry.version == 1, registry.processes.count <= 128 else { return nil }
        for entry in registry.processes where entry.pid > 1 && entry.opaque_owner_tag == "aionui-session-title" {
            guard UUID(uuidString: entry.instance_epoch) != nil, let ticks = entry.start_time_ticks else { continue }
            let candidate = Identity(pid: entry.pid, startTicks: ticks)
            if ancestors.contains(candidate) { return candidate }
        }
        return nil
    }

    /// Uses the same lossless macOS packing as AionCore proc_control.rs;
    /// comparing PID alone could exclude an unrelated task after PID reuse.
    static func identity(_ pid: Int32) -> Identity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Identity(pid: pid, startTicks: (info.pbi_start_tvsec << 20) | (info.pbi_start_tvusec & 0xF_FFFF))
    }

    static func ancestors() -> [Identity] {
        var result: [Identity] = [], pid = getppid()
        for _ in 0..<10 {
            guard let current = identity(pid), !result.contains(current),
                  let parent = TerminalInfo.procInfo(pid: pid)?.ppid else { break }
            result.append(current); pid = parent
        }
        return result
    }
}
