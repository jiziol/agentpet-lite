import XCTest
@testable import AgentPetCore

final class SessionRepositoryTests: XCTestCase {
    private let byteLimit = 4_194_304
    private final class CountingWriter: @unchecked Sendable {
        let lock = NSLock()
        var sizes: [Int] = []
        func write(_ url: URL, _ data: Data) throws {
            lock.withLock { sizes.append(data.count) }
            try data.write(to: url, options: .atomic)
        }
    }
    private final class WriterProbe: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var titles: [String] = []
        func write(_ url: URL, _ data: Data) throws {
            let title = try JSONDecoder().decode(SessionSnapshotDTO.self, from: data).sessions.first?.title ?? ""
            let first = lock.withLock { titles.append(title); return titles.count == 1 }
            if first {
                started.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "synthetic-timeout", code: 1) }
            }
            try data.write(to: url, options: .atomic)
        }
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func snapshot(_ title: String) -> SessionSnapshotDTO {
        SessionSnapshotDTO(sessions: [AgentSession(id: "synthetic", agentKind: .codex, title: title,
            state: .working, source: .hook, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))])
    }

    private func unreadSnapshot() -> SessionSnapshotDTO {
        var value = snapshot("原生未读")
        value.sessions[0].notificationVersion = 2
        value.sessions[0].readThroughVersion = 1
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let fact = AOHostObservation(sessionID: "proj-wait", projectID: "proj", role: .worker,
            harness: "codex", status: "needs_input", activity: .waitingInput, activityAt: at,
            isTerminated: false, createdAt: at, updatedAt: at, observedAt: at,
            instanceID: "apprun-11111111-1111-1111-1111-111111111111", available: false)
        value.aoAttentionRecords = [AOAttentionReceipt(observation: fact, version: 3,
            readThroughVersion: 2, readAt: at, waitingAt: at, instanceID: fact.instanceID,
            lastWasWaiting: true, latestUpdatedAt: at)]
        return value
    }

    private func padded(_ snapshot: SessionSnapshotDTO, toByteCount count: Int) throws -> SessionSnapshotDTO {
        var value = snapshot
        // Multi-byte text makes this a byte-boundary check rather than a character limit.
        value.sessions[0].title = "未读"
        let size = try JSONEncoder().encode(value).count
        value.sessions[0].title! += String(repeating: "x", count: count - size)
        XCTAssertEqual(try JSONEncoder().encode(value).count, count)
        return value
    }

    func testWritesObeyTheExactStrictReadByteBoundary() throws {
        for count in [byteLimit - 1, byteLimit, byteLimit + 1] {
            let file = try root().appendingPathComponent("snapshot.json")
            let writer = CountingWriter()
            let repository = SessionRepository(coalesces: true, writer: { try writer.write($0, $1) })
            repository.url = file
            let original = unreadSnapshot()
            repository.save(original)
            XCTAssertTrue(repository.flush().isFlushed)
            let before = try Data(contentsOf: file)
            repository.save(try padded(original, toByteCount: count))
            let result = repository.flush()
            XCTAssertEqual(result.requestedRevision, 2)
            if count < byteLimit {
                XCTAssertTrue(result.isFlushed)
                XCTAssertEqual(result.committedRevision, 2)
                XCTAssertEqual(try Data(contentsOf: file).count, count)
            } else {
                XCTAssertFalse(result.isFlushed)
                XCTAssertEqual(result.committedRevision, 1)
                XCTAssertNotNil(result.error)
                XCTAssertEqual(try Data(contentsOf: file), before)
                XCTAssertEqual(writer.lock.withLock { writer.sizes.count }, 1,
                               "an oversized value must never reach the writer")
            }
            let restarted = SessionRepository(); restarted.url = file
            XCTAssertNotNil(restarted.load(), "every successful write must remain readable")
            XCTAssertNil(restarted.error)
        }
    }

    func testNativeAndAOOverflowPreserveDiskUnreadAndAllowLaterLegalRevision() throws {
        let original = unreadSnapshot()
        var aoOverflow = original
        let template = try XCTUnwrap(original.aoAttentionRecords?.first)
        aoOverflow.aoAttentionRecords = (0..<9_000).map { index in
            var record = template
            record.observation.sessionID = "proj-wait-\(index)"
            return record
        }
        guard try JSONEncoder().encode(aoOverflow).count >= byteLimit else {
            return XCTFail("AO overflow fixture must exceed the encoded byte limit")
        }
        let nativeOverflow = try padded(original, toByteCount: byteLimit)
        for oversized in [nativeOverflow, aoOverflow] {
            let file = try root().appendingPathComponent("snapshot.json")
            let writer = CountingWriter()
            let repository = SessionRepository(coalesces: true, writer: { try writer.write($0, $1) })
            repository.url = file
            repository.save(original)
            XCTAssertTrue(repository.flush().isFlushed)
            let before = try Data(contentsOf: file)
            repository.save(oversized)
            for _ in 0..<3 {
                let failure = repository.flush()
                XCTAssertFalse(failure.isFlushed)
                XCTAssertEqual(failure.requestedRevision, 2)
                XCTAssertEqual(failure.committedRevision, 1)
                XCTAssertNotNil(failure.error)
                XCTAssertTrue(failure.error?.contains("4 MiB") == true)
                XCTAssertEqual(try Data(contentsOf: file), before)
            }
            XCTAssertEqual(writer.lock.withLock { writer.sizes.count }, 1)
            XCTAssertEqual(repository.load()?.aoAttentionRecords, original.aoAttentionRecords)
            XCTAssertFalse(repository.status.isFlushed, "loading old disk data cannot commit pending memory")
            XCTAssertTrue(oversized.sessions[0].hasUnread)
            XCTAssertTrue(oversized.aoAttentionRecords?.allSatisfy(\.hasUnread) == true)
            let restored = SessionStore(); restored.persistenceURL = file
            restored.restoreCodexSessions()
            XCTAssertTrue(try XCTUnwrap(restored.session(id: "synthetic")).hasUnread)
            XCTAssertEqual(restored.sessions.flatMap { $0.aoAttentionReceipts ?? [] }, original.aoAttentionRecords)
            XCTAssertNil(restored.persistenceError)
            var legal = original
            legal.sessions[0].title = "合法的新修订"
            repository.save(legal)
            let recovered = repository.flush()
            XCTAssertTrue(recovered.isFlushed)
            XCTAssertEqual(recovered.requestedRevision, 3)
            XCTAssertEqual(recovered.committedRevision, 3)
            XCTAssertNil(recovered.error)
            XCTAssertEqual(writer.lock.withLock { writer.sizes.count }, 2)
            XCTAssertEqual(repository.load()?.sessions.first?.title, "合法的新修订")
            XCTAssertEqual(repository.load()?.aoAttentionRecords, original.aoAttentionRecords)
        }
    }

    func testBurstCoalescesPendingValueAndOldWriterCannotOverwriteNewRevision() throws {
        let probe = WriterProbe()
        let repository = SessionRepository(coalesces: true, writer: { try probe.write($0, $1) })
        repository.url = try root().appendingPathComponent("codex-sessions-v1.json")
        repository.save(snapshot("first"))
        defer { probe.release.signal() }
        XCTAssertEqual(probe.started.wait(timeout: .now() + 2), .success)
        for index in 1...100 { repository.save(snapshot(String(index))) }
        XCTAssertEqual(repository.status.requestedRevision, 101)
        probe.release.signal()
        XCTAssertTrue(repository.flush().isFlushed)
        XCTAssertEqual(repository.status.committedRevision, 101)
        XCTAssertEqual(try JSONDecoder().decode(SessionSnapshotDTO.self,
            from: Data(contentsOf: XCTUnwrap(repository.url))).sessions.first?.title, "100")
        XCTAssertEqual(probe.lock.withLock { probe.titles }, ["first", "100"])
        XCTAssertTrue(repository.flush().isFlushed)
    }

    func testFailedLatestSaveIsVisibleRetainedAndFlushRetriesAfterStorageRecovery() throws {
        let base = try root(); let blocked = base.appendingPathComponent("blocked")
        try Data("synthetic".utf8).write(to: blocked)
        let repository = SessionRepository(coalesces: true)
        repository.url = blocked.appendingPathComponent("codex-sessions-v1.json")
        repository.save(snapshot("latest"))
        let failure = repository.flush()
        XCTAssertFalse(failure.isFlushed); XCTAssertEqual(failure.requestedRevision, 1)
        XCTAssertEqual(failure.committedRevision, 0); XCTAssertNotNil(failure.error)
        try FileManager.default.removeItem(at: blocked)
        let success = repository.flush()
        XCTAssertTrue(success.isFlushed); XCTAssertNil(success.error)
        XCTAssertEqual(repository.load()?.sessions.first?.title, "latest")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: XCTUnwrap(repository.url).path)[.posixPermissions] as? Int, 0o600)
    }

    func testDamagedV1IsNotOverwrittenByQueuedSaveOrFlush() throws {
        let file = try root().appendingPathComponent("codex-sessions-v1.json")
        let damaged = Data("{synthetic-damaged".utf8); try damaged.write(to: file)
        let repository = SessionRepository(coalesces: true); repository.url = file
        XCTAssertNil(repository.load())
        repository.save(snapshot("must-not-write"))
        XCTAssertFalse(repository.flush().isFlushed)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testProductionModeFlushPreservesAgyFloorReceiptAndOpencodeCheckpoint() throws {
        let file = try root().appendingPathComponent("codex-sessions-v1.json")
        let store = SessionStore(coalescesSnapshotWrites: true); store.persistenceURL = file
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        var agy = AgentEvent(sessionId: "synthetic-agy", agentKind: .antigravity, eventName: "working", timestamp: at)
        agy.antigravityStepFloor = 20; store.apply(agy, now: at)
        agy.timestamp = at.addingTimeInterval(1); agy.antigravityStepFloor = 25
        let clicked = try XCTUnwrap(store.apply(agy, now: agy.timestamp))
        XCTAssertTrue(store.markOpened(clicked, at: at.addingTimeInterval(2)))
        var opencode = AgentEvent(sessionId: "synthetic-opencode", agentKind: .opencode, eventName: "working", timestamp: at)
        opencode.opencodeTurnID = "turn"; opencode.opencodeNewTurn = true; opencode.opencodeProcessID = 2_000_000_000
        store.apply(opencode, now: at)
        opencode.eventName = "heartbeat"; opencode.timestamp = at.addingTimeInterval(61)
        store.apply(opencode, now: opencode.timestamp)
        XCTAssertTrue(store.flushSnapshots().isFlushed)
        let restored = SessionStore(); restored.persistenceURL = file; restored.restoreCodexSessions()
        XCTAssertEqual(restored.sessions.sorted { $0.id < $1.id }, store.sessions.sorted { $0.id < $1.id })
        XCTAssertEqual(restored.session(id: agy.sessionId)?.antigravityStepFloor, 25)
        XCTAssertTrue(restored.session(id: agy.sessionId)?.hasReadReceipt ?? false)
        XCTAssertEqual(restored.session(id: opencode.sessionId)?.opencodeCheckpointAt, opencode.timestamp)
    }
}
