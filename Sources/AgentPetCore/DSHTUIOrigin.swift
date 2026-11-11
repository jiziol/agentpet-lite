import Foundation
import Darwin

/// Positive process provenance for the TUI source filter. Terminal names,
/// project paths, prompts and model names never establish TUI ownership.
public enum DSHTUIOrigin {
    public static func isHosted(startingAt start: Int32 = getppid()) -> Bool {
        var pid = start
        var seen = Set<Int32>()
        for _ in 0..<16 {
            guard pid > 1, seen.insert(pid).inserted,
                  let identity = CodexHookOrigin.identity(pid),
                  let info = TerminalInfo.procInfo(pid: pid) else { return false }
            var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            if count > 0 {
                let executable = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
                if URL(fileURLWithPath: executable).lastPathComponent == "node",
                   let arguments = arguments(pid), isTUICommand(arguments),
                   CodexHookOrigin.identity(pid) == identity { return true }
            }
            guard CodexHookOrigin.identity(pid) == identity else { return false }
            pid = info.ppid
        }
        return false
    }

    static func isTUICommand(_ arguments: [String], packageName: (URL) -> String? = readPackageName) -> Bool {
        guard let script = nodeScript(arguments), script.hasPrefix("/") else { return false }
        let file = URL(fileURLWithPath: script).resolvingSymlinksInPath().standardizedFileURL
        var root = file.deletingLastPathComponent()
        for _ in 0..<6 {
            if let name = packageName(root) {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                if name == "@deepseek-harness-tui/dsh-tui" {
                    return ["bin/dsh-tui.js", "lib/types/dsh-adapter/host-entry.js"].contains(relative)
                }
                if name == "@deepseek-ai/dsh", relative == "lib/bin.js" {
                    // The native CLI fallback can launch TUI without a TUI
                    // launcher ancestor. Only its exact dedicated Profile counts.
                    let appArguments = Array(arguments.dropFirst(arguments.firstIndex(of: script)! + 1))
                    return profile(in: appArguments) == "dsh-tui"
                }
                return false
            }
            let parent = root.deletingLastPathComponent()
            guard parent != root else { return false }
            root = parent
        }
        return false
    }

    private static func nodeScript(_ arguments: [String]) -> String? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return arguments.dropFirst(index + 1).first }
            if ["-e", "--eval", "-p", "--print"].contains(argument) ||
                argument.hasPrefix("--eval=") || argument.hasPrefix("--print=") ||
                (argument.hasPrefix("-e") && !argument.hasPrefix("--")) ||
                (argument.hasPrefix("-p") && !argument.hasPrefix("--")) { return nil }
            if ["-r", "--require", "--import", "--loader", "--experimental-loader"].contains(argument) {
                index += 2; continue
            }
            if argument.hasPrefix("-") { index += 1; continue }
            return argument
        }
        return nil
    }

    private static func profile(in arguments: [String]) -> String? {
        var selected: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            if argument == "--profile", index + 1 < arguments.count {
                selected = arguments[index + 1]; index += 2; continue
            }
            if argument.hasPrefix("--profile=") {
                selected = String(argument.dropFirst(10)); index += 1; continue
            }
            if argument == "--patch", index + 1 < arguments.count { index += 2; continue }
            if argument.hasPrefix("--patch=") { index += 1; continue }
            // Subcommands, config replacements and diagnostic modes are not
            // evidence of a running TUI, even if their text names its Profile.
            return nil
        }
        return selected
    }

    private static func readPackageName(_ root: URL) -> String? {
        let file = root.appendingPathComponent("package.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 131_072,
              let data = try? Data(contentsOf: file), data.count <= 131_072,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["name"] as? String
    }

    /// KERN_PROCARGS2 includes an environment tail. Decode exactly argc argv
    /// entries and stop; no environment values are examined or retained.
    private static func arguments(_ pid: Int32) -> [String]? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 1_048_576 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, UInt32(query.count), &data, &size, nil, 0) == 0 else { return nil }
        let argc = data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc <= 4096 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size && data[index] != 0 { index += 1 } // executable path
        while index < size && data[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = index
            while index < size && data[index] != 0 { index += 1 }
            guard index < size else { return nil }
            result.append(String(decoding: data[start..<index], as: UTF8.self)); index += 1
        }
        return result
    }
}
