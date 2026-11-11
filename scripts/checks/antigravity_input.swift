import Foundation
import CSQLite

final class AgyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [HumanIntervention] = []
    func add(_ change: HumanIntervention) { lock.lock(); records.append(change); lock.unlock() }
    var values: [HumanIntervention] { lock.lock(); defer { lock.unlock() }; return records }
}

final class AgyCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [AntigravityHumanInput.Cancellation] = []
    func add(_ value: AntigravityHumanInput.Cancellation) { lock.lock(); records.append(value); lock.unlock() }
    var values: [AntigravityHumanInput.Cancellation] { lock.lock(); defer { lock.unlock() }; return records }
}

@main struct Checks {
    static var count = 0
    static func check(_ condition: Bool, _ message: String) { count += 1; if !condition { fatalError(message) } }
    static func vint(_ value: UInt64) -> Data {
        var n = value; var d = Data()
        repeat { let more = n > 127; d.append(UInt8(n & 127) | (more ? 128 : 0)); n >>= 7 } while n > 0
        return d
    }
    static func int(_ n: Int, _ value: UInt64) -> Data { vint(UInt64(n << 3)) + vint(value) }
    static func bytes(_ n: Int, _ value: Data) -> Data { vint(UInt64(n << 3 | 2)) + vint(UInt64(value.count)) + value }
    static func text(_ n: Int, _ value: String) -> Data { bytes(n, Data(value.utf8)) }
    static func metadata(_ identity: String = "execution-a", tool: String = "ask_question") -> Data {
        text(12, identity) + bytes(1, int(1, 200)) + bytes(8, int(1, 201)) + bytes(4, text(1, "call-a") + text(2, tool) + text(3, "SECRET ARGUMENTS"))
    }
    static func payload(_ status: Int = 2, type: Int = 132, request: Int? = nil, round: Int = 0) -> Data {
        var data = int(1, UInt64(type)) + int(4, UInt64(status)) + bytes(140, text(1, "SECRET BODY"))
        if let request { data += bytes(56, bytes(request, text(1, "SECRET QUESTION OR COMMAND"))) }
        for _ in 0..<round { data += bytes(147, text(2, "SECRET ANSWER")) }
        return data
    }
    static func step(_ status: Int = 2, tool: String = "ask_question", request: Int? = nil, round: Int = 0, identity: String = "execution-a") -> AntigravityHumanInput.Step? {
        AntigravityHumanInput.step(index: 26, type: 132, status: status, metadata: metadata(identity, tool: tool), payload: payload(status, request: request, round: round))
    }
    static func write(_ path: String, status: Int = 2, request: Int? = nil, round: Int = 0, index: Int = 26, tool: String = "ask_question", cancelledChoice: Bool = false) throws {
        var db: OpaquePointer?; check(sqlite3_open(path, &db) == SQLITE_OK, "fixture opens"); defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS steps(idx INTEGER PRIMARY KEY,step_type INTEGER,status INTEGER,metadata BLOB,step_payload BLOB)", nil, nil, nil) == SQLITE_OK, "fixture schema")
        var s: OpaquePointer?; sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO steps VALUES(?,132,?,?,?)", -1, &s, nil); defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(index)); sqlite3_bind_int(s, 2, Int32(status))
        let m = metadata(tool: tool)
        var p = payload(status, request: request, round: round)
        if cancelledChoice { p += bytes(147, bytes(1, bytes(22, text(1, "SECRET QUESTION OR COMMAND"))) + bytes(2, bytes(22, int(2, 1)))) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        m.withUnsafeBytes { _ = sqlite3_bind_blob(s, 3, $0.baseAddress, Int32(m.count), transient) }
        p.withUnsafeBytes { _ = sqlite3_bind_blob(s, 4, $0.baseAddress, Int32(p.count), transient) }
        check(sqlite3_step(s) == SQLITE_DONE, "fixture record")
    }
    static func wait(_ predicate: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(4)
        while Date() < until { if predicate() { return true }; Thread.sleep(forTimeInterval: 0.025) }
        return predicate()
    }
    static func executor(_ path: String, reason: Int = 2, index: Int = 26, identity: String = "execution-a") throws {
        var db: OpaquePointer?; check(sqlite3_open(path, &db) == SQLITE_OK, "executor fixture opens"); defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS executor_metadata(idx INTEGER PRIMARY KEY,data BLOB)", nil, nil, nil) == SQLITE_OK, "executor schema")
        var s: OpaquePointer?; sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO executor_metadata VALUES(1,?)", -1, &s, nil); defer { sqlite3_finalize(s) }
        let d = int(1, UInt64(reason)) + (index == 0 ? Data() : int(3, UInt64(index))) + text(9, identity) + text(12, "SECRET ERROR BODY")
        d.withUnsafeBytes { _ = sqlite3_bind_blob(s, 1, $0.baseAddress, Int32(d.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        check(sqlite3_step(s) == SQLITE_DONE, "executor stored")
    }
    static func main() throws {
        if CommandLine.arguments.count > 1 {
            let snapshot = AntigravityHumanInput.readSnapshot(path: CommandLine.arguments[1])
            check(snapshot?.cancellation != nil, "actual native user cancellation without Stop decoded")
            let store = SessionStore(); let at = ProcessInfo.processInfo.environment["AGENTPET_AGY_NATIVE_HOOK_AT"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? snapshot!.cancellation!.timestamp.addingTimeInterval(-1)
            store.apply(AgentEvent(sessionId: "native", agentKind: .antigravity, eventName: "working", timestamp: at), now: at)
            check(store.reconcileAntigravityCancellation(id: "native", cancellation: snapshot!.cancellation!)?.indicator == .read, "native cancellation stops blue and becomes green")
            print("PASS: native cancellation replay; no question/answer/arguments exported")
            return
        }
        check(step()?.kind == .choice, "native ask_question running is choice")
        check(step(9, tool: "run_command")?.kind == .permission, "native WAITING means user approval")
        check(step(tool: "run_command", request: 21)?.kind == .permission, "explicit permission request")
        check(step(tool: "mcp", request: 20)?.kind == .reply, "explicit elicitation reply")
        check(step(tool: "other", request: 22)?.kind == .choice, "native requested choice regardless tool name")
        check(step(tool: "run_command")?.kind == nil, "ordinary running command is blue")
        check(step(3)?.kind == nil && step(3)?.terminal == true, "done question is not pending")
        check(step(round: 1)?.kind == nil, "completed UI response while tool still runs cannot ask again")
        check(step(request: 21, round: 1)?.requestID != step(request: 21)?.requestID, "new interaction round has new identity")
        let request = bytes(22, text(1, "SECRET QUESTION"))
        let cancelledResponse = bytes(147, bytes(1, request) + bytes(2, bytes(22, int(2, 1))))
        let skipped = payload(request: nil) + bytes(56, request) + cancelledResponse
        check(AntigravityHumanInput.step(index: 26, type: 132, status: 2, metadata: metadata(), payload: skipped)?.kind == nil, "cancelled choice with retained request is not asked again")
        let differentRequest = payload(request: nil) + bytes(56, bytes(22, text(1, "NEW QUESTION"))) + cancelledResponse
        check(AntigravityHumanInput.step(index: 26, type: 132, status: 2, metadata: metadata(), payload: differentRequest)?.kind == .choice, "different current choice still asks after prior response")
        check(step(identity: "execution-b")?.requestID != step()?.requestID, "reused step index in new execution is distinct")
        check(step(identity: "invalid:identity") == nil, "identity delimiter rejected")
        check(AntigravityHumanInput.databasePath(sessionID: "../../other") == nil, "invalid conversation path rejected")
        check(AntigravityHumanInput.step(index: 1, type: 132, status: 2, metadata: metadata(), payload: payload(3)) == nil, "inconsistent snapshot rejected")
        check(AntigravityHumanInput.step(index: 1, type: 132, status: 2, metadata: Data([0xFF]), payload: payload()) == nil, "malformed protobuf rejected")
        let ordered = SessionStore(); let t = Date(timeIntervalSince1970: 100)
        ordered.apply(AgentEvent(sessionId: "order", agentKind: .antigravity, eventName: "working", timestamp: t), now: t)
        var asked = AgentEvent(sessionId: "order", agentKind: .antigravity, eventName: "HumanInput", timestamp: t.addingTimeInterval(3))
        asked.humanIntervention = HumanIntervention(action: .asked, requests: [HumanRequest(id: "order-q", kind: .choice, createdAt: t.addingTimeInterval(3))])
        ordered.apply(asked, now: asked.timestamp)
        var answer = asked; answer.timestamp = t.addingTimeInterval(5)
        answer.humanIntervention = HumanIntervention(action: .resolved, requests: asked.humanIntervention!.requests)
        ordered.apply(answer, now: answer.timestamp)
        var stop = AgentEvent(sessionId: "order", agentKind: .antigravity, eventName: "done", timestamp: t.addingTimeInterval(4))
        stop.turnResult = .completed; ordered.apply(stop, now: t.addingTimeInterval(6))
        check(ordered.session(id: "order")!.state == .done && ordered.session(id: "order")!.indicator == .unread, "observer timestamp cannot discard delayed native completion")
        ordered.apply(AgentEvent(sessionId: "order", agentKind: .antigravity, eventName: "working", timestamp: t.addingTimeInterval(2)), now: t.addingTimeInterval(7))
        check(ordered.session(id: "order")!.state == .done, "true old hook still cannot reopen completed task")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("native.db").path
        try write(path)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let native = AntigravityHumanInput.read(path: path)!
        check(native.count == 1 && native[0].kind == .choice, "native SQLite exact step read")
        check(before == (try Data(contentsOf: URL(fileURLWithPath: path))), "native database is unchanged")
        check(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["native.db"], "observer creates no journal or lock files")
        try Data().write(to: URL(fileURLWithPath: path + "-journal"))
        check(AntigravityHumanInput.read(path: path) == nil, "active transaction skipped"); try FileManager.default.removeItem(atPath: path + "-journal")
        try Data().write(to: URL(fileURLWithPath: path + "-wal"))
        check(AntigravityHumanInput.read(path: path) == nil, "unsupported WAL snapshot skipped"); try FileManager.default.removeItem(atPath: path + "-wal")
        let probe = AgyProbe(); let watcher = AntigravityHumanInputWatcher { _, change, _ in probe.add(change) }
        watcher.watch(sessionID: "fixture", path: path)
        check(wait { probe.values.count == 1 }, "file watcher initial waiting")
        let store = SessionStore(); let initial = Date().addingTimeInterval(-10)
        store.apply(AgentEvent(sessionId: "fixture", agentKind: .antigravity, eventName: "working", timestamp: initial), now: initial)
        func apply(_ change: HumanIntervention) {
            let at = Date(); var event = AgentEvent(sessionId: "fixture", agentKind: .antigravity, eventName: "HumanInput", timestamp: at)
            event.humanIntervention = change; store.apply(event, now: at)
        }
        apply(probe.values[0]); let pending = store.session(id: "fixture")!
        check(pending.indicator == .attention && pending.message == "等待你的选择", "real watcher event orange")
        check(store.markOpened(pending, at: Date()) && store.session(id: "fixture")!.indicator == .read, "click green preserves choice")
        try write(path)
        Thread.sleep(forTimeInterval: 0.6)
        check(probe.values.count == 1, "duplicate native writes do not notify")
        let resumedProbe = AgyProbe(); let resumed = AntigravityHumanInputWatcher { _, c, _ in resumedProbe.add(c) }
        resumed.watch(sessionID: "restored", path: path, pending: pending.humanRequests ?? [])
        Thread.sleep(forTimeInterval: 0.6)
        check(resumedProbe.values.isEmpty, "restart waiting retains read without duplicate")
        try write(path, status: 3, round: 1)
        check(wait { probe.values.count == 2 && resumedProbe.values.count == 1 }, "answer resolves native request on both watches")
        check(probe.values[1].action == .resolved && probe.values[1].requests[0].id == pending.humanRequests![0].id, "exact answered identity")
        apply(probe.values[1]); check(store.session(id: "fixture")!.indicator == .running, "actual answer resumes blue")
        try write(path, request: 21, round: 1)
        check(wait { probe.values.count == 3 }, "next permission in same step emits new request")
        apply(probe.values[2]); check(store.session(id: "fixture")!.indicator == .attention && store.session(id: "fixture")!.message == "等待批准", "next request orange despite previous click")
        try write(path, status: 6, round: 1)
        check(wait { probe.values.count == 4 }, "native cancelled step clears waiting")
        // Replacement, rather than append, must keep the known-path watch alive.
        let replacement = root.appendingPathComponent("replacement.db").path
        try write(replacement, index: 30)
        try FileManager.default.removeItem(atPath: path); try FileManager.default.moveItem(atPath: replacement, toPath: path)
        check(wait { probe.values.count == 5 }, "atomic native database replacement reattaches")
        let data = try JSONEncoder().encode(probe.values)
        check(!String(decoding: data, as: UTF8.self).contains("SECRET"), "observer events contain no questions/answers/arguments")
        watcher.retain(sessionIDs: []); resumed.retain(sessionIDs: [])

        let skippedPath = root.appendingPathComponent("skipped.db").path
        try write(skippedPath, request: 22)
        let skipProbe = AgyProbe(); let skipWatcher = AntigravityHumanInputWatcher { _, c, _ in skipProbe.add(c) }
        skipWatcher.watch(sessionID: "skip", path: skippedPath)
        check(wait { skipProbe.values.count == 1 }, "choice fixture asks before cancellation")
        try write(skippedPath, request: 22, cancelledChoice: true)
        check(wait { skipProbe.values.count == 2 }, "skipped choice resolves while native tool remains RUNNING")
        check(skipProbe.values[1].action == .resolved && skipProbe.values[1].requests[0].id == skipProbe.values[0].requests[0].id, "skip clears exact old request without asking it again")
        let skipStore = SessionStore()
        let skipStart = Date().addingTimeInterval(-10)
        skipStore.apply(AgentEvent(sessionId: "skip", agentKind: .antigravity, eventName: "working", timestamp: skipStart), now: skipStart)
        for change in skipProbe.values {
            var e = AgentEvent(sessionId: "skip", agentKind: .antigravity, eventName: "HumanInput", timestamp: Date()); e.humanIntervention = change
            skipStore.apply(e, now: e.timestamp)
        }
        check(skipStore.session(id: "skip")!.indicator == .running && skipStore.session(id: "skip")!.humanRequests == [], "choice skip alone resumes blue, not a false completed turn")
        skipWatcher.retain(sessionIDs: [])

        let cancelledPath = root.appendingPathComponent("cancelled.db").path
        try write(cancelledPath)
        try executor(cancelledPath, reason: 4)
        check(AntigravityHumanInput.readSnapshot(path: cancelledPath)?.cancellation == nil, "normal executor return is not cancellation")
        let cancellationProbe = AgyCancellationProbe()
        let cancellationWatcher = AntigravityHumanInputWatcher(cancellationHandler: { _, value in cancellationProbe.add(value) }) { _, _, _ in }
        cancellationWatcher.watch(sessionID: "cancelled", path: cancelledPath, latestHookAt: Date(timeIntervalSince1970: 199))
        Thread.sleep(forTimeInterval: 0.6)
        try executor(cancelledPath)
        check(wait { cancellationProbe.values.count == 1 }, "Esc executor amendment emits cancellation without Stop hook")
        var cancellation = cancellationProbe.values[0]
        cancellation.observedAt = nil // Isolate the deterministic store clock below.
        let stopped = SessionStore(); stopped.persistenceURL = root.appendingPathComponent("stopped.json")
        let start = Date(timeIntervalSince1970: 199)
        stopped.apply(AgentEvent(sessionId: "cancelled", agentKind: .antigravity, eventName: "working", timestamp: start), now: start)
        var choice = AgentEvent(sessionId: "cancelled", agentKind: .antigravity, eventName: "HumanInput", timestamp: start)
        choice.humanIntervention = HumanIntervention(action: .asked, requests: [HumanRequest(id: "agy:26:execution-a:0:choice", kind: .choice, createdAt: start)])
        stopped.apply(choice, now: start)
        let terminal = stopped.reconcileAntigravityCancellation(id: "cancelled", cancellation: cancellation)!
        check(terminal.state == .done && terminal.indicator == .read && terminal.humanRequests == [] && terminal.turnEndedAt != nil, "Esc clears choice and freezes green stopped state")
        check(!terminal.hasUnread && terminal.readAt == nil && !terminal.hasReadReceipt, "manual stop does not forge a click receipt")
        stopped.apply(AgentEvent(sessionId: "cancelled", agentKind: .antigravity, eventName: "working", timestamp: Date(timeIntervalSince1970: 202)), now: Date(timeIntervalSince1970: 202))
        check(stopped.session(id: "cancelled")!.state == .done, "late tool cannot reopen explicit cancellation")
        let restoredStop = SessionStore(); restoredStop.persistenceURL = stopped.persistenceURL; restoredStop.restoreCodexSessions()
        check(restoredStop.session(id: "cancelled")!.indicator == .read, "green manual stop survives restart")
        stopped.prune(now: Date(timeIntervalSince1970: 232))
        check(stopped.session(id: "cancelled")!.state == .idle, "manual stop hides after grace period without click")
        var next = AgentEvent(sessionId: "cancelled", agentKind: .antigravity, eventName: "working", timestamp: Date(timeIntervalSince1970: 233)); next.antigravityNewInvocation = true
        stopped.apply(next, now: next.timestamp)
        check(stopped.session(id: "cancelled")!.indicator == .running, "fresh invocation resumes blue after manual stop")
        check(stopped.reconcileAntigravityCancellation(id: "cancelled", cancellation: cancellation) == nil && stopped.session(id: "cancelled")!.state == .working, "old executor cancellation cannot stop a new task")
        try executor(cancelledPath)
        Thread.sleep(forTimeInterval: 0.6)
        check(cancellationProbe.values.count == 1, "duplicate executor cancellation is not delivered twice")
        try executor(cancelledPath, identity: "old-execution")
        check(AntigravityHumanInput.readSnapshot(path: cancelledPath)?.cancellation == nil, "different execution cannot cancel latest step")
        try executor(cancelledPath, index: 25)
        check(AntigravityHumanInput.readSnapshot(path: cancelledPath)?.cancellation == nil, "old executor step cannot end later native work")
        let firstStepPath = root.appendingPathComponent("first-step.db").path
        try write(firstStepPath, index: 0)
        try executor(firstStepPath, index: 0)
        check(AntigravityHumanInput.readSnapshot(path: firstStepPath)?.cancellation?.lastStepIndex == 0, "proto3 omitted zero index still observes first-step cancellation")
        cancellationWatcher.retain(sessionIDs: [])
        // PreInvocation counts include the native thinking step before its
        // delayed DB flush. The second Hook can still see only old cancellation.
        let boundaryPath = root.appendingPathComponent("boundary.db").path
        try write(boundaryPath, status: 3, index: 0)
        try executor(boundaryPath, index: 0)
        let boundaryProbe = AgyCancellationProbe()
        let boundaryWatcher = AntigravityHumanInputWatcher(cancellationHandler: { _, c in boundaryProbe.add(c) }) { _, _, _ in }
        let boundaryHook = Date(timeIntervalSince1970: 203)
        boundaryWatcher.watch(sessionID: "boundary", path: boundaryPath, latestHookAt: boundaryHook, stepFloor: 1)
        Thread.sleep(forTimeInterval: 0.6)
        check(boundaryProbe.values.isEmpty, "new native step floor rejects old cancellation still on disk")
        try write(boundaryPath, status: 3, index: 1)
        try executor(boundaryPath, index: 1)
        check(wait { boundaryProbe.values.count == 1 }, "current cancellation flush stops thinking despite step timestamp before Hook")
        check(boundaryProbe.values[0].expectedHookAt == boundaryHook && boundaryProbe.values[0].observedAt != nil, "watcher captures exact Hook fence and observation end time")
        let laterHook = boundaryHook.addingTimeInterval(1)
        boundaryWatcher.watch(sessionID: "boundary", path: boundaryPath, latestHookAt: laterHook, stepFloor: 1)
        check(wait { boundaryProbe.values.count == 2 }, "new Hook fence rechecks same cancellation instead of permanently deduplicating")
        check(boundaryProbe.values[1].expectedHookAt == laterHook, "new callback carries new Hook fence")
        try executor(boundaryPath, index: 1)
        Thread.sleep(forTimeInterval: 0.6)
        check(boundaryProbe.values.count == 2, "same cancellation is deduplicated within its Hook revision")
        boundaryWatcher.retain(sessionIDs: [])
        print("PASS: \(count) Antigravity input checks (native steps, read lifecycle, restart, file changes, privacy)")
    }
}
