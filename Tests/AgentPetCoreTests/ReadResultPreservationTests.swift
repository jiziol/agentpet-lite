import XCTest
@testable import AgentPetCore

final class ReadResultPreservationTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_000)

    private func readResult(in store: SessionStore) -> AgentSession {
        let event = AgentEvent(sessionId: "s", agentKind: .codex, eventName: "Stop", timestamp: at)
        let s = store.apply(event, now: at)!
        XCTAssertTrue(store.markOpened(s, at: at))
        return s
    }

    func testForeverKeepsReadDoneAndTurningItOffRestoresCleanup() {
        let store = SessionStore()
        _ = readResult(in: store)
        store.preserveReadResults = true
        store.prune(now: at.addingTimeInterval(100_000))
        XCTAssertEqual(store.session(id: "s")?.state, .done)
        XCTAssertFalse(store.session(id: "s")!.hasUnread)
        store.preserveReadResults = false
        store.prune(now: at.addingTimeInterval(100_001))
        XCTAssertEqual(store.session(id: "s")?.state, .idle)
        store.prune(now: at.addingTimeInterval(100_602))
        XCTAssertNil(store.session(id: "s"))
    }

    func testForeverAlsoKeepsPreviouslyDemotedResult() {
        let store = SessionStore()
        _ = readResult(in: store)
        store.prune(now: at.addingTimeInterval(40))
        XCTAssertEqual(store.session(id: "s")?.state, .idle)
        store.preserveReadResults = true
        store.prune(now: at.addingTimeInterval(100_000))
        XCTAssertEqual(store.session(id: "s")?.state, .idle)
    }

    func testLateArchiveRetryCannotRemoveResultAfterKeepVisibleIsSelected() {
        let store = SessionStore()
        _ = readResult(in: store)
        let read = store.session(id: "s")!
        let reducer = SessionReducer()
        reducer.byID[read.id] = read
        let receipt = ArchiveEffectReceipt(request: SessionArchiveRequest(session: read,
            endedAt: at, saveAfterRemoval: false), result: .archived)
        reducer.preserveReadResults = true
        reducer.finishArchive(receipt)
        XCTAssertEqual(reducer.byID[read.id], read)
        reducer.preserveReadResults = false
        reducer.finishArchive(receipt)
        XCTAssertNil(reducer.byID[read.id])
    }

    func testNewWorkStillReplacesRetainedReadResult() {
        let store = SessionStore()
        _ = readResult(in: store)
        store.preserveReadResults = true
        let later = at.addingTimeInterval(100)
        let next = AgentEvent(sessionId: "s", agentKind: .codex, eventName: "UserPromptSubmit", timestamp: later)
        XCTAssertEqual(store.apply(next, now: later)?.state, .working)
        XCTAssertFalse(store.session(id: "s")!.hasReadReceipt)
    }
}
