import Foundation
import XCTest
@testable import AgentPetCore

private final class AionCancelProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var signals: [AionUiCancellationSignal] = []
    private var checkpoints: [AionUiCancellationWatchCheckpoint] = []
    func add(_ signal: AionUiCancellationSignal) {
        condition.lock(); signals.append(signal); condition.broadcast(); condition.unlock()
    }
    func record(_ checkpoint: AionUiCancellationWatchCheckpoint) {
        condition.lock(); checkpoints.append(checkpoint); condition.broadcast(); condition.unlock()
    }
    var values: [AionUiCancellationSignal] { condition.lock(); defer { condition.unlock() }; return signals }
    var events: [AionUiCancellationWatchCheckpoint] { condition.lock(); defer { condition.unlock() }; return checkpoints }
    var mark: Int { condition.lock(); defer { condition.unlock() }; return checkpoints.count }
    func wait(after mark: Int = 0, matching predicate: (AionUiCancellationWatchCheckpoint) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        condition.lock(); defer { condition.unlock() }
        while !checkpoints.dropFirst(mark).contains(where: predicate) {
            if !condition.wait(until: deadline) {
                return checkpoints.dropFirst(mark).contains(where: predicate)
            }
        }
        return true
    }
    func waitForSignals(_ count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        condition.lock(); defer { condition.unlock() }
        while signals.count < count {
            if !condition.wait(until: deadline) { return signals.count >= count }
        }
        return true
    }
    var activeIDs: Set<UUID> {
        condition.lock(); defer { condition.unlock() }
        return checkpoints.reduce(into: Set<UUID>()) { ids, event in
            switch event {
            case .registered(_, _, let id): ids.insert(id)
            case .cancelled(_, _, let id): ids.remove(id)
            default: break
            }
        }
    }
}

private final class AionCancelClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Date) { lock.lock(); self.value = value; lock.unlock() }
}

private final class AionCancelActivationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let path: String
    private let directory: Bool
    private var held: [DispatchSourceFileSystemObject] = []
    private var released = false
    init(path: String, directory: Bool = true) { self.path = path; self.directory = directory }
    func activate(path: String, directory: Bool, source: DispatchSourceFileSystemObject) {
        lock.lock()
        if !released && directory == self.directory && path == self.path {
            held.append(source); lock.unlock()
        } else { lock.unlock(); source.resume() }
    }
    func release() {
        lock.lock(); released = true; let sources = held; held.removeAll(); lock.unlock()
        for source in sources { source.resume() }
    }
    deinit { release() }
}

