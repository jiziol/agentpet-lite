import Foundation

private struct Fixture: Decodable {
    let schema: Int
    let origin: String
    let scenarios: [Scenario]
}
private struct Scenario: Decodable {
    let id: String
    let kind: AgentKind
    let session: String
    let actions: [Action]
}
private struct Action: Decodable {
    let op: String
    let at: Double
    let session: String?
    let event: String?
    let requests: [String]?
    let requestKind: HumanRequest.Kind?
    let capture: String?
    let turn: String?
    let started: Double?
    let result: CodexTurnResult?
    let nativeJSON: String?
    let expect: Expected?
}
private struct Expected: Decodable {
    let exists: Bool?
    let state: AgentState?
    let indicator: AgentSession.Indicator?
    let pending: [String]?
    let unread: Bool?
    let result: CodexTurnResult?
    let resultAbsent: Bool?
    let disconnected: Bool?

    private enum CodingKeys: String, CodingKey { case exists, state, indicator, pending, unread, result, resultAbsent, disconnected }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exists = try c.decodeIfPresent(Bool.self, forKey: .exists)
        state = try c.decodeIfPresent(AgentState.self, forKey: .state)
        if let raw = try c.decodeIfPresent(String.self, forKey: .indicator) {
            guard let value = AgentSession.Indicator(rawValue: raw) else { throw ReplayError.invalid("indicator") }
            indicator = value
        } else { indicator = nil }
        pending = try c.decodeIfPresent([String].self, forKey: .pending)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread)
        result = try c.decodeIfPresent(CodexTurnResult.self, forKey: .result)
        resultAbsent = try c.decodeIfPresent(Bool.self, forKey: .resultAbsent)
        disconnected = try c.decodeIfPresent(Bool.self, forKey: .disconnected)
    }
}
private enum ReplayError: Error { case invalid(String), mismatch(String) }

@main private struct ReplayChecks {
    static func checkNative(_ path: String) throws {
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline)
        var tracker = CodexHumanInputTracker(), asked = 0, resolved = 0
        for line in lines {
            if let change = tracker.ingest(Data(line.utf8))?.0 {
                if change.action == .asked { asked += change.requests.count }
                else { resolved += change.requests.count }
            }
        }
        // Fixed observations from the aliased R0 corpus. "resolved" includes
        // new-turn retirement; it is not a count of answers given by the user.
        guard lines.count == 95, asked == 9, resolved == 8, tracker.pending.isEmpty else {
            throw ReplayError.mismatch("native metadata corpus counts")
        }
        print("PASS: 95 aliased native Codex records; asked=9, resolved/retired=8, outstanding=0")
    }

    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--native" {
            try checkNative(CommandLine.arguments[2]); return
        }
        guard CommandLine.arguments.count == 2 else { throw ReplayError.invalid("fixture path required") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        guard fixture.schema == 1, fixture.origin == "synthetic-metadata-only", !fixture.scenarios.isEmpty else {
            throw ReplayError.invalid("unsupported fixture")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentpet-refactor-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0, steps = 0
        for scenario in fixture.scenarios {
            var store = SessionStore()
            let persistence = root.appendingPathComponent(scenario.id + ".json")
            store.persistenceURL = persistence
            var clicks: [String: AgentSession] = [:]
            var tracker = CodexHumanInputTracker()
            for action in scenario.actions {
                let at = Date(timeIntervalSince1970: action.at)
                let id = action.session ?? scenario.session
                switch action.op {
                case "event", "asked", "answered":
                    var event = AgentEvent(sessionId: id, agentKind: scenario.kind,
                        eventName: action.event ?? (action.op == "asked" ? "waiting" : "working"),
                        project: "/synthetic/shared-project", timestamp: at)
                    if scenario.kind == .opencode {
                        event.opencodeTurnID = action.turn ?? "synthetic-turn"
                        event.opencodeNewTurn = action.op == "event" && event.eventName == "working" && store.session(id: id) == nil
                        event.opencodeProcessID = 2_000_000_000
                    }
                    if action.op != "event" {
                        event.humanIntervention = HumanIntervention(action: action.op == "asked" ? .asked : .resolved,
                            requests: (action.requests ?? []).map { HumanRequest(id: $0, kind: action.requestKind ?? .choice, createdAt: at) })
                    }
                    store.apply(event, now: at)
                case "capture":
                    guard let name = action.capture, let session = store.session(id: id) else { throw ReplayError.invalid("capture") }
                    clicks[name] = session
                case "open":
                    guard let name = action.capture, let clicked = clicks[name] else { throw ReplayError.invalid("open") }
                    store.markOpened(clicked, at: at)
                case "prune": store.prune(now: at)
                case "restart":
                    let restored = SessionStore(); restored.persistenceURL = persistence
                    restored.restoreCodexSessions(); store = restored
                case "lifecycle":
                    guard let turn = action.turn else { throw ReplayError.invalid("turn") }
                    store.reconcileCodexLifecycle(id: id, event: CodexLifecycle(turnID: turn, timestamp: at,
                        startedAt: action.started.map(Date.init(timeIntervalSince1970:)), result: action.result))
                case "native":
                    guard let raw = action.nativeJSON else { throw ReplayError.invalid("native") }
                    if let (change, timestamp) = tracker.ingest(Data(raw.utf8)) {
                        var event = AgentEvent(sessionId: id, agentKind: scenario.kind, eventName: "HumanInput", timestamp: timestamp)
                        event.humanIntervention = change; store.apply(event, now: timestamp)
                    }
                case "disconnect":
                    store.reconcileOpencodeLiveness(now: at, processIsAlive: { _ in false })
                default: throw ReplayError.invalid("unknown action")
                }
                if let path = ProcessInfo.processInfo.environment["AGENTPET_REPLAY_TRACE"] {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let sessions = try encoder.encode(store.sessions.sorted { $0.id < $1.id })
                    let line = "\(scenario.id)\t\(steps)\t" + String(decoding: sessions, as: UTF8.self) + "\n"
                    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                    try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8)); try handle.close()
                }
                steps += 1
                if let expected = action.expect {
                    let actual = store.session(id: id)
                    func require(_ condition: Bool, _ field: String) throws {
                        checks += 1
                        if !condition { throw ReplayError.mismatch(scenario.id + " step " + String(steps) + " " + field) }
                    }
                    if let exists = expected.exists { try require((actual != nil) == exists, "exists") }
                    if let state = expected.state { try require(actual?.state == state, "state") }
                    if let indicator = expected.indicator { try require(actual?.indicator == indicator, "indicator") }
                    if let pending = expected.pending { try require((actual?.humanRequests ?? []).map(\.id).sorted() == pending.sorted(), "pending IDs") }
                    if let unread = expected.unread { try require(actual?.hasUnread == unread, "unread") }
                    if let result = expected.result { try require(actual?.taskResult == result, "result") }
                    if let absent = expected.resultAbsent { try require((actual?.taskResult == nil) == absent, "result absent") }
                    if let disconnected = expected.disconnected { try require((actual?.opencodeDisconnectedAt != nil) == disconnected, "disconnected") }
                }
            }
        }
        print("PASS: \(fixture.scenarios.count) fixed metadata replay scenarios, \(steps) actions, \(checks) contract checks; synthetic data only")
    }
}
