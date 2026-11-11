import Foundation
import ServiceManagement
import AgentPetCore

/// Explicit deployment diagnostics. Never runs as part of normal app startup.
enum IdentityCLI {
    static func run(_ arguments: [String]) {
        do {
            switch arguments.first {
            case "identity":
                try printJSON(["bundleIdentifier": AgentPetPaths.bundleIdentifier,
                    "dataRoot": AgentPetPaths.baseDir,
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unbundled",
                    "localCompatibilityRoot": AgentPetPaths.migratedLocalDir as Any? ?? NSNull()])
            case "integration":
                guard arguments.count == 3, ["inspect", "update"].contains(arguments[1]),
                      let kind = AgentKind(rawValue: arguments[2]) else { throw Failure.usage }
                let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
                let setup = AgentIntegrationSetup(binary: binary)
                let before = try setup.inspect(kind)
                if arguments[1] == "update" {
                    guard before.configuration != .absent else { throw Failure.absent }
                    try setup.install(kind)
                }
                let after = try setup.inspect(kind)
                let state = after.configuration == .absent ? "absent"
                    : after.configuration == .needsUpdate ? "needsUpdate" : "configured"
                try printJSON(["agent": kind.rawValue, "configuration": state,
                               "blocked": after.installBlockReason != nil])
            case "login-item":
                guard arguments.count == 2, Bundle.main.bundleURL.pathExtension == "app" else { throw Failure.usage }
                switch arguments[1] {
                case "enable": try SMAppService.mainApp.register()
                case "disable": try SMAppService.mainApp.unregister()
                case "status": break
                default: throw Failure.usage
                }
                let state: String
                switch SMAppService.mainApp.status {
                case .enabled: state = "enabled"
                case .requiresApproval: state = "requiresApproval"
                case .notRegistered: state = "notRegistered"
                case .notFound: state = "notFound"
                @unknown default: state = "unknown"
                }
                try printJSON(["status": state])
            default: throw Failure.usage
            }
        } catch {
            fputs("Identity operation refused: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private enum Failure: LocalizedError {
        case usage, absent
        var errorDescription: String? {
            switch self {
            case .usage: return "Use identity, integration inspect|update AGENT, or login-item status|enable|disable."
            case .absent: return "An absent integration is not installed during migration."
            }
        }
    }

    private static func printJSON(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