final class AionUiCancellationLogTests: XCTestCase {
    private let id = "00000000-0000-4000-8000-000000000003"
    private let host = "e812694a"
    private let turn = "turn_c15c3cb3"
    private var base: Date { ISO8601DateFormatter().date(from: "2026-10-04T08:52:19Z")! }
    private var target: AionUiConversation { AionUiConversation(id: host, nativeSessionID: id, agentKind: .antigravity) }
    private func data(_ message: String, at: Date, turn: String? = nil, host: String? = nil,
                      module: String = "aionui_conversation::runtime_state", level: String = "INFO") -> Data {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields = ["message": message, "conversation_id": host ?? self.host]
        if let turn { fields["turn_id"] = turn }
        return try! JSONSerialization.data(withJSONObject: ["timestamp": format.string(from: at), "level": level,
            "target": module, "fields": fields])
    }
    private func record(_ action: AionUiCancellationLog.Action, at: Date, turn: String? = nil, host: String? = nil) -> AionUiCancellationLog.Record {
        AionUiCancellationLog.Record(action: action, conversationID: host ?? self.host, turnID: turn, timestamp: at)
    }
    private func session(at: Date) -> AgentSession {
        var s = AgentSession(id: id, agentKind: .antigravity, state: .working, source: .hook, updatedAt: at)
        s.aionUiConversation = target; s.antigravityEventAt = at
        return s
    }
    private func context(at: Date) -> AionUiCancellationContext {
        AionUiCancellationContext(conversation: target, createdAt: at, hookAt: at)
    }
    private func signal(_ context: AionUiCancellationContext, at: Date) -> AionUiCancellationSignal {
        AionUiCancellationSignal(conversation: context.conversation, createdAt: context.createdAt,
            expectedHookAt: context.hookAt, turnID: turn, claimedAt: context.hookAt.addingTimeInterval(-7),
            requestedAt: at.addingTimeInterval(-2), timestamp: at)
    }
    private func applyWorking(_ store: SessionStore, at: Date) {
        var e = AgentEvent(sessionId: id, agentKind: .antigravity, eventName: "PreInvocation", timestamp: at)
        e.antigravityNewInvocation = true; e.antigravityStepFloor = 127
        let s = store.apply(e, now: at)!
        let record = AionUiMetadata.Record(conversation: target, title: "test")
        store.updateAionUiMetadata(id: id, createdAt: s.createdAt, record: record)
    }
    func testInstalledStructuredAcknowledgementPreservesHostAndTurn() {
        let line = #"{"timestamp":"2026-10-04T08:52:35.069049Z","level":"INFO","fields":{"message":"Stream cancel acknowledged","conversation_id":"e812694a","turn_id":"turn_c15c3cb3"},"target":"aionui_conversation::service"}"#
        let r = AionUiCancellationLog.parse(Data(line.utf8), observedAt: base.addingTimeInterval(20))!
        XCTAssertEqual(r.action, .acknowledged); XCTAssertEqual(r.conversationID, host); XCTAssertEqual(r.turnID, turn)
        XCTAssertEqual(r.timestamp.timeIntervalSince(base), 16.069, accuracy: 0.001)
    }
    func testWrongModuleTextFinishIdleKillFailureAndUnstructuredOutputAreIgnored() {
        let now = base.addingTimeInterval(20)
        for d in [data("Stream cancel acknowledged", at: base, turn: turn, module: "assistant"),
                  data("Stream cancel acknowledged", at: base, turn: turn),
                  data("Stream cancel acknowledged", at: base, turn: turn, module: "aionui_conversation::service", level: "WARN"),
                  data("Failed to cancel agent", at: base, turn: turn, module: "aionui_conversation::service"),
                  data("feedback.runtime.turn_terminal", at: base, turn: turn, module: "aionui_feedback_diagnostics"),
                  data("Idle kill: task removed from manager", at: base, module: "aionui_ai_agent::task_manager"),
                  Data("Stream cancel acknowledged".utf8), Data(repeating: 65, count: 4_097)] {
            XCTAssertNil(AionUiCancellationLog.parse(d, observedAt: now))
        }
    }
    func testBadIDMissingTurnOldAndFutureRecordsAreIgnored() {
        let now = base.addingTimeInterval(20)
        for d in [data("Stream cancel acknowledged", at: base, module: "aionui_conversation::service"),
                  data("conversation runtime turn claimed", at: base, turn: "../turn"),
                  data("conversation marked cancelling", at: base, host: "../host"),
                  data("conversation marked cancelling", at: base, host: host + "\0other"),
                  data("conversation marked cancelling", at: base.addingTimeInterval(-86_401)),
                  data("conversation marked cancelling", at: now.addingTimeInterval(2))] {
            XCTAssertNil(AionUiCancellationLog.parse(d, observedAt: now))
        }
    }
    func testRequestAloneDoesNotStopAndMatchingAcknowledgementStopsOnce() {
        var tracker = AionUiCancellationTracker(); let c = context(at: base.addingTimeInterval(7))
        XCTAssertNil(tracker.consume(record(.claimed, at: base, turn: turn), context: c))
        XCTAssertNil(tracker.consume(record(.requested, at: base.addingTimeInterval(14)), context: c))
        let ack = record(.acknowledged, at: base.addingTimeInterval(16), turn: turn)
        XCTAssertEqual(tracker.consume(ack, context: c)?.expectedHookAt, c.hookAt)
        XCTAssertNil(tracker.consume(ack, context: c))
    }
    func testDifferentConversationOrTurnCannotStopCurrentInvocation() {
        var tracker = AionUiCancellationTracker(); let c = context(at: base.addingTimeInterval(7))
        _ = tracker.consume(record(.claimed, at: base, turn: turn), context: c)
        _ = tracker.consume(record(.requested, at: base.addingTimeInterval(14)), context: c)
        XCTAssertNil(tracker.consume(record(.acknowledged, at: base.addingTimeInterval(16), turn: turn, host: "other"), context: c))
        XCTAssertNil(tracker.consume(record(.acknowledged, at: base.addingTimeInterval(16), turn: "turn_other"), context: c))
    }
    func testNewHostTurnRejectsLateOldAcknowledgement() {
        var tracker = AionUiCancellationTracker(); let c = context(at: base.addingTimeInterval(20))
        _ = tracker.consume(record(.claimed, at: base, turn: turn), context: c)
        _ = tracker.consume(record(.requested, at: base.addingTimeInterval(14)), context: c)
        _ = tracker.consume(record(.claimed, at: base.addingTimeInterval(19), turn: "turn_next"), context: c)
        XCTAssertNil(tracker.consume(record(.acknowledged, at: base.addingTimeInterval(21), turn: turn), context: c))
        _ = tracker.consume(record(.requested, at: base.addingTimeInterval(22)), context: c)
        XCTAssertNotNil(tracker.consume(record(.acknowledged, at: base.addingTimeInterval(24), turn: "turn_next"), context: c))
    }
    func testRestartAcknowledgementCannotBecomeManualStop() {
        var tracker = AionUiCancellationTracker(); let c = context(at: base.addingTimeInterval(7))
        _ = tracker.consume(record(.claimed, at: base, turn: turn), context: c)
        _ = tracker.consume(record(.restarting, at: base.addingTimeInterval(13)), context: c)
        _ = tracker.consume(record(.requested, at: base.addingTimeInterval(14)), context: c)
        XCTAssertNil(tracker.consume(record(.acknowledged, at: base.addingTimeInterval(16), turn: turn), context: c))
    }
    func testMissingClaimRequestAndNewerUnobservedNativeHookAreConservative() {
        let c = context(at: base.addingTimeInterval(7))
        var t = AionUiCancellationTracker()
        XCTAssertNil(t.consume(record(.acknowledged, at: base.addingTimeInterval(16), turn: turn), context: c))
        _ = t.consume(record(.claimed, at: base.addingTimeInterval(17), turn: "turn_next"), context: c)
        _ = t.consume(record(.requested, at: base.addingTimeInterval(18)), context: c)
        XCTAssertNil(t.consume(record(.acknowledged, at: base.addingTimeInterval(20), turn: "turn_next"), context: c))
    }
    func testAcknowledgementStopsGreenClearsWaitAndFreezesAtHostTime() {
        let store = SessionStore(); let hook = base.addingTimeInterval(7); applyWorking(store, at: hook)
        var e = AgentEvent(sessionId: id, agentKind: .antigravity, eventName: "HumanInput", timestamp: hook.addingTimeInterval(0.1))
        e.humanIntervention = HumanIntervention(action: .asked, requests: [HumanRequest(id: "choice", kind: .choice, createdAt: hook)])
        store.apply(e, now: e.timestamp)
        let s = store.session(id: id)!
        let c = AionUiCancellationContext(conversation: target, createdAt: s.createdAt, hookAt: s.antigravityEventAt!)
        let ack = signal(c, at: base.addingTimeInterval(16))
        let stopped = store.reconcileAionUiCancellation(ack, observedAt: base.addingTimeInterval(100))!
        XCTAssertEqual(stopped.indicator, .read); XCTAssertTrue(stopped.isStopped); XCTAssertFalse(stopped.hasUnread)
        XCTAssertNil(stopped.readAt); XCTAssertEqual(stopped.humanRequests, [])
        XCTAssertEqual(stopped.turnEndedAt, ack.timestamp); XCTAssertEqual(stopped.antigravityStepFloor, 127)
        XCTAssertNil(store.reconcileAionUiCancellation(ack, observedAt: base.addingTimeInterval(101)))
    }
    func testUnhostedSessionWrongBindingAndRecreatedSessionRejectSignal() {
        let store = SessionStore(); let hook = base.addingTimeInterval(7); applyWorking(store, at: hook)
        let old = signal(context(at: hook), at: base.addingTimeInterval(16))
        store.remove(id: id)
        var e = AgentEvent(sessionId: id, agentKind: .antigravity, eventName: "PreInvocation", timestamp: hook)
        e.antigravityNewInvocation = true
        store.apply(e, now: hook)
        XCTAssertNil(store.reconcileAionUiCancellation(old, observedAt: base.addingTimeInterval(20)))
        store.remove(id: id); applyWorking(store, at: base.addingTimeInterval(30))
        XCTAssertNil(store.reconcileAionUiCancellation(old, observedAt: base.addingTimeInterval(40)))
        XCTAssertEqual(store.session(id: id)?.indicator, .running)
    }
    func testQueuedSignalIsRejectedAfterNewHookAndLateToolCannotReviveStoppedTurn() {
        let store = SessionStore(); let hook = base.addingTimeInterval(7); applyWorking(store, at: hook)
        let old = signal(context(at: hook), at: base.addingTimeInterval(16))
        var e = AgentEvent(sessionId: id, agentKind: .antigravity, eventName: "PreToolUse", timestamp: base.addingTimeInterval(10))
        store.apply(e, now: e.timestamp)
        XCTAssertNil(store.reconcileAionUiCancellation(old, observedAt: base.addingTimeInterval(20)))
        let s = store.session(id: id)!
        let current = signal(AionUiCancellationContext(conversation: target, createdAt: s.createdAt, hookAt: s.antigravityEventAt!), at: base.addingTimeInterval(16))
        XCTAssertNotNil(store.reconcileAionUiCancellation(current, observedAt: base.addingTimeInterval(20)))
        e.timestamp = base.addingTimeInterval(21); e.eventName = "PostToolUse"
        XCTAssertNil(store.apply(e, now: e.timestamp)); XCTAssertEqual(store.session(id: id)?.indicator, .read)
        applyWorking(store, at: base.addingTimeInterval(30))
        XCTAssertEqual(store.session(id: id)?.indicator, .running)
        XCTAssertNil(store.reconcileAionUiCancellation(current, observedAt: base.addingTimeInterval(31)))
    }
    private var testCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }
    private var observedAt: Date { base.addingTimeInterval(20) }
    private var hookAt: Date { base.addingTimeInterval(7) }
    private func dailyPath(_ root: URL, at: Date? = nil) -> URL {
        let c = testCalendar.dateComponents([.year, .month, .day], from: at ?? observedAt)
        return root.appendingPathComponent(String(format: "%04d/%02d/%02d/%04d-%02d-%02d.aioncore.log",
            c.year!, c.month!, c.day!, c.year!, c.month!, c.day!))
    }
    private func logPath(_ root: URL, at: Date? = nil) throws -> URL {
        let path = dailyPath(root, at: at)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        return path
    }
    private func prefix(turn: String? = nil, claimedAt: Date? = nil, requestedAt: Date? = nil) -> Data {
        data("conversation runtime turn claimed", at: claimedAt ?? base, turn: turn ?? self.turn) + Data([10]) +
            data("conversation marked cancelling", at: requestedAt ?? base.addingTimeInterval(14)) + Data([10])
    }
    private func acknowledgement(turn: String? = nil, at: Date? = nil) -> Data {
        data("Stream cancel acknowledged", at: at ?? base.addingTimeInterval(16), turn: turn ?? self.turn,
            module: "aionui_conversation::service")
    }
    private func append(_ bytes: Data, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
    }
    private func makeWatcher(_ root: URL, probe: AionCancelProbe, clock: AionCancelClock? = nil,
                             gate: AionCancelActivationGate? = nil) -> AionUiCancellationLogWatcher {
        let clock = clock ?? AionCancelClock(observedAt)
        return AionUiCancellationLogWatcher(root: root.path, clock: { clock.read() }, calendar: testCalendar,
            activateSource: { path, directory, source in
                if let gate { gate.activate(path: path, directory: directory, source: source) }
                else { source.resume() }
            }, checkpoint: { probe.record($0) }, handler: { probe.add($0) })
    }
    @discardableResult
    private func registered(_ path: URL, directory: Bool, probe: AionCancelProbe, after mark: Int = 0,
                            file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        let matched = probe.wait(after: mark) {
            if case .registered(let actual, let isDirectory, _) = $0 {
                return actual == path.path && isDirectory == directory
            }
            return false
        }
        XCTAssertTrue(matched, "No registered source for \(path.path)", file: file, line: line)
        let id = probe.events.dropFirst(mark).compactMap { event -> UUID? in
            if case .registered(let actual, let isDirectory, let id) = event,
               actual == path.path && isDirectory == directory { return id }
            return nil
        }.last
        return try XCTUnwrap(id, file: file, line: line)
    }
    private func read(_ path: URL, offset: Int, partial: Int = 0, probe: AionCancelProbe, after mark: Int = 0,
                      inodeDifferentFrom: UInt64? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(probe.wait(after: mark) {
            if case .read(let actual, let cursor, let pending, let dropping, let inode) = $0 {
                return actual == path.path && cursor == UInt64(offset) && pending == partial && !dropping &&
                    (inodeDifferentFrom == nil || inode != inodeDifferentFrom)
            }
            return false
        }, "No completed read at offset \(offset), partial \(partial) for \(path.path)", file: file, line: line)
    }
    private func inode(_ path: URL, probe: AionCancelProbe) throws -> UInt64 {
        try XCTUnwrap(probe.events.compactMap { event -> UInt64? in
            if case .read(let actual, _, _, _, let inode) = event, actual == path.path { return inode }
            return nil
        }.last)
    }
    private func stop(_ watcher: AionUiCancellationLogWatcher, probe: AionCancelProbe,
                      file: StaticString = #filePath, line: UInt = #line) {
        let ids = probe.activeIDs; let mark = probe.mark
        watcher.retain(conversationIDs: [])
        XCTAssertTrue(probe.wait(after: mark) {
            if case .scanCompleted(let directories, let files, let contexts) = $0 {
                return contexts == 0 && directories.isEmpty && files.isEmpty
            }
            return false
        }, "Retain empty must finish clearing watcher state", file: file, line: line)
        for id in ids {
            XCTAssertTrue(probe.wait(after: mark) {
                if case .cancelled(_, _, let actual) = $0 { return actual == id }
                return false
            }, "Source cancellation must close its descriptor", file: file, line: line)
        }
        XCTAssertEqual(probe.activeIDs, [], file: file, line: line)
    }
    private func verifyLateLog(_ path: URL, probe: AionCancelProbe, expectedSignals: Int = 1) throws {
        let bytes = prefix() + acknowledgement() + Data([10]); let mark = probe.mark
        try bytes.write(to: path)
        _ = try registered(path, directory: false, probe: probe, after: mark)
        read(path, offset: bytes.count, probe: probe, after: mark)
        XCTAssertTrue(probe.waitForSignals(expectedSignals))
        XCTAssertEqual(probe.values.count, expectedSignals)
        XCTAssertEqual(probe.values.last?.conversation, target)
    }
    func testIncrementalPartialAcknowledgementAndDuplicateRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try logPath(root); let prefix = prefix(); try prefix.write(to: path)
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt)); _ = try registered(path, directory: false, probe: probe)
        read(path, offset: prefix.count, probe: probe); XCTAssertEqual(probe.values.count, 0)
        let ack = acknowledgement(); let half = ack.count / 2; var mark = probe.mark
        try append(Data(ack.prefix(half)), to: path)
        read(path, offset: prefix.count + half, partial: half, probe: probe, after: mark)
        XCTAssertEqual(probe.values.count, 0, "A processed partial record must not emit")
        mark = probe.mark; try append(Data(ack.dropFirst(half)) + Data([10]), to: path)
        read(path, offset: prefix.count + ack.count + 1, probe: probe, after: mark)
        XCTAssertTrue(probe.waitForSignals(1)); XCTAssertEqual(probe.values.first?.conversation, target)
        mark = probe.mark; try append(ack + Data([10]), to: path)
        read(path, offset: prefix.count + (ack.count + 1) * 2, probe: probe, after: mark)
        XCTAssertEqual(probe.values.count, 1, "A processed duplicate must not emit")
    }
    func testStartupReplayRecoversStopButOlderTailCannotStopNewHook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try logPath(root); let bytes = prefix() + acknowledgement() + Data([10])
        try bytes.write(to: path)
        let old = AionCancelProbe(); let oldWatch = makeWatcher(root, probe: old)
        defer { stop(oldWatch, probe: old) }
        oldWatch.watch(session(at: hookAt)); read(path, offset: bytes.count, probe: old)
        XCTAssertTrue(old.waitForSignals(1))
        let next = AionCancelProbe(); let newWatch = makeWatcher(root, probe: next)
        defer { stop(newWatch, probe: next) }
        newWatch.watch(session(at: observedAt)); _ = try registered(path, directory: false, probe: next)
        read(path, offset: bytes.count, probe: next)
        XCTAssertEqual(next.values.count, 0, "The entire old tail was processed behind a newer Hook fence")
    }
    func testDailyLogCreatedAfterWatchIsDiscovered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt)); _ = try registered(root, directory: true, probe: probe)
        // The whole hierarchy is created in one batch; the log is deliberately later.
        let path = try logPath(root)
        _ = try registered(path.deletingLastPathComponent(), directory: true, probe: probe)
        try verifyLateLog(path, probe: probe)
    }
    func testAtomicLogReplacementAndOversizedUntrustedLineDoNotLoseAcknowledgement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try logPath(root); let prefix = prefix(); try prefix.write(to: path)
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt)); _ = try registered(path, directory: false, probe: probe)
        read(path, offset: prefix.count, probe: probe); let oldInode = try inode(path, probe: probe)
        let replacement = prefix + Data(repeating: 65, count: 8_192) + Data([10]); var mark = probe.mark
        try replacement.write(to: path, options: .atomic)
        read(path, offset: replacement.count, probe: probe, after: mark, inodeDifferentFrom: oldInode)
        XCTAssertEqual(probe.values.count, 0)
        mark = probe.mark; let ack = acknowledgement(); try append(ack + Data([10]), to: path)
        read(path, offset: replacement.count + ack.count + 1, probe: probe, after: mark)
        XCTAssertTrue(probe.waitForSignals(1)); XCTAssertEqual(probe.values.count, 1)
    }
    func testRegistrationRescanDiscoversTreeCreatedBeforeRootActivation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AionCancelProbe(); let gate = AionCancelActivationGate(path: root.path)
        let watcher = makeWatcher(root, probe: probe, gate: gate)
        defer { gate.release(); stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt))
        XCTAssertTrue(probe.wait {
            if case .scanCompleted(_, let files, let contexts) = $0 { return contexts == 1 && files.isEmpty }
            return false
        })
        XCTAssertFalse(probe.events.contains {
            if case .registered(let path, _, _) = $0 { return path == root.path }; return false
        }, "The root source is intentionally suspended while the missing tree is created")
        let path = try logPath(root); gate.release()
        _ = try registered(root, directory: true, probe: probe)
        _ = try registered(path.deletingLastPathComponent(), directory: true, probe: probe)
        try verifyLateLog(path, probe: probe)
    }
    func testFileRegistrationReadsFirstWriteMadeBeforeSourceActivation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try logPath(root); try Data().write(to: path)
        let probe = AionCancelProbe(); let gate = AionCancelActivationGate(path: path.path, directory: false)
        let watcher = makeWatcher(root, probe: probe, gate: gate)
        defer { gate.release(); stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt))
        let day = path.deletingLastPathComponent(); let month = day.deletingLastPathComponent()
        let year = month.deletingLastPathComponent(); let paths = Set([root.path, year.path, month.path, day.path])
        for directory in [root, year, month, day] {
            _ = try registered(directory, directory: true, probe: probe)
        }
        // Drain the last actual directory-registration rescan before the first append.
        // Otherwise a pending parent registration could read the file and mask a broken file handler.
        let lastRegistration = try XCTUnwrap(probe.events.enumerated().compactMap { item -> Int? in
            if case .registered(let actual, let directory, _) = item.element,
               directory && paths.contains(actual) { return item.offset }
            return nil
        }.last)
        read(path, offset: 0, probe: probe, after: lastRegistration + 1)
        XCTAssertTrue(probe.wait(after: lastRegistration + 1) {
            if case .scanCompleted(_, let files, let contexts) = $0 {
                return contexts == 1 && files.contains(path.path)
            }
            return false
        })
        XCTAssertFalse(probe.events.contains {
            if case .registered(let actual, let directory, _) = $0 {
                return !directory && actual == path.path
            }
            return false
        }, "The file source must still be suspended after the initial empty read")
        let bytes = prefix() + acknowledgement() + Data([10]); let mark = probe.mark
        try append(bytes, to: path)
        XCTAssertEqual(probe.values.count, 0)
        gate.release()
        _ = try registered(path, directory: false, probe: probe, after: mark)
        read(path, offset: bytes.count, probe: probe, after: mark)
        XCTAssertTrue(probe.waitForSignals(1)); XCTAssertEqual(probe.values.count, 1)
        XCTAssertEqual(probe.values.first?.conversation, target)
    }
    func testSubscribedRootQuicklyDeletedAndRecreatedGetsNewSourcesBeforeLateLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try logPath(root); let day = path.deletingLastPathComponent()
        let month = day.deletingLastPathComponent(); let year = month.deletingLastPathComponent()
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt)); let oldRootID = try registered(root, directory: true, probe: probe)
        for directory in [year, month, day] {
            _ = try registered(directory, directory: true, probe: probe)
        }
        let mark = probe.mark
        // Rebuild immediately: do not wait for any old-generation vnode/cancel event first.
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let newRootID = try registered(root, directory: true, probe: probe, after: mark)
        XCTAssertNotEqual(newRootID, oldRootID)
        _ = try registered(day, directory: true, probe: probe, after: mark)
        XCTAssertTrue(probe.wait(after: mark) {
            if case .cancelled(_, _, let id) = $0 { return id == oldRootID }
            return false
        }, "The old root descriptor must close without removing its replacement source")
        try verifyLateLog(path, probe: probe)
    }
    func testMissingRootRegistersExistingAncestorAndFindsLateLog() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("AionUi")
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt))
        _ = try registered(sandbox, directory: true, probe: probe)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try registered(root, directory: true, probe: probe)
        let path = try logPath(root)
        _ = try registered(path.deletingLastPathComponent(), directory: true, probe: probe)
        try verifyLateLog(path, probe: probe)
    }
    func testDateDirectoriesCreatedOneLevelAtATimeAreRegisteredBeforeLateLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt)); _ = try registered(root, directory: true, probe: probe)
        let path = dailyPath(root); let day = path.deletingLastPathComponent()
        let month = day.deletingLastPathComponent(); let year = month.deletingLastPathComponent()
        for directory in [year, month, day] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            _ = try registered(directory, directory: true, probe: probe)
        }
        try verifyLateLog(path, probe: probe)
    }
    func testRenamedDateDirectoryIsReattachedBeforeLaterAppend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try logPath(root); let day = path.deletingLastPathComponent()
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt)); let oldID = try registered(day, directory: true, probe: probe)
        let mark = probe.mark; let moved = day.appendingPathExtension("old")
        try FileManager.default.moveItem(at: day, to: moved)
        XCTAssertTrue(probe.wait(after: mark) {
            if case .cancelled(_, _, let id) = $0 { return id == oldID }; return false
        })
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: false)
        let newID = try registered(day, directory: true, probe: probe, after: mark)
        XCTAssertNotEqual(newID, oldID); try verifyLateLog(path, probe: probe)
    }
    func testDeletedDateDirectoryIsRecreatedBeforeLateLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try logPath(root); let day = path.deletingLastPathComponent()
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt)); let oldID = try registered(day, directory: true, probe: probe)
        let mark = probe.mark; try FileManager.default.removeItem(at: day)
        XCTAssertTrue(probe.wait(after: mark) {
            if case .cancelled(_, _, let id) = $0 { return id == oldID }; return false
        })
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: false)
        let newID = try registered(day, directory: true, probe: probe, after: mark)
        XCTAssertNotEqual(newID, oldID); try verifyLateLog(path, probe: probe)
    }
    func testEmptyTruncationClearsCursorBeforeLargerReplacementTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try logPath(root); let oldAck = acknowledgement(); let half = oldAck.count / 2
        let oldBytes = prefix() + oldAck.prefix(half); try oldBytes.write(to: path)
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt)); _ = try registered(path, directory: false, probe: probe)
        read(path, offset: oldBytes.count, partial: half, probe: probe)
        let oldInode = try inode(path, probe: probe); var mark = probe.mark
        watcher.watch(session(at: base.addingTimeInterval(16)))
        read(path, offset: oldBytes.count, partial: half, probe: probe, after: mark)
        mark = probe.mark
        let handle = try FileHandle(forWritingTo: path); try handle.truncate(atOffset: 0); try handle.close()
        read(path, offset: 0, probe: probe, after: mark)
        XCTAssertEqual(try inode(path, probe: probe), oldInode)
        XCTAssertEqual(probe.values.count, 0)
        // This record sequence is longer than the old cursor: stale offset would skip its claim.
        let nextTurn = "turn_after_empty_truncation_" + String(repeating: "x", count: 80)
        let replacement = prefix(turn: nextTurn, claimedAt: base.addingTimeInterval(15), requestedAt: base.addingTimeInterval(17)) +
            acknowledgement(turn: nextTurn, at: base.addingTimeInterval(19)) + Data([10])
        XCTAssertGreaterThan(replacement.count, oldBytes.count)
        mark = probe.mark; try append(replacement, to: path)
        read(path, offset: replacement.count, probe: probe, after: mark)
        XCTAssertTrue(probe.waitForSignals(1)); XCTAssertEqual(probe.values.last?.turnID, nextTurn)
    }
    func testPartialAcknowledgementCannotCrossAnAtomicReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try logPath(root); let oldAck = acknowledgement(); let oldHalf = oldAck.count / 2
        let oldBytes = prefix() + oldAck.prefix(oldHalf); try oldBytes.write(to: path)
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt)); _ = try registered(path, directory: false, probe: probe)
        read(path, offset: oldBytes.count, partial: oldHalf, probe: probe)
        let oldInode = try inode(path, probe: probe); let nextTurn = "turn_atomic_replacement"
        var mark = probe.mark; watcher.watch(session(at: base.addingTimeInterval(16)))
        read(path, offset: oldBytes.count, partial: oldHalf, probe: probe, after: mark)
        let nextPrefix = prefix(turn: nextTurn, claimedAt: base.addingTimeInterval(15), requestedAt: base.addingTimeInterval(17))
        let nextAck = acknowledgement(turn: nextTurn, at: base.addingTimeInterval(19)); let half = nextAck.count / 2
        let replacement = nextPrefix + nextAck.prefix(half); mark = probe.mark
        try replacement.write(to: path, options: .atomic)
        read(path, offset: replacement.count, partial: half, probe: probe, after: mark, inodeDifferentFrom: oldInode)
        XCTAssertEqual(probe.values.count, 0)
        mark = probe.mark; try append(Data(nextAck.dropFirst(half)) + Data([10]), to: path)
        read(path, offset: nextPrefix.count + nextAck.count + 1, probe: probe, after: mark)
        XCTAssertTrue(probe.waitForSignals(1)); XCTAssertEqual(probe.values.count, 1)
        XCTAssertEqual(probe.values.first?.turnID, nextTurn)
    }
    func testRetainEmptyClosesSourcesAndSameWatcherCanWatchAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try logPath(root); let bytes = prefix(); try bytes.write(to: path)
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: hookAt)); let oldID = try registered(path, directory: false, probe: probe)
        read(path, offset: bytes.count, probe: probe); XCTAssertFalse(probe.activeIDs.isEmpty)
        stop(watcher, probe: probe)
        try append(acknowledgement() + Data([10]), to: path)
        XCTAssertEqual(probe.values.count, 0, "All old sources and descriptors are already cancelled")
        let mark = probe.mark; watcher.watch(session(at: hookAt))
        let newID = try registered(path, directory: false, probe: probe, after: mark)
        XCTAssertNotEqual(newID, oldID)
        read(path, offset: bytes.count + acknowledgement().count + 1, probe: probe, after: mark)
        XCTAssertTrue(probe.waitForSignals(1)); XCTAssertEqual(probe.values.count, 1)
    }
    private func checkDateRollover(initial: String, next: String) throws {
        let format = ISO8601DateFormatter(); let initialDate = try XCTUnwrap(format.date(from: initial))
        let nextDate = try XCTUnwrap(format.date(from: next)); let clock = AionCancelClock(initialDate)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = try logPath(root, at: initialDate)
        let probe = AionCancelProbe(); let watcher = makeWatcher(root, probe: probe, clock: clock)
        defer { stop(watcher, probe: probe) }
        watcher.watch(session(at: initialDate)); let day = oldPath.deletingLastPathComponent()
        let oldID = try registered(day, directory: true, probe: probe)
        let nextPath = dailyPath(root, at: nextDate); let mark = probe.mark; clock.set(nextDate)
        // No Hook change or explicit rescan: a real parent-directory event must update candidates.
        try FileManager.default.createDirectory(at: nextPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try registered(nextPath.deletingLastPathComponent(), directory: true, probe: probe, after: mark)
        XCTAssertTrue(probe.wait(after: mark) {
            if case .cancelled(_, _, let id) = $0 { return id == oldID }; return false
        }, "An old day outside the new +/-1 day window must be released")
        XCTAssertTrue(probe.wait(after: mark) {
            if case .scanCompleted(let directories, _, let contexts) = $0 {
                return contexts == 1 && directories.contains(nextPath.deletingLastPathComponent().path) &&
                    !directories.contains(day.path)
            }
            return false
        })
        // Topology-only: fixture parser's 24h acceptance window is deliberately not involved.
        XCTAssertEqual(probe.values.count, 0)
    }
    func testMonthRolloverChangesCandidatesWithoutNewHook() throws {
        try checkDateRollover(initial: "2026-10-31T12:00:00+08:00", next: "2026-11-02T12:00:00+08:00")
    }
    func testYearRolloverChangesCandidatesWithoutNewHook() throws {
        try checkDateRollover(initial: "2026-12-31T12:00:00+08:00", next: "2027-01-02T12:00:00+08:00")
    }
}
