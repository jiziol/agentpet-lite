import XCTest
import AgentPetCore
@testable import agentpet

@MainActor
final class AOHostObserverTests: XCTestCase {
    private final class StubLoader: AOHostLoading, @unchecked Sendable {
        var results: [AOSnapshot?] = []
        func load(_ run: AORunFile, now: Date) async -> AOSnapshot? {
            results.isEmpty ? nil : results.removeFirst()
        }
    }

    private let at = Date(timeIntervalSince1970: 100)
    private let run = AORunFile(port: 3001, pid: 42,
                                appRunID: "apprun-66666666-6666-6666-6666-666666666666")

    private func snapshot(available: Bool = true) -> AOSnapshot {
        let observation = AOHostObservation(
            sessionID: "proj-1", projectID: "proj", projectName: "AgentPet", role: .worker,
            harness: "opencode-v2", displayName: "Worker", status: "needs_input",
            activity: .waitingInput, activityAt: at, isTerminated: false,
            createdAt: at, updatedAt: at, lastEventAt: at,
            observedAt: at, instanceID: run.appRunID, available: available)
        return AOSnapshot(instanceID: run.appRunID, observedAt: at,
                          projectNames: ["proj": "AgentPet"], sessions: [observation])
    }

    func testObserverAppliesSnapshotAndMarksUnavailableWithoutASecondPoll() async throws {
        let store = SessionStore()
        let loader = StubLoader()
        loader.results = [snapshot()]
        var notified = 0
        var refreshes = 0
        let run = self.run
        let observer = AOHostObserver(
            loader: loader,
            readRunFile: { run },
            applySnapshot: { snapshot, now in store.applyAOSnapshot(snapshot, now: now) },
            markUnavailable: { now in store.markAOUnavailable(now: now) },
            notify: { before, _ in if before != nil { notified += 1 } },
            refreshUI: { refreshes += 1 },
            pollInterval: 60)
        await observer.refreshNow()
        let placeholder = try XCTUnwrap(store.session(id: "ao:proj-1"))
        XCTAssertEqual(placeholder.state, .waiting)
        XCTAssertEqual(placeholder.notificationVersion, 1)
        XCTAssertEqual(notified, 0, "initial history must not notify")
        XCTAssertEqual(refreshes, 1)

        loader.results = [nil]
        await observer.refreshNow()
        let unavailable = try XCTUnwrap(store.session(id: "ao:proj-1"))
        XCTAssertEqual(unavailable.state, .idle)
        XCTAssertEqual(unavailable.message, "AO 不可达，状态未知")
        XCTAssertEqual(refreshes, 2)
        observer.stop()
    }

    func testConflictWaitNotifiesOnceFromKnownHostBaseline() async throws {
        let store = SessionStore()
        func claim(_ id: String) {
            var event = AgentEvent(sessionId: id, agentKind: .opencode,
                                   eventName: "working", timestamp: at)
            event.aoSessionID = "proj-1"
            event.aoProjectID = "proj"
            _ = store.apply(event, now: at)
        }
        claim("ses_a")
        var active = snapshot()
        active.sessions[0].status = "working"
        active.sessions[0].activity = .active
        var waiting = snapshot()
        waiting.sessions[0].updatedAt = at.addingTimeInterval(1)
        let loader = StubLoader()
        loader.results = [active, waiting, waiting]
        var effects: [SessionCompletionEffect] = []
        // This test injects snapshots and uses an unserved port for the SSE
        // transport; it never reads the actual daemon or its session data.
        let run = AORunFile(port: 1, pid: 42, appRunID: self.run.appRunID)
        let observer = AOHostObserver(
            loader: loader, readRunFile: { run },
            applySnapshot: { snapshot, now in store.applyAOSnapshot(snapshot, now: now) },
            markUnavailable: { now in store.markAOUnavailable(now: now) },
            notify: { before, after in
                effects += SessionNotificationPolicy.effects(before: before?.state, session: after)
            })
        defer { observer.stop() }
        await observer.refreshNow()
        claim("ses_b")
        await observer.refreshNow()
        let host = try XCTUnwrap(store.session(id: "ao:proj-1"))
        XCTAssertTrue(host.hasUnread)
        XCTAssertEqual(host.state, .waiting)
        XCTAssertEqual(effects.filter { $0 == .waitingSound }.count, 1)
        XCTAssertEqual(effects.count, 2)
        await observer.refreshNow()
        XCTAssertEqual(effects.count, 2, "repeat snapshot cannot notify another wait")
        XCTAssertEqual(store.session(id: host.id)?.notificationVersion, host.notificationVersion)
        XCTAssertNil(store.session(id: "ses_a")?.aoObservation)
        XCTAssertNil(store.session(id: "ses_b")?.aoObservation)
    }

    func testObserverDoesNothingWithoutARunFile() async {
        let store = SessionStore()
        var refreshes = 0
        let observer = AOHostObserver(
            loader: StubLoader(),
            readRunFile: { nil },
            applySnapshot: { snapshot, now in store.applyAOSnapshot(snapshot, now: now) },
            markUnavailable: { now in store.markAOUnavailable(now: now) },
            refreshUI: { refreshes += 1 },
            pollInterval: 60)
        await observer.refreshNow()
        XCTAssertNil(store.session(id: "ao:proj-1"))
        XCTAssertEqual(refreshes, 1)
        observer.stop()
    }
}
