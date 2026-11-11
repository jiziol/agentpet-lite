import Foundation
import CryptoKit

/// Small transition-only diagnostic log. No titles, prompts, paths, tool
/// arguments, models, or source IDs are retained here.
public enum CodexEventTrace {
    public static func record(_ event: AgentEvent, before: AgentState?, after: AgentState) {
        guard AgentPetPaths.isLocal, event.agentKind == .codex,
              before != after || event.eventName == "UserPromptSubmit" else { return }
        let path = AgentPetPaths.baseDir + "/codex-transitions.jsonl"
        let fingerprint = SHA256.hash(data: Data(event.sessionId.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let row: [String: Any] = ["at": event.timestamp.timeIntervalSince1970,
                                  "session": fingerprint, "event": String(event.eventName.prefix(64)),
                                  "before": before?.rawValue ?? "absent", "after": after.rawValue]
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) else { return }
        data.append(0x0A)
        let manager = FileManager.default
        if let size = try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber, size.intValue > 262_144 {
            try? manager.removeItem(atPath: path + ".previous")
            try? manager.moveItem(atPath: path, toPath: path + ".previous")
        }
        if !manager.fileExists(atPath: path) { manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { /* Monitoring must not block the source task. */ }
    }
}
