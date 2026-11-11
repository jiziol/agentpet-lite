import Foundation

/// Shared JSON coders so the CLI helper and the daemon agree on the wire
/// format (notably the date strategy).
public enum EventCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// Default on-disk locations used by both the daemon and the CLI helper.
public enum AgentPetPaths {
    public static var isLite: Bool {
        #if AGENTPET_LITE
        true
        #else
        false
        #endif
    }
    public static var bundleIdentifier: String {
        isLite ? "io.github.jiziol.agentpet-lite" : "local.acerz.agentpet"
    }
    /// Historical name for the maintained build policy, shared by Local and Lite.
    public static var isLocal: Bool {
        #if AGENTPET_LOCAL
        true
        #else
        false
        #endif
    }
    public static var baseDir: String {
        if isLite { return ProcessInfo.processInfo.environment["AGENTPET_LITE_HOME"] ?? NSHomeDirectory() + "/.agentpet-lite" }
        if isLocal { return ProcessInfo.processInfo.environment["AGENTPET_LOCAL_HOME"] ?? NSHomeDirectory() + "/.agentpet-local" }
        return NSHomeDirectory() + "/.agentpet"
    }
    public static var socketPath: String { baseDir + "/agentpet.sock" }
    public static var eventSocketPaths: [String] {
        [socketPath] + [migratedLocalDir.map { $0 + "/agentpet.sock" }].compactMap { $0 }
    }
    public static var queueDir: String { baseDir + "/queue" }
    /// Already-loaded clients can finish through Local's endpoint after a
    /// verified migration. Custom test/data roots never opt into the real home.
    public static var migratedLocalDir: String? {
        guard isLite, ProcessInfo.processInfo.environment["AGENTPET_LITE_HOME"] == nil else { return nil }
        return LocalMigrationIdentity.sourceRoot(destination: baseDir, home: NSHomeDirectory(), bundle: bundleIdentifier)
    }
}
