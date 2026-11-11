import Foundation

/// Official AO discovery file. It contains the local daemon port and the
/// run-scoped generation ID, never a credential. Reading it is the supported
/// way for a local client to find the loopback daemon.
public struct AORunFile: Equatable, Sendable {
    public var port: Int
    public var pid: Int32
    public var appRunID: String
    public var startedAt: Date?

    public init(port: Int, pid: Int32, appRunID: String, startedAt: Date? = nil) {
        self.port = port
        self.pid = pid
        self.appRunID = appRunID
        self.startedAt = startedAt
    }

    public static var defaultPath: String {
        NSHomeDirectory() + "/.ao/running.json"
    }

    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["AO_RUN_FILE"], !override.isEmpty,
           override.hasPrefix("/"), override.utf8.count <= 4096 {
            return override
        }
        return defaultPath
    }

    /// Bounded, read-only discovery. Returns nil for a missing, oversized,
    /// malformed or non-loopback run file.
    public static func read(path: String? = nil, now: Date = Date()) -> AORunFile? {
        let location = path ?? Self.path()
        guard location.hasPrefix("/") else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: location),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= 65_536,
              let data = try? Data(contentsOf: URL(fileURLWithPath: location)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let portNumber = object["port"] as? NSNumber,
              let pidNumber = object["pid"] as? NSNumber,
              let appRunID = object["appRunId"] as? String,
              AOHostObservation.validInstanceID(appRunID) else { return nil }
        let port = portNumber.intValue
        let pid = pidNumber.int32Value
        guard (1...65_535).contains(port), pid > 0, pidNumber.int64Value <= Int64(Int32.max) else { return nil }
        let startedAt = (object["startedAt"] as? String).flatMap(AOAPIDate.parse)
        if let startedAt, !startedAt.timeIntervalSince1970.isFinite { return nil }
        _ = now // Callers pass their clock; the run file itself has no freshness claim.
        return AORunFile(port: port, pid: pid, appRunID: appRunID, startedAt: startedAt)
    }
}

/// ISO-8601 parsing shared by the run file and the HTTP read model. Both
/// fractional and whole-second forms occur across AO builds.
public enum AOAPIDate {
    public static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 64 else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(raw)
    }
}

/// Read-only AO HTTP client. Only the documented loopback listener is used;
/// there is no authentication header, cookie, cache or redirect-following
/// state carried into this client.
public protocol AOHostLoading: Sendable {
    func load(_ run: AORunFile, now: Date) async -> AOSnapshot?
}

