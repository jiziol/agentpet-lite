import AppKit
import AgentPetCore

/// Exact page evidence may acknowledge only the clicked native result. Project
/// boards, other members and AO approval receipts are never acknowledged here.
@MainActor
enum AOProjectNavigation {
    struct Target: Equatable {
        let projectID: String
        let projectName: String
        let orchestratorIDs: Set<String>
        var instanceID: String? = nil
        var sessionID: String? = nil
        var requiredCapability: String? {
            guard sessionID != nil else { return nil }
            return projectID == AOHostMapping.standaloneProjectID ? "standalone-session.v1" : "project-session.v1"
        }
    }
    enum Destination: Equatable { case orchestrator(String), board, session(String) }
    enum Outcome { case opened(Destination), failed(String), superseded }
    @MainActor protocol Driver: AnyObject {
        func open(_ target: Target, validate: @escaping @MainActor () -> Bool) async -> Outcome
    }
    struct Capability: Codable, Equatable {
        let version: Int
        let instanceId: String
        let appRunId: String
        let pid: Int32
        let appPath: String
        let updatedAt: Double
        var capabilities: [String]? = nil
        enum CodingKeys: String, CodingKey {
            case version = "protocol", instanceId, appRunId, pid, appPath, updatedAt, capabilities
        }
        func isCurrent(run: AORunFile, target: Target, now: Date) -> Bool {
            let age = now.timeIntervalSince1970 * 1000 - updatedAt
            return version == 1 && UUID(uuidString: instanceId) != nil && pid > 0
                && appRunId == run.appRunID && appRunId == target.instanceID
                && appPath.hasPrefix("/") && appPath.hasSuffix(".app") && appPath.utf8.count <= 4096
                && updatedAt.isFinite && age >= 0 && age <= 30_000
                && (target.requiredCapability.map { capabilities?.contains($0) == true } ?? true)
        }
    }
    struct Receipt: Codable {
        let version: Int
        let instanceId: String
        let appRunId: String
        let projectId: String
        let requestId: String
        let status: String
        let path: String?
        let sessionId: String?
        let completedAt: Double
        enum CodingKeys: String, CodingKey {
            case version = "protocol", instanceId, appRunId, projectId, requestId, status, path, sessionId, completedAt
        }
        func matches(capability: Capability, target: Target, requestID: String, since: Date, now: Date) -> Bool {
            version == 1 && instanceId == capability.instanceId && appRunId == capability.appRunId
                && projectId == target.projectID && self.requestId == requestID
                && completedAt.isFinite && completedAt >= since.timeIntervalSince1970 * 1000
                && completedAt <= now.timeIntervalSince1970 * 1000
        }
        func destination(projectID: String) -> Destination? {
            guard status == "confirmed", projectId == projectID else { return nil }
            let board = "/projects/" + projectID
            if let sessionId {
                guard AOProjectNavigation.validID(sessionId), path == board + "/sessions/" + sessionId else { return nil }
                return .orchestrator(sessionId)
            }
            return path == board ? .board : nil
        }
        func destination(target: Target) -> Destination? {
            if let exact = target.sessionID {
                let expected = target.projectID == AOHostMapping.standaloneProjectID
                    ? "/sessions/" + exact : "/projects/" + target.projectID + "/sessions/" + exact
                guard status == "confirmed", projectId == target.projectID, sessionId == exact,
                      path == expected else { return nil }
                return .session(exact)
            }
            return destination(projectID: target.projectID)
        }
    }
    nonisolated static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,239}$", options: .regularExpression) != nil
    }
    static func requestURL(target: Target, capability: Capability, requestID: String) -> URL? {
        guard validTarget(target), UUID(uuidString: requestID) != nil else { return nil }
        var url = URLComponents()
        url.scheme = "ao-app"; url.host = "navigate"
        url.queryItems = [URLQueryItem(name: "v", value: "1"),
                         URLQueryItem(name: "instance", value: capability.instanceId),
                         URLQueryItem(name: "request", value: requestID),
                         URLQueryItem(name: "run", value: capability.appRunId)]
        if target.projectID != AOHostMapping.standaloneProjectID {
            url.queryItems?.append(URLQueryItem(name: "project", value: target.projectID))
        }
        if let sessionID = target.sessionID { url.queryItems?.append(URLQueryItem(name: "session", value: sessionID)) }
        return url.url
    }
    static func open(_ target: Target, driver: any Driver,
                     validate: @escaping @MainActor () -> Bool) async -> Outcome {
        guard validate(), !Task.isCancelled else { return .superseded }
        guard validTarget(target),
              let instance = target.instanceID, AOHostObservation.validInstanceID(instance) else {
            return .failed(NSLocalizedString("ao.navigation.stale", comment: ""))
        }
        let outcome = await driver.open(target, validate: validate)
        return validate() && !Task.isCancelled ? outcome : .superseded
    }
    private static func validTarget(_ target: Target) -> Bool {
        if let id = target.sessionID {
            return validID(id) && (target.projectID == AOHostMapping.standaloneProjectID || validID(target.projectID))
        }
        return validID(target.projectID) && target.projectID != AOHostMapping.standaloneProjectID
    }
}

