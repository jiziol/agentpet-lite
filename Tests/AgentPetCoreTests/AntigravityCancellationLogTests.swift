import Foundation
import XCTest
@testable import AgentPetCore

private final class LogProbe: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var signals: [AntigravityCancellationSignal] = []
    func add(_ signal: AntigravityCancellationSignal) { lock.lock(); signals.append(signal); lock.unlock(); ready.signal() }
    var values: [AntigravityCancellationSignal] { lock.lock(); defer { lock.unlock() }; return signals }
}
final class AntigravityCancellationLogTests: XCTestCase {
    private let id = "00000000-0000-4000-8000-000000000003"
    private let other = "00000000-0000-4000-8000-000000000004"
    private let utc = TimeZone(secondsFromGMT: 0)!
    private var at: Date { ISO8601DateFormatter().date(from: "2026-10-04T02:00:55Z")! }
    private func line(_ id: String, at: Date) -> String {
        let format = DateFormatter(); format.dateFormat = "'I'MMdd HH:mm:ss.SSSSSS"
        format.locale = Locale(identifier: "en_US_POSIX")
        return "\(format.string(from: at))   12345 server.go:2336] Cancelling conversation \(id) (killBackgroundTasks=false)"
    }
    private func event(_ time: Date, waiting: Bool = false) -> AgentEvent {
        var e = AgentEvent(sessionId: id, agentKind: .antigravity, eventName: waiting ? "waiting" : "working", timestamp: time)
        e.antigravityNewInvocation = !waiting; e.antigravityStepFloor = 10
        return e
    }
    func testExactNativeRecordParsesAndPreservesCancellationTime() {
        let text = "I1004 02:00:55.405269   45343 server.go:2336] Cancelling conversation \(id) (killBackgroundTasks=false)"
        let result = AntigravityCancellationLog.parse(text, observedAt: at.addingTimeInterval(1), timeZone: utc)
        XCTAssertEqual(result?.sessionID, id)
        XCTAssertEqual(result!.timestamp.timeIntervalSince(at), 0.405269, accuracy: 0.000001)
    }
    func testAssistantTextGenericErrorsAndInvalidRecordsAreIgnored() {
        let suffix = "Cancelling conversation \(id) (killBackgroundTasks=false)"
        for text in [suffix, "Assistant: \(suffix)", "I1004 02:00:55.405269 123 conversation_manager.go:1517] \(suffix)",
                     "I1004 02:00:55.405269 123 server.go:2336] request cancelled", "I1004 02:00:55.405269 123 server.go:2336] Cancelling conversation ../../other (killBackgroundTasks=false)",
                     "I1004 02:00:55.405269 123 server.go:2336] \(suffix) EXTRA", String(repeating: "a", count: 513)] {
            XCTAssertNil(AntigravityCancellationLog.parse(text, observedAt: at.addingTimeInterval(1), timeZone: utc), text)
        }
    }
    func testOldFutureAndImpossibleDatesAreRejected() {
        for prefix in ["I1002 02:00:55.405269", "I1004 02:01:55.405269", "I0230 02:00:55.405269", "I1004 24:00:55.405269", "I1004 02:60:55.405269", "I1004 02:00:60.405269"] {
            XCTAssertNil(AntigravityCancellationLog.parse("\(prefix) 1 server.go:2] Cancelling conversation \(id) (killBackgroundTasks=false)", observedAt: at, timeZone: utc))
        }
    }
    func testYearBoundaryUsesThePreviousYear() {
        let now = ISO8601DateFormatter().date(from: "2027-01-01T00:00:01Z")!
        let parsed = AntigravityCancellationLog.parse("I1231 23:59:59.000000 1 server.go:2] Cancelling conversation \(id) (killBackgroundTasks=true)", observedAt: now, timeZone: utc)
        XCTAssertEqual(parsed?.timestamp, now.addingTimeInterval(-2))
    }
    func testCurrentCancellationStopsGreenWithoutNavigationReceipt() {
        let store = SessionStore(); let hook = at.addingTimeInterval(-2)
        store.apply(event(hook), now: hook)
        let signal = AntigravityCancellationSignal(sessionID: id, timestamp: at, expectedHookAt: hook)
        let s = store.reconcileAntigravityCancellationSignal(signal, observedAt: at.addingTimeInterval(0.01))!
        XCTAssertTrue(s.isStopped); XCTAssertEqual(s.indicator, .read)
        XCTAssertFalse(s.hasUnread); XCTAssertNil(s.readAt)
        XCTAssertEqual(s.antigravityStepFloor, 10)
        XCTAssertNil(store.reconcileAntigravityCancellationSignal(signal, observedAt: at.addingTimeInterval(1)))
    }
    func testStaleHookOlderLogAndOtherSessionCannotStopCurrentTurn() {
        let store = SessionStore(); let hook = at.addingTimeInterval(-2)
        store.apply(event(hook), now: hook)
        for signal in [AntigravityCancellationSignal(sessionID: id, timestamp: at, expectedHookAt: hook.addingTimeInterval(-1)),
                       AntigravityCancellationSignal(sessionID: id, timestamp: hook.addingTimeInterval(-1), expectedHookAt: hook),
                       AntigravityCancellationSignal(sessionID: other, timestamp: at, expectedHookAt: hook)] {
            XCTAssertNil(store.reconcileAntigravityCancellationSignal(signal, observedAt: at))
        }
        XCTAssertEqual(store.session(id: id)?.indicator, .running)
        let pending = AntigravityCancellationSignal(sessionID: id, timestamp: at, expectedHookAt: hook)
        let next = at.addingTimeInterval(1);store.apply(event(next), now: next)
        XCTAssertNil(store.reconcileAntigravityCancellationSignal(pending, observedAt: next))
        XCTAssertEqual(store.session(id: id)?.indicator, .running)
    }
    func testNativeCancellationClearsChoiceAndNewInvocationResumesBlue() {
        let store = SessionStore();let hook = at.addingTimeInterval(-2);store.apply(event(hook), now: hook)
        var request = AgentEvent(sessionId: id, agentKind: .antigravity, eventName: "HumanInput", timestamp: hook.addingTimeInterval(0.1))
        request.humanIntervention = HumanIntervention(action: .asked, requests: [HumanRequest(id: "agy:10:execution:0:choice", kind: .choice, createdAt: hook)])
        store.apply(request, now: request.timestamp)
        let current = store.session(id: id)!.antigravityEventAt!
        let signal = AntigravityCancellationSignal(sessionID: id, timestamp: at, expectedHookAt: current)
        let stopped = store.reconcileAntigravityCancellationSignal(signal, observedAt: at)!
        XCTAssertEqual(stopped.humanRequests?.count, 0);XCTAssertEqual(stopped.indicator,.read)
        let next = at.addingTimeInterval(1);store.apply(event(next),now:next)
        XCTAssertEqual(store.session(id: id)?.indicator,.running)
    }
    func testIncrementalPartialLinesExactSessionAndDeduplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("cli-20261004_100000.log")
        let now = Date(); let text = line(id,at:now);let data = Data(text.utf8);let split = data.count / 2
        try Data((line(other,at:now)+"\n").utf8).write(to:path)
        let handle = try FileHandle(forWritingTo: path);defer { try? handle.close() }
        try handle.seekToEnd();try handle.write(contentsOf: data.prefix(split))
        let p = LogProbe();let w = AntigravityCancellationLogWatcher(directory:root.path) { p.add($0) }
        let hook = now.addingTimeInterval(-1);w.watch(sessionID:id,latestHookAt:hook)
        XCTAssertEqual(p.ready.wait(timeout:.now()+0.08),.timedOut)
        try handle.write(contentsOf:data.dropFirst(split));try handle.write(contentsOf:Data([10]))
        XCTAssertEqual(p.ready.wait(timeout:.now()+2),.success)
        XCTAssertEqual(p.values.first?.sessionID,id);XCTAssertEqual(p.values.first?.expectedHookAt,hook)
        try handle.write(contentsOf:Data((text+"\n").utf8))
        XCTAssertEqual(p.ready.wait(timeout:.now()+0.1),.timedOut);XCTAssertEqual(p.values.count,1)
        w.retain(sessionIDs:[])
    }
    func testHookBoundaryRejectsOldLogTailAndFutureWriteStillWorks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let path = root.appendingPathComponent("cli-20261004_100000.log");let now = Date()
        try Data((line(id,at:now.addingTimeInterval(-4))+"\n").utf8).write(to:path)
        let p = LogProbe();let w = AntigravityCancellationLogWatcher(directory:root.path) { p.add($0) }
        w.watch(sessionID:id,latestHookAt:now.addingTimeInterval(-1))
        XCTAssertEqual(p.ready.wait(timeout:.now()+0.08),.timedOut)
        let h = try FileHandle(forWritingTo:path);try h.seekToEnd();try h.write(contentsOf:Data((line(id,at:now)+"\n").utf8));try h.close()
        XCTAssertEqual(p.ready.wait(timeout:.now()+2),.success)
        w.retain(sessionIDs:[])
    }
}
