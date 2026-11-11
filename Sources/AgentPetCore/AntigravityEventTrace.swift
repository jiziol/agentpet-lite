import Foundation
import CryptoKit

/// Bounded metadata-only diagnostics for validating the real native route.
public enum AntigravityEventTrace {
    public static func record(_ event: AgentEvent, state: AgentState) {
        guard AgentPetPaths.isLocal, event.agentKind == .antigravity else { return }
        let path = AgentPetPaths.baseDir + "/antigravity-events.jsonl"
        let id = SHA256.hash(data: Data(event.sessionId.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let row: [String: Any] = ["at": event.timestamp.timeIntervalSince1970, "session": id,
            "state": state.rawValue, "hasModel": event.model != nil, "hasProject": event.project != nil,
            "hasTranscript": event.transcriptPath != nil, "result": event.turnResult?.rawValue ?? "active"]
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
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
    }
}
