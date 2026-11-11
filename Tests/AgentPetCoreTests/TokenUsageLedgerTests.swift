import XCTest
import Foundation
@testable import AgentPetCore

final class TokenUsageLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_337_600)
    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("token-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func record(_ id: String = "call", at: Date, revision: Int64 = 1, tokens: Int64 = 5) throws -> TokenRecord {
        .init(id: id, occurredAt: at, revision: revision, agent: .dsh, buckets: try .init(input: tokens, cacheRead: 2, cacheWrite: 0, output: 3))
    }
    func testReopenReplayRevisionAndFormalStart() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger.sqlite"), source = TokenUsageInstance(source: .dsh, root: root)
        let start = now.addingTimeInterval(-3600)
        var ledger: TokenUsageLedger? = try .init(url: url, mode: "test")
        try ledger!.enable(source, at: start); try ledger!.enable(source, at: now)
        var result = TokenReadResult(); result.files = ["file"]
        result.records = [try record(at: start.addingTimeInterval(-1)), try record(at: start.addingTimeInterval(1))]
        try ledger!.ingest(result, instanceID: source.id, checkedAt: now)
        let first = try ledger!.snapshot(eligibleIDs: [source.id], now: now)
        XCTAssertEqual(first.total, 10); XCTAssertEqual(first.days.count, 30)
        ledger = nil; ledger = try .init(url: url, mode: "test")
        try ledger!.ingest(result, instanceID: source.id, checkedAt: now)
        XCTAssertEqual(try ledger!.snapshot(eligibleIDs: [source.id], now: now).total, 10)
        result.records = [try record(at: start.addingTimeInterval(1), revision: 2, tokens: 8)]
        try ledger!.ingest(result, instanceID: source.id, checkedAt: now)
        XCTAssertEqual(try ledger!.snapshot(eligibleIDs: [source.id], now: now).total, 13)
        XCTAssertEqual(try ledger!.states().first?.startedAt, start)
        XCTAssertThrowsError(try TokenUsageLedger(url: url, mode: "formal"))
        XCTAssertEqual(try ledger!.snapshot(eligibleIDs: [], now: now).total, 0)
    }
    func testPauseGapMissingFilesAndBadRevisions() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let source = TokenUsageInstance(source: .dsh, root: root), ledger = try TokenUsageLedger(url: root.appendingPathComponent("l.sqlite"), mode: "test")
        try ledger.enable(source, at: now.addingTimeInterval(-100))
        try ledger.pause(instanceID: source.id, at: now.addingTimeInterval(-80))
        try ledger.enable(source, at: now.addingTimeInterval(-40))
        var result = TokenReadResult(); result.files = ["known"]
        result.records = [try record("before", at: now.addingTimeInterval(-90)), try record("gap", at: now.addingTimeInterval(-60)), try record("after", at: now.addingTimeInterval(-20))]
        try ledger.ingest(result, instanceID: source.id, checkedAt: now)
        XCTAssertEqual(try ledger.snapshot(eligibleIDs: [source.id], now: now).total, 20)
        result.records = [try record("after", at: now.addingTimeInterval(-10), revision: 2, tokens: 100)]
        result.files = []
        try ledger.ingest(result, instanceID: source.id, checkedAt: now)
        let snapshot = try ledger.snapshot(eligibleIDs: [source.id], now: now)
        XCTAssertEqual(snapshot.total, 20); XCTAssertNotEqual(snapshot.days.last?.coverage, .complete)
        XCTAssertTrue(try ledger.states()[0].issues.contains("usage.issue.changedTime"))
        XCTAssertTrue(try ledger.states()[0].issues.contains("usage.issue.missingFiles"))
    }
    func testCalendarDSTAndUnknownNotZero() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try TokenUsageLedger(url: root.appendingPathComponent("l.sqlite"), mode: "test"), source = TokenUsageInstance(source: .dsh, root: root)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let end = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let start = calendar.date(byAdding: .day, value: -30, to: end)!
        try ledger.enable(source, at: start)
        let unknown = try ledger.snapshot(eligibleIDs: [source.id], now: end, calendar: calendar)
        XCTAssertEqual(unknown.days.last?.coverage, .unknown)
        let result = TokenReadResult(); try ledger.ingest(result, instanceID: source.id, checkedAt: end)
        let checked = try ledger.snapshot(eligibleIDs: [source.id], now: end, calendar: calendar)
        XCTAssertEqual(checked.days.count, 30); XCTAssertEqual(Set(checked.days.map(\.date)).count, 30)
        XCTAssertTrue(zip(checked.days, checked.days.dropFirst()).contains { $1.date.timeIntervalSince($0.date) == 25 * 3600 })
        XCTAssertEqual(checked.days.last?.coverage, .complete)
    }
    func testRejectInvalidCountBooleanAndSourceAttribution() throws {
        XCTAssertThrowsError(try UsageJSON.count(true)); XCTAssertThrowsError(try UsageJSON.count(-1)); XCTAssertThrowsError(try UsageJSON.count(1.2))
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try TokenUsageLedger(url: root.appendingPathComponent("l.sqlite"), mode: "test"), source = TokenUsageInstance(source: .dsh, root: root)
        try ledger.enable(source, at: now.addingTimeInterval(-10))
        var result = TokenReadResult()
        result.records = [.init(id: "wrong", occurredAt: now, revision: 1, agent: .agy, buckets: .zero, provider: "gemini")]
        try ledger.ingest(result, instanceID: source.id, checkedAt: now)
        XCTAssertTrue(try ledger.snapshot(eligibleIDs: [source.id], now: now).records.isEmpty)
        XCTAssertEqual(try ledger.states()[0].quality, .partial)
    }
    func testSubmillisecondTimeSurvivesReopenAndRevision() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSinceReferenceDate: 815003211.000081)
        let time = start.addingTimeInterval(1)
        let source = TokenUsageInstance(source: .dsh, root: root), url = root.appendingPathComponent("l.sqlite")
        var ledger: TokenUsageLedger? = try .init(url: url, mode: "test")
        try ledger!.enable(source, at: start)
        var result = TokenReadResult(); result.records = [try record(at: time)]
        try ledger!.ingest(result, instanceID: source.id, checkedAt: start.addingTimeInterval(10))
        ledger = nil; ledger = try .init(url: url, mode: "test")
        XCTAssertEqual(try ledger!.states()[0].startedAt, start)
        result.records = [try record(at: time, revision: 2, tokens: 8)]
        try ledger!.ingest(result, instanceID: source.id, checkedAt: start.addingTimeInterval(20))
        let snapshot = try ledger!.snapshot(eligibleIDs: [source.id], now: start.addingTimeInterval(20))
        XCTAssertEqual(snapshot.total, 13)
        XCTAssertEqual(snapshot.records.first?.occurredAt, time)
    }
}