public struct AOAPIClient: AOHostLoading {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 4
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.waitsForConnectivity = false
            configuration.connectionProxyDictionary = [:]
            self.session = URLSession(configuration: configuration)
        }
    }

    public func load(_ run: AORunFile, now: Date) async -> AOSnapshot? {
        guard let sessionsData = await get(path: "/api/v1/sessions", run: run) else { return nil }
        // Project names are display-only; a failed projects read must not hide
        // the exact session observations.
        let projectsData = await get(path: "/api/v1/projects", run: run)
        guard var snapshot = AOSnapshotParser.parse(sessionsData: sessionsData, projectsData: projectsData,
                                      run: run, observedAt: now) else { return nil }
        // Never combine a custom/changed daemon with the default installation's
        // native identities. HTTP host facts remain usable without this reader.
        if run == AORunFile.read(path: AORunFile.defaultPath) {
            snapshot.nativeIdentities = AONativeIdentityReader.read(snapshot: snapshot)
            guard run == AORunFile.read(path: AORunFile.defaultPath) else { return nil }
        }
        return snapshot
    }

    private func get(path: String, run: AORunFile) async -> Data? {
        guard (1...65_535).contains(run.port), AOHostObservation.validInstanceID(run.appRunID),
              let url = URL(string: "http://127.0.0.1:\(run.port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host == "127.0.0.1", http.url?.port == run.port,
                  data.count > 0, data.count <= 1_048_576 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

/// Pure parser so the read contract is testable without a daemon.
public enum AOSnapshotParser {
    private struct SessionsResponse: Decodable { let sessions: [Session] }
    private struct ProjectsResponse: Decodable { let projects: [Project] }
    private struct Session: Decodable {
        let id: String?
        let projectId: String?
        let kind: String?
        let harness: String?
        let displayName: String?
        let branch: String?
        let isTerminated: Bool?
        let status: String?
        let displayStatus: String?
        let activity: Activity?
        let createdAt: String?
        let updatedAt: String?
        let lastEventAt: String?
    }
    private struct Activity: Decodable {
        let state: String?
        let lastActivityAt: String?
    }
    private struct Project: Decodable {
        let id: String?
        let name: String?
    }

    public static func parse(sessionsData: Data, projectsData: Data?, run: AORunFile,
                             observedAt: Date) -> AOSnapshot? {
        guard AOHostObservation.validInstanceID(run.appRunID),
              observedAt.timeIntervalSince1970.isFinite,
              sessionsData.count <= 1_048_576,
              (projectsData?.count ?? 0) <= 262_144 else { return nil }
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(SessionsResponse.self, from: sessionsData) else { return nil }
        var projectNames: [String: String] = [:]
        if let projectsData, let projects = try? decoder.decode(ProjectsResponse.self, from: projectsData) {
            for project in projects.projects.prefix(100) {
                guard let id = project.id, AOHostObservation.validID(id),
                      let name = project.name, AOHostObservation.validLabel(name, limit: 240) else { continue }
                projectNames[id] = name
            }
        }
        var rows: [AOHostObservation] = []
        rows.reserveCapacity(min(response.sessions.count, 200))
        for row in response.sessions.prefix(1_000) {
            guard let id = row.id, AOHostObservation.validID(id),
                  let harness = row.harness, AOHostObservation.validHarness(harness),
                  let kind = row.kind else { continue }
            let rawProject = row.projectId.flatMap { $0.isEmpty ? nil : $0 }
            let projectID: String
            if let rawProject {
                guard AOHostObservation.validID(rawProject) else { continue }
                projectID = rawProject
            } else {
                projectID = AOHostMapping.standaloneProjectID
            }
            let role: AOHostRole
            switch kind {
            case "orchestrator": role = .orchestrator
            case "worker": role = .worker
            default: continue
            }
            guard let createdAt = AOAPIDate.parse(row.createdAt),
                  let updatedAt = AOAPIDate.parse(row.updatedAt) else { continue }
            let activity = activity(row.activity?.state)
            var observation = AOHostObservation(
                sessionID: id, projectID: projectID,
                projectName: projectNames[projectID] ?? (projectID == AOHostMapping.standaloneProjectID ? "Standalone" : nil),
                role: role, harness: harness,
                displayName: clean(row.displayName, limit: 240),
                branch: clean(row.branch, limit: 240),
                status: clean(row.status, limit: 64) ?? "unknown",
                displayStatus: clean(row.displayStatus, limit: 64),
                activity: activity,
                activityAt: AOAPIDate.parse(row.activity?.lastActivityAt),
                isTerminated: row.isTerminated == true,
                createdAt: createdAt, updatedAt: updatedAt,
                lastEventAt: AOAPIDate.parse(row.lastEventAt),
                observedAt: observedAt, instanceID: run.appRunID
            )
            observation.orchestration = AOHostMapping.projectGroup(for: observation)
            guard observation.valid else { continue }
            rows.append(observation)
        }
        rows.sort { $0.updatedAt > $1.updatedAt }
        return AOSnapshot(instanceID: run.appRunID, observedAt: observedAt,
                          projectNames: projectNames, sessions: Array(rows.prefix(200)))
    }

    private static func activity(_ raw: String?) -> AOHostActivity {
        switch raw {
        case "active": return .active
        case "idle": return .idle
        case "waiting_input": return .waitingInput
        case "blocked": return .blocked
        case "exited": return .exited
        default: return .unknown
        }
    }

    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let body = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !body.isEmpty, body.utf8.count <= limit else { return nil }
        guard !body.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return body
    }
}

/// Minimal SSE frame parser. Only event names and IDs are retained; payload
/// bodies are deliberately ignored so no conversation content enters the app.
public struct AOSSEParser {
    public struct Event: Equatable, Sendable {
        public let type: String
        public let id: String?
        public init(type: String, id: String?) { self.type = type; self.id = id }
    }

    private var type = ""
    private var id: String?
    private var dataBytes = 0

    public init() {}

    public mutating func consume(line rawLine: String) -> Event? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { type = ""; id = nil; dataBytes = 0 }
            guard !type.isEmpty, dataBytes <= 16_384 else { return nil }
            return Event(type: type, id: id)
        }
        if line.hasPrefix("event:") {
            let value = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard value.utf8.count <= 64,
                  value.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil else { return nil }
            type = value
        } else if line.hasPrefix("id:") {
            let value = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            guard value.utf8.count <= 64,
                  value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil else { return nil }
            id = value
        } else if line.hasPrefix("data:") {
            dataBytes += line.utf8.count
        }
        return nil
    }

    public static func invalidates(_ type: String) -> Bool {
        switch type {
        case "session_created", "session_updated", "pr_created", "pr_updated",
             "pr_check_recorded", "pr_session_changed", "pr_review_thread_added",
             "pr_review_thread_resolved":
            return true
        default:
            return false
        }
    }
}
