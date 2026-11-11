import XCTest
import Foundation
@testable import AgentPetCore

final class TokenUsageCollectorTests: XCTestCase {
    func testExplicitActivationRemovalAndColdReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-worker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let instance = TokenUsageInstance(source: .codex, root: root)
        let reader: TokenUsageCollector.Reader = { _, _, _ in
            var result = TokenReadResult(); result.files = ["log"]
            result.records = [TokenRecord(id: "old", occurredAt: start.addingTimeInterval(-1), revision: 1, agent: .codex, buckets: try! .init(input: 10, cacheRead: 0, cacheWrite: 0, output: 5)), TokenRecord(id: "new", occurredAt: start.addingTimeInterval(1), revision: 2, agent: .codex, buckets: try! .init(input: 20, cacheRead: 0, cacheWrite: 0, output: 5))]
            return result
        }
        let url = root.appendingPathComponent("l.sqlite"), worker = TokenUsageCollector(url: root.appendingPathComponent("l.sqlite"), mode: "test", reader: reader)
        let before = try await worker.poll(eligible: [instance], now: start)
        XCTAssertEqual(before.total, 0); XCTAssertTrue(before.states.isEmpty)
        try await worker.enable(instance, at: start)
        let active = try await worker.poll(eligible: [instance], now: start.addingTimeInterval(2))
        XCTAssertEqual(active.total, 25)
        let cold = TokenUsageCollector(url: url, mode: "test", reader: reader)
        let replay = try await cold.poll(eligible: [instance], now: start.addingTimeInterval(3)); XCTAssertEqual(replay.total, 25)
        let removed = try await cold.poll(eligible: [], removedIDs: [instance.id], now: start.addingTimeInterval(4)); XCTAssertEqual(removed.total, 0)
        let states = try await cold.states(); XCTAssertFalse(states[0].enabled)
    }
    func testUnreadableInterfaceCannotEstablishFormalStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-block-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = TokenUsageCollector(url: root.appendingPathComponent("l.sqlite"), mode: "test", reader: { _,_,_ in var r = TokenReadResult(); r.quality = .failed; return r })
        do { try await worker.enable(.init(source: .dsh, root: root), at: Date()); XCTFail("must reject unreadable source") } catch {}
        let states = try await worker.states(); XCTAssertTrue(states.isEmpty)
    }

    func testIntegrationAutomaticallyActivatesAndReinstallExcludesRemovedGap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-auto-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let instance = TokenUsageInstance(source: .codex, root: root)
        let reader: TokenUsageCollector.Reader = { _, _, now in
            var result = TokenReadResult()
            result.records = [-1, 1, 4, 6].filter { start.addingTimeInterval(Double($0)) <= now }.map {
                TokenRecord(id: String($0), occurredAt: start.addingTimeInterval(Double($0)), revision: 1,
                            agent: .codex, buckets: try! .init(input: 10, cacheRead: 0, cacheWrite: 0, output: 0))
            }
            return result
        }
        let url = root.appendingPathComponent("l.sqlite")
        let worker = TokenUsageCollector(url: url, mode: "test", reader: reader)
        let initial = try await worker.poll(eligible: [instance], automaticallyStart: true, now: start)
        XCTAssertEqual(initial.states.first?.startedAt, start)
        XCTAssertTrue(initial.states.first?.enabled == true)
        XCTAssertEqual(initial.total, 0, "Do not import history from before integration")
        let active = try await worker.poll(eligible: [instance], automaticallyStart: true, now: start.addingTimeInterval(2))
        XCTAssertEqual(active.total, 10)
        _ = try await worker.poll(eligible: [], removedIDs: [instance.id], automaticallyStart: true, now: start.addingTimeInterval(3))
        let cold = TokenUsageCollector(url: url, mode: "test", reader: reader)
        let reinstalled = try await cold.poll(eligible: [instance], automaticallyStart: true, now: start.addingTimeInterval(5))
        XCTAssertEqual(reinstalled.states.first?.startedAt, start)
        XCTAssertTrue(reinstalled.states.first?.enabled == true)
        XCTAssertEqual(reinstalled.total, 10, "Removed interval must not be backfilled")
        let resumed = try await cold.poll(eligible: [instance], automaticallyStart: true, now: start.addingTimeInterval(7))
        XCTAssertEqual(resumed.total, 20)
        XCTAssertEqual(resumed.states.first?.intervals.count, 2)
    }

    func testIntegratedLegacyPausedStateResumesNowWithoutBackfillingGap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-pause-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let instance = TokenUsageInstance(source: .dsh, root: root), url = root.appendingPathComponent("l.sqlite")
        let reader: TokenUsageCollector.Reader = { _, _, now in
            var result = TokenReadResult()
            result.records = [2, 4].filter { start.addingTimeInterval(Double($0)) <= now }.map {
                .init(id: String($0), occurredAt: start.addingTimeInterval(Double($0)), revision: 1,
                      agent: .dsh, buckets: try! .init(input: 10, cacheRead: 0, cacheWrite: 0, output: 0))
            }
            return result
        }
        let worker = TokenUsageCollector(url: url, mode: "test", reader: reader)
        _ = try await worker.poll(eligible: [instance], automaticallyStart: true, now: start)
        try await worker.pause(instance.id, at: start.addingTimeInterval(1))
        let old = try await worker.states()
        XCTAssertEqual(old.first?.pauseReason, .user)
        // Older optional-field encodings still decode. Current integration
        // eligibility, rather than any legacy independent switch, drives reads.
        let encoded = try JSONEncoder().encode(old[0])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pauseReason")
        let legacy = try JSONDecoder().decode(TokenCollectionState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.pauseReason); XCTAssertFalse(legacy.enabled)
        _ = try await worker.poll(eligible: [], removedIDs: [instance.id], automaticallyStart: true, now: start.addingTimeInterval(2))
        let cold = TokenUsageCollector(url: url, mode: "test", reader: reader)
        let resumed = try await cold.poll(eligible: [instance], automaticallyStart: true, now: start.addingTimeInterval(3))
        XCTAssertTrue(try XCTUnwrap(resumed.states.first).enabled)
        XCTAssertNil(resumed.states.first?.pauseReason)
        XCTAssertEqual(resumed.states.first?.intervals.count, 2)
        XCTAssertEqual(resumed.states.first?.startedAt, start)
        XCTAssertEqual(resumed.total, 0, "Do not backfill the previously closed interval")
        let active = try await cold.poll(eligible: [instance], automaticallyStart: true, now: start.addingTimeInterval(5))
        XCTAssertEqual(active.total, 10)
        XCTAssertEqual(active.states.first?.intervals.count, 2, "Refresh must not create another interval")
    }

    func testMissingDataKeepsStartAndDoesNotBlockHealthyIntegratedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-mixed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = TokenUsageInstance(source: .codex, root: root), dsh = TokenUsageInstance(source: .dsh, root: root)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let worker = TokenUsageCollector(url: root.appendingPathComponent("l.sqlite"), mode: "test", reader: { instance, _, now in
            var result = TokenReadResult()
            if instance.source == .dsh {
                if now == start { result.quality = .failed; result.issue("usage.error.unavailable") }
                else { result.records = [.init(id: "first", occurredAt: start.addingTimeInterval(1), revision: 1,
                    agent: .dsh, buckets: try! .init(input: 10, cacheRead: 0, cacheWrite: 0, output: 0))] }
            }
            return result
        })
        let snapshot = try await worker.poll(eligible: [codex, dsh], automaticallyStart: true, now: start)
        XCTAssertEqual(Set(snapshot.states.map(\.instance.id)), [codex.id, dsh.id])
        XCTAssertTrue(snapshot.states.allSatisfy(\.enabled))
        XCTAssertEqual(snapshot.states.first { $0.instance == dsh }?.quality, .failed)
        XCTAssertTrue(snapshot.states.first { $0.instance == dsh }?.issues.contains("usage.error.unavailable") == true)
        let later = try await worker.poll(eligible: [codex, dsh], automaticallyStart: true, now: start.addingTimeInterval(2))
        XCTAssertEqual(later.total, 10, "The first call must count even if its file did not exist at Install")
        XCTAssertEqual(later.states.first { $0.instance == dsh }?.startedAt, start)
    }
}
