import XCTest
@testable import AgentPetCore

final class RunningIndicatorReadReceiptTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 100)
    // DSH uses authenticated envelope/identity fixtures in DSHIntegrationTests.
    private let kinds = AgentCatalog.maintainedKinds.filter { $0 != .dsh } + [.cli, .unknown]

    private func event(_ kind: AgentKind, _ state: AgentState, _ seconds: Double = 0) -> AgentEvent {
        AgentEvent(sessionId: "test", agentKind: kind, eventName: state.rawValue,
            timestamp: at.addingTimeInterval(seconds))
    }

    func testRunningNavigationRecordsReceiptWithoutChangingWorkOrClock() {
        for kind in kinds {
            let store = SessionStore()
            let start = event(kind, .working)
            let clicked = store.apply(start, now: start.timestamp)!
            XCTAssertTrue(store.markOpened(clicked, at: at.addingTimeInterval(1)), "\(kind)")
            let current = store.session(id: "test")!
            XCTAssertTrue(current.hasReadReceipt, "\(kind): successful navigation still records reading")
            XCTAssertEqual(current.readDisplayRevision, clicked.displayRevision ?? 0)
            XCTAssertEqual(current.readThroughVersion, clicked.notificationVersion)
            XCTAssertEqual(current.state, .working)
            XCTAssertEqual(current.indicator, .running, "\(kind): a read running task stays blue")
            XCTAssertEqual(current.updatedAt, clicked.updatedAt)
            XCTAssertEqual(current.turnStartedAt, clicked.turnStartedAt)
            XCTAssertNil(current.turnEndedAt)
        }
    }

    func testRegisteredNavigationRecordsReceiptAndRemainsBlue() {
        for kind in kinds {
            let store = SessionStore()
            let start = event(kind, .registered)
            let clicked = store.apply(start, now: start.timestamp)!
            XCTAssertTrue(store.markOpened(clicked, at: at.addingTimeInterval(1)))
            XCTAssertTrue(store.session(id: "test")!.hasReadReceipt)
            XCTAssertEqual(store.session(id: "test")!.state, .registered)
            XCTAssertEqual(store.session(id: "test")!.indicator, .running, "\(kind)")
        }
    }

    func testReadWaitingAndCompletedMessagesKeepGreen() {
        for kind in kinds {
            let store = SessionStore()
            let wait = event(kind, .waiting)
            let waiting = store.apply(wait, now: wait.timestamp)!
            XCTAssertEqual(waiting.indicator, .attention)
            XCTAssertTrue(store.markOpened(waiting, at: at.addingTimeInterval(1)))
            XCTAssertEqual(store.session(id: "test")!.state, .waiting)
            XCTAssertEqual(store.session(id: "test")!.indicator, .read)
            let finish = event(kind, .done, 2)
            let done = store.apply(finish, now: finish.timestamp)!
            XCTAssertEqual(done.indicator, .unread)
            XCTAssertTrue(store.markOpened(done, at: at.addingTimeInterval(3)))
            XCTAssertEqual(store.session(id: "test")!.state, .done)
            XCTAssertEqual(store.session(id: "test")!.indicator, .read)
        }
    }

    func testRunningReceiptPersistsAcrossNativeSourceRestartAndIdleCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for kind: AgentKind in [.codex, .antigravity, .opencode] {
            let store = SessionStore()
            store.persistenceURL = root.appendingPathComponent(kind.rawValue + ".json")
            let start = event(kind, .working)
            let clicked = store.apply(start, now: start.timestamp)!
            XCTAssertTrue(store.markOpened(clicked, at: at.addingTimeInterval(1)))
            let restored = SessionStore()
            restored.persistenceURL = store.persistenceURL
            restored.restoreCodexSessions()
            restored.prune(now: at.addingTimeInterval(20))
            let current = try XCTUnwrap(restored.session(id: "test"))
            XCTAssertTrue(current.hasReadReceipt)
            XCTAssertEqual(current.readAt, at.addingTimeInterval(1))
            XCTAssertEqual(current.state, .working)
            XCTAssertEqual(current.indicator, .running)
            XCTAssertEqual(current.updatedAt, clicked.updatedAt)
            XCTAssertEqual(current.turnStartedAt, clicked.turnStartedAt)
            XCTAssertNil(current.turnEndedAt)
        }
    }
}
