import Foundation
import Darwin

/// Only process ancestry identifies the host of a new native invocation. Do
/// not inspect prompts, environment credentials, titles or model names.
public enum AntigravityHostOrigin {
    public static func isDSH() -> Bool {
        var pid = getppid()
        var seen = Set<Int32>()
        for _ in 0..<16 {
            guard pid > 1, seen.insert(pid).inserted,
                  let identity = CodexHookOrigin.identity(pid),
                  let parent = TerminalInfo.procInfo(pid: pid)?.ppid else { return false }
            var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            if count > 0 {
                let executable = String(decoding: path.prefix(while: { $0 != 0 }), as: UTF8.self)
                if isDSHExecutable(executable), CodexHookOrigin.identity(pid) == identity { return true }
            }
            guard CodexHookOrigin.identity(pid) == identity else { return false }
            pid = parent
        }
        return false
    }

    static func isDSHExecutable(_ path: String, bundleIdentifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }) -> Bool {
        guard path.hasPrefix("/"), let range = path.range(of: ".app/Contents/MacOS/", options: .backwards),
              !path[range.upperBound...].isEmpty,
              !path[range.upperBound...].contains("/") else { return false }
        let app = String(path[..<range.lowerBound]) + ".app"
        return bundleIdentifier(URL(fileURLWithPath: app)) == "com.deepseek.dsh"
    }
}
