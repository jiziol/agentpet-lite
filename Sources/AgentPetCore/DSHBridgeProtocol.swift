import Foundation
import Darwin

/// Public consumer contract. Adapter release and DSH SDK versions are diagnostic metadata only.
public enum DSHBridgeProtocol {
    public struct Status: Codable, Sendable, Equatable {
        public var schema: Int
        public var requestID: String
        public var profileID: String
        public var hostID: String
        public var hostStartedAt: Double
        public var protocolMajor: Int
        public var capabilities: [String]
        public var packageVersion: String
        public var clientCount: Int
        public var eventConnected: Bool
        public var eventSocket: String
        public var valid: Bool {
            schema == 1 && UUID(uuidString: requestID) != nil && UUID(uuidString: hostID) != nil &&
            profileID.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil &&
            hostStartedAt.isFinite && hostStartedAt > 0 && protocolMajor > 0 &&
            capabilities.count <= 32 && Set(capabilities).count == capabilities.count &&
            capabilities.allSatisfy { $0.utf8.count <= 64 && DSHObservation.validID($0) } &&
            !packageVersion.isEmpty && packageVersion.utf8.count <= 128 &&
            (0...4).contains(clientCount) && eventSocket.hasPrefix("/") && eventSocket.utf8.count < 104
        }
        public var compatible: Bool { protocolMajor == 1 && capabilities.contains("lifecycle.v1") }
        public var navigationReady: Bool { capabilities.contains("navigation.v1") && clientCount == 1 }
    }
    public struct Probe: Sendable {
        public let status: Status
        public let socketPath: String
        public let peerPID: pid_t
        public init(status: Status, socketPath: String, peerPID: pid_t) {
            self.status = status; self.socketPath = socketPath; self.peerPID = peerPID
        }
    }
    private struct StatusRequest: Encodable { let schema = 1; let operation = "status"; let requestID: String }
    public static func status(at path: String, timeout: TimeInterval = 0.2) -> Probe? {
        let request = StatusRequest(requestID: UUID().uuidString)
        guard let (status, pid): (Status, pid_t) = DSHNavigation.exchange(path: path, request: request, timeout: timeout),
              status.valid, status.requestID == request.requestID,
              status.hostStartedAt <= Date().timeIntervalSince1970 + 5 else { return nil }
        return Probe(status: status, socketPath: path, peerPID: pid)
    }
    /// Bounded same-user endpoint discovery. Multiple instances of one Profile remain ambiguous.
    public static func discover(profileID: String, timeout: TimeInterval = 0.6) -> [Probe] {
        let root = "/tmp/agentpet-dsh-\(getuid())"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root), names.count <= 64 else { return [] }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, min(timeout, 1))
        var result: [Probe] = []
        for name in names where name.range(of: "^h-[A-Za-z0-9]+$", options: .regularExpression) != nil {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            if let probe = status(at: root + "/" + name + "/nav.sock", timeout: min(remaining, 0.15)),
               probe.status.profileID == profileID { result.append(probe) }
        }
        return result
    }
    private struct BindingRequest: Encodable {
        let schema = 1; let operation = "binding"
        let requestID: String; let hostID: String; let profileID: String; let conversationID: String
    }
    private struct BindingReply: Decodable {
        let schema: Int; let requestID: String; let hostID: String; let profileID: String
        let result: String; let nativeSessionID: String?
    }
    public static func binding(conversationID: String, probe: Probe) -> DSHAntigravityBinding.Lookup {
        guard UUID(uuidString: conversationID) != nil, probe.status.compatible,
              probe.status.capabilities.contains("bindings.v1") else { return .notFound }
        let request = BindingRequest(requestID: UUID().uuidString, hostID: probe.status.hostID,
            profileID: probe.status.profileID, conversationID: conversationID)
        guard let (reply, pid): (BindingReply, pid_t) = DSHNavigation.exchange(path: probe.socketPath, request: request, timeout: 0.2),
              pid == probe.peerPID, reply.schema == 1, reply.requestID == request.requestID,
              reply.hostID == request.hostID, reply.profileID == request.profileID else { return .unavailable }
        switch reply.result {
        case "notFound": return .notFound
        case "ambiguous": return .ambiguous
        case "matched":
            guard let id = reply.nativeSessionID, DSHObservation.validID(id) else { return .unavailable }
            return .matched(.init(profileID: reply.profileID, nativeSessionID: id))
        default: return .unavailable
        }
    }
}
