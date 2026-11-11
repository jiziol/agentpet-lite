import AppKit
import AgentPetCore
import Foundation

/// Brings the terminal running a given agent session to the front. Terminal.app
/// and iTerm2 expose a per-tab/session `tty` over AppleScript, so we can focus
/// the *exact* window and tab. Warp has no scripting dictionary, so the best we
/// can do there is activate the app. Everything else falls back to activation.
enum TerminalFocus {
    /// osascript can block for a beat while the target app comes forward; keep it
    /// off the main thread so the bubble stays responsive.
    private static let queue = DispatchQueue(label: "agentpet.terminal-focus", qos: .userInitiated)

    /// Bundle id per `TERM_PROGRAM`, used to activate terminals we can't script.
    private static let bundleIDs: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "vscode": "com.microsoft.VSCode",
        "ghostty": "com.mitchellh.ghostty",
        "Hyper": "co.zeit.hyper",
        "Tabby": "org.tabby",
        "kitty": "net.kovidgoyal.kitty",
        "alacritty": "org.alacritty",
    ]

    enum Result: Sendable { case openedTarget, activatedApplication, failed }

    static func focus(program: String?, tty: String?, focusURL: String? = nil,
                      completion: @escaping @Sendable (Result) -> Void) {
        guard let program else { completion(.failed); return }
        queue.async {
            switch program {
            case "Apple_Terminal" where validTTY(tty):
                completion(runScript(appleTerminalScript(tty: tty!)) == "matched" ? .openedTarget : .failed)
            case "iTerm.app" where validTTY(tty):
                completion(runScript(iTermScript(tty: tty!)) == "matched" ? .openedTarget : .failed)
            default:
                if program == "WarpTerminal", let focusURL, let url = URL(string: focusURL), url.scheme == "warp" {
                    DispatchQueue.main.async {
                        completion(NSWorkspace.shared.open(url) ? .openedTarget : .failed)
                    }
                } else if let bid = bundleIDs[program] {
                    completion(runScript("tell application id \"\(bid)\" to activate") != nil ? .activatedApplication : .failed)
                } else { completion(.failed) }
            }
        }
    }

    private static func validTTY(_ tty: String?) -> Bool {
        TerminalInfo.concreteTTY(tty) != nil
    }

    private static func appleTerminalScript(tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (tty of t) is "\(tty)" then
                            set selected of t to true
                            set frontmost of w to true
                            return "matched"
                        end if
                    end try
                end repeat
            end repeat
            return "missing"
        end tell
        """
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if (tty of s) is "\(tty)" then
                                select w
                                select t
                                select s
                                return "matched"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "missing"
        end tell
        """
    }

    /// Wait off the main thread for the exact-tab result, rather than treating
    /// a launched osascript process as successful navigation.
    private static func runScript(_ source: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "with timeout of 5 seconds\n" + source + "\nend timeout"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
