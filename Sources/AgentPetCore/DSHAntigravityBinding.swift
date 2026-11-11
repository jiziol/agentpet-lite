import Foundation
import CryptoKit

/// Exact native-ID binding supplied by the DSH adapter. Never infer a host from title,
/// model, directory, or an account credential. No DSH database is opened.
public enum DSHAntigravityBinding {
    public struct Record: Equatable, Sendable {
        public let profileID: String
        public let nativeSessionID: String
        public init(profileID: String, nativeSessionID: String) {
            self.profileID = profileID; self.nativeSessionID = nativeSessionID
        }
    }
    public enum Lookup: Equatable, Sendable {
        case matched(Record), notFound, ambiguous, unavailable
    }
    public static func read(sessionID: String, home: String = NSHomeDirectory() + "/.dsh") -> Lookup {
        guard UUID(uuidString: sessionID) != nil, home.hasPrefix("/") else { return .notFound }
        // Host-specific files and account-key formats belong to the adapter. The app
        // consumes only an exact native-ID binding on a versioned, same-user endpoint.
        let profile = URL(fileURLWithPath: home + "/profiles/desktop").resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(profile.utf8)).map { String(format: "%02x", $0) }.joined()
        let probes = DSHBridgeProtocol.discover(profileID: String(hash.prefix(24)))
        guard probes.count <= 1 else { return .ambiguous }
        guard let probe = probes.first else { return .notFound }
        return DSHBridgeProtocol.binding(conversationID: sessionID, probe: probe)
    }
}
