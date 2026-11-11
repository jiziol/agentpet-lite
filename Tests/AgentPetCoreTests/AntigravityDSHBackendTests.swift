import XCTest
@testable import AgentPetCore

final class AntigravityDSHBackendTests: XCTestCase {
    private let id = "00000000-0000-4000-8000-000000000006"
    private let time = Date(timeIntervalSince1970: 10000)
    private func event(_ offset: Double = 0, hosted: Bool? = nil, new: Bool = true, done: Bool = false) -> AgentEvent {
        var e = AgentEvent(sessionId: id, agentKind: .antigravity, eventName: done ? "done" : "working", timestamp: time.addingTimeInterval(offset))
        e.antigravityFromDSH = hosted; e.antigravityNewInvocation = new
        if done { e.turnResult = .completed }
        return e
    }
    func testHostExecutableRequiresActualAppBundleIdentity() {
        XCTAssertTrue(AntigravityHostOrigin.isDSHExecutable("/Applications/DeepSeek Harness.app/Contents/MacOS/dsh-desktop", bundleIdentifier: { _ in "com.deepseek.dsh" }))
        for path in ["/usr/local/bin/dsh", "/tmp/com.deepseek.dsh", "/Applications/Fake.app/Contents/Resources/node", "relative.app/Contents/MacOS/dsh"] {
            XCTAssertFalse(AntigravityHostOrigin.isDSHExecutable(path, bundleIdentifier: { _ in "com.deepseek.dsh" }))
        }
        XCTAssertFalse(AntigravityHostOrigin.isDSHExecutable("/Applications/AionUi.app/Contents/MacOS/AionUi", bundleIdentifier: { _ in "com.aionui.app" }))
    }
    func testMainAndAuxiliaryDSHInvocationsAreTrackedButNotDisplayedOrRewardedTwice() throws {
        for title in ["Normal main conversation", "Auxiliary title request"] {
            let store = SessionStore()
            var e = event(hosted: true); e.title = title
            let running = try XCTUnwrap(store.apply(e, now: e.timestamp))
            XCTAssertTrue(running.isDSHBackend); XCTAssertTrue(store.sorted.isEmpty)
            XCTAssertTrue(SessionNotificationPolicy.effects(before: .idle, session: running).isEmpty)
            let end = event(5, hosted: true, new: false, done: true)
            let finished = try XCTUnwrap(store.apply(end, now: end.timestamp))
            XCTAssertEqual(finished.state, .done); XCTAssertEqual(finished.taskResult, .completed)
            XCTAssertTrue(SessionNotificationPolicy.effects(before: .working, session: finished).isEmpty)
            XCTAssertTrue(try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(finished)).isDSHBackend)
        }
    }
    func testIndependentInvocationOfSameUUIDReappearsAndLateOrUnknownHooksCannotResetOwnership() throws {
        let store = SessionStore()
        let start = event(hosted: true); store.apply(start, now: start.timestamp)
        let tool = event(1, hosted: false, new: false); store.apply(tool, now: tool.timestamp)
        XCTAssertTrue(try XCTUnwrap(store.session(id: id)).isDSHBackend)
        let resumed = event(2, hosted: false); store.apply(resumed, now: resumed.timestamp)
        XCTAssertFalse(try XCTUnwrap(store.session(id: id)).isDSHBackend); XCTAssertEqual(store.sorted.count, 1)
        store.apply(start, now: time.addingTimeInterval(3))
        XCTAssertFalse(try XCTUnwrap(store.session(id: id)).isDSHBackend)
        let unknown = event(4, hosted: nil, new: false); store.apply(unknown, now: unknown.timestamp)
        XCTAssertFalse(try XCTUnwrap(store.session(id: id)).isDSHBackend)
    }
    func testHistoricalClassificationPreservesLifecycleAndReceiptsAndRejectsStaleOrIndependentRecords() throws {
        let store = SessionStore()
        let e = event(); let before = try XCTUnwrap(store.apply(e, now: e.timestamp))
        XCTAssertTrue(store.markAntigravityDSHBackend(expected: before))
        var after = try XCTUnwrap(store.session(id: id)); XCTAssertTrue(after.isDSHBackend)
        after.antigravityFromDSH = nil; XCTAssertEqual(after, before)
        XCTAssertFalse(store.markAntigravityDSHBackend(expected: before))
        let normal = event(2, hosted: false); let independent = try XCTUnwrap(store.apply(normal, now: normal.timestamp))
        XCTAssertFalse(store.markAntigravityDSHBackend(expected: independent))
        XCTAssertFalse(store.markAntigravityDSHBackend(expected: before))
    }
    func testLegacyIndependentTerminalAndAionUiRecordsRemainVisible() throws {
        for variant in ["legacy", "terminal", "aionui"] {
            let store = SessionStore(); var e = event()
            if variant == "terminal" { e.terminalProgram = "iTerm.app" }
            var record = try XCTUnwrap(store.apply(e, now: e.timestamp))
            if variant == "aionui" { record.aionUiConversation = .init(id: "fixture", nativeSessionID: id, agentKind: .antigravity) }
            XCTAssertFalse(record.isDSHBackend); XCTAssertEqual(store.sorted.count, 1)
            if variant == "terminal" { XCTAssertFalse(store.markAntigravityDSHBackend(expected: record)) }
        }
    }
}