@MainActor
final class SystemAOProjectNavigationDriver: AOProjectNavigation.Driver {
    private let runFilePath: String
    init(runFilePath: String = AORunFile.path()) { self.runFilePath = runFilePath }

    func open(_ target: AOProjectNavigation.Target,
              validate: @escaping @MainActor () -> Bool) async -> AOProjectNavigation.Outcome {
        guard let run = AORunFile.read(path: runFilePath), run.appRunID == target.instanceID else { return failure("ao.navigation.stale") }
        let root = URL(fileURLWithPath: runFilePath).deletingLastPathComponent()
        guard let capability: AOProjectNavigation.Capability = read(root.appendingPathComponent("desktop-navigation-v1.json")),
              capability.isCurrent(run: run, target: target, now: Date()),
              let app = NSRunningApplication(processIdentifier: capability.pid), !app.isTerminated,
              let bundle = app.bundleURL,
              bundle.resolvingSymlinksInPath().standardizedFileURL == URL(fileURLWithPath: capability.appPath).resolvingSymlinksInPath().standardizedFileURL else {
            return failure("ao.navigation.unsupported")
        }
        let requestID = UUID().uuidString.lowercased()
        guard let url = AOProjectNavigation.requestURL(target: target, capability: capability, requestID: requestID),
              validate(), !Task.isCancelled else { return .superseded }
        let startedAt = Date()
        do {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let opened = try await NSWorkspace.shared.open([url], withApplicationAt: bundle, configuration: config)
            guard opened.processIdentifier == capability.pid else { return failure("ao.navigation.unconfirmed") }
        } catch { return failure("ao.navigation.unconfirmed") }
        // OS acceptance is only pending. Require the exact request's fresh,
        // daemon-bound page receipt, and foreground identity from NSWorkspace.
        let receiptURL = root.appendingPathComponent("navigation-receipts/" + requestID + ".json")
        for _ in 0..<100 {
            guard validate(), !Task.isCancelled else { return .superseded }
            guard AORunFile.read(path: runFilePath) == run, !app.isTerminated else { return failure("ao.navigation.stale") }
            if let receipt: AOProjectNavigation.Receipt = read(receiptURL) {
                guard receipt.matches(capability: capability, target: target, requestID: requestID, since: startedAt, now: Date()),
                      let destination = receipt.destination(target: target),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == capability.pid else { return failure("ao.navigation.unconfirmed") }
                return .opened(destination)
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return .superseded }
        }
        return failure("ao.navigation.unconfirmed")
    }
    private func failure(_ key: String) -> AOProjectNavigation.Outcome {
        .failed(NSLocalizedString(key, comment: ""))
    }
    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 8192,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
