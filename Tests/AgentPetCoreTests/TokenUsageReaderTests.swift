import XCTest
import Foundation
import CSQLite
import CUsageZstd
@testable import AgentPetCore

final class TokenUsageReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-read-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func rows(_ input: [[String: Any]]) -> [(Int64, [String: Any])] { input.enumerated().map { (Int64($0.offset), $0.element) } }
    private func dshEvent(_ seq: Int, _ type: String, _ usage: [String: Any]? = nil, provider: String = "antigravity") -> [String: Any] {
        var data: [String: Any] = ["turn": 1, "step": 1, "message": ["source": ["provider": provider, "model": "gemini"]]]
        if let usage { data["usage"] = usage }
        return ["seq": seq, "type": type, "time": 1_999_999_900_000 + seq * 1000, "data": data]
    }
    func testDSHRetryRevisionAndExclusiveAgyAttribution() throws {
        let usage: [String: Any] = ["inputTokens": 10, "cacheReadTokens": 20, "outputTokens": 5]
        var revised = usage; revised["inputTokens"] = 11
        let result = TokenUsageParsers.dsh(rows([
            ["type": "session", "version": 4, "id": "s", "isSeeded": false],
            dshEvent(0, "assistant/attempt", usage), dshEvent(1, "llm/retry-started"),
            dshEvent(2, "assistant/message", usage, provider: "other"), dshEvent(3, "assistant/message", revised, provider: "other")
        ]))
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.buckets.total }, 71)
        XCTAssertEqual(result.records.filter { $0.agent == .agy }.count, 1)
        XCTAssertEqual(result.records.first { $0.agent == .dsh }?.occurredAt, Date(timeIntervalSince1970: 1_999_999_902))
        XCTAssertEqual(result.quality, .complete)
    }
    func testSeedRequiresAuthoritativeCut() {
        let header: [String: Any] = ["type": "session", "version": 4, "id": "fork", "isSeeded": true]
        let u: [String: Any] = ["inputTokens": 1, "outputTokens": 2]
        let unknown = TokenUsageParsers.dsh(rows([header, dshEvent(0, "assistant/message", u)]))
        XCTAssertTrue(unknown.records.isEmpty); XCTAssertEqual(unknown.quality, .partial)
        let valid = TokenUsageParsers.dsh(rows([header, dshEvent(0, "assistant/message", u), ["seq": 1, "type": "session/end-seed", "data": ["inherited": true]], dshEvent(2, "assistant/message", u)]))
        XCTAssertEqual(valid.records.count, 1); XCTAssertEqual(valid.records[0].revision, 2)
    }
    func testCodexFirstCallDuplicateAndForkCut() throws {
        let u: [String: Any] = ["input_tokens": 10, "cached_input_tokens": 4, "output_tokens": 5, "reasoning_output_tokens": 3, "total_tokens": 15]
        let twice: [String: Any] = ["input_tokens": 20, "cached_input_tokens": 8, "output_tokens": 10, "reasoning_output_tokens": 6, "total_tokens": 30]
        func event(_ ordinal: Int, _ total: [String: Any]) -> [String: Any] {
            ["type": "event_msg", "ordinal": ordinal, "timestamp": "2033-05-18T03:32:00Z", "payload": ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": u]]]
        }
        let header: [String: Any] = ["type": "session_meta", "payload": ["id": "codex"]]
        let result = TokenUsageParsers.codex(rows([header, event(1, u), event(2, u), event(3, twice)]), fileID: "f")
        XCTAssertEqual(result.records.count, 2); XCTAssertEqual(result.records[0].buckets.input, 6)
        XCTAssertEqual(result.records[0].buckets.output, 5)
        let fork: [String: Any] = ["type": "session_meta", "payload": ["id": "fork", "forked_from_id": "codex", "forked_from_ordinal_exclusive": 3]]
        XCTAssertEqual(TokenUsageParsers.codex(rows([fork, event(1, u), event(3, twice)]), fileID: "f").records.count, 1)
    }
    func testFileReaderTailMissingAndSymlink() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let instance = TokenUsageInstance(source: .dsh, root: root)
        XCTAssertEqual(TokenUsageReader.read(instance, since: .distantPast, now: now).quality, .failed)
        let dir = root.appendingPathComponent("sessions/s"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("session.v4.jsonl")
        var data = try JSONSerialization.data(withJSONObject: ["type": "session", "version": 4, "id": "s", "isSeeded": false]); data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: dshEvent(0, "assistant/message", ["inputTokens": 5, "outputTokens": 6])))
        try data.write(to: path)
        let half = TokenUsageReader.read(instance, since: .distantPast, now: now)
        XCTAssertEqual(half.quality, .partial); XCTAssertTrue(half.records.isEmpty)
        data.append(10); try data.write(to: path)
        let before = try Data(contentsOf: path)
        XCTAssertEqual(TokenUsageReader.read(instance, since: .distantPast, now: now).records.count, 1)
        XCTAssertEqual(try Data(contentsOf: path), before)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sessions/link"), withDestinationURL: dir)
        XCTAssertEqual(TokenUsageReader.read(instance, since: .distantPast, now: now).records.count, 1)
    }

    func testCodexUnchangedCumulativeSnapshotPreservesNextCall() throws {
        let usage: [String: Any] = ["input_tokens": 10, "cached_input_tokens": 4, "output_tokens": 5, "total_tokens": 15]
        let twice: [String: Any] = ["input_tokens": 20, "cached_input_tokens": 8, "output_tokens": 10, "total_tokens": 30]
        let estimate: [String: Any] = ["input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0, "total_tokens": 42]
        func event(_ ordinal: Int, _ total: [String: Any], _ last: [String: Any]) -> [String: Any] {
            ["type": "event_msg", "ordinal": ordinal, "timestamp": "2033-05-18T03:32:00Z", "payload": ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last]]]
        }
        let header: [String: Any] = ["type": "session_meta", "payload": ["id": "codex"]]
        let result = TokenUsageParsers.codex(rows([header, event(1, usage, usage), event(2, usage, estimate), event(3, twice, usage)]), fileID: "f")
        XCTAssertEqual(result.quality, .complete)
        XCTAssertEqual(result.records.map(\.id), ["codex:1", "codex:3"])
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.buckets.total }, 30)

        // A changed cumulative counter with an inconsistent last count still
        // fails validation; this is not permission to trust arbitrary metadata.
        let invalid = TokenUsageParsers.codex(rows([header, event(1, usage, usage), event(2, twice, estimate)]), fileID: "f")
        XCTAssertEqual(invalid.records.count, 1)
        XCTAssertTrue(invalid.issues.contains("usage.error.invalid"))
    }

    func testCodexLargeTranscriptStreamsAcrossChunksWithNativeOffsets() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("large.jsonl")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)
        func write(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10); try handle.write(contentsOf: data)
        }
        let usage: [String: Any] = ["input_tokens": 10, "cached_input_tokens": 4, "output_tokens": 5, "total_tokens": 15]
        let twice: [String: Any] = ["input_tokens": 20, "cached_input_tokens": 8, "output_tokens": 10, "total_tokens": 30]
        try write(["type": "session_meta", "payload": ["id": "large"]])
        try write(["type": "turn_context", "payload": ["model": "fixture", "developer_instructions": String(repeating: "界", count: 30_000)]])
        try write(["type": "event_msg", "ordinal": 1, "timestamp": "2033-05-18T03:32:00Z", "payload": ["type": "token_count", "info": ["total_token_usage": usage, "last_token_usage": usage]]])
        var body = try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["text": String(repeating: "x", count: 65_536)]]); body.append(10)
        for _ in 0..<1025 { try handle.write(contentsOf: body) }
        let offset = try handle.offset()
        try write(["type": "event_msg", "timestamp": "2033-05-18T03:32:01Z", "payload": ["type": "token_count", "info": ["total_token_usage": twice, "last_token_usage": usage]]])
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
        XCTAssertGreaterThan(offset, 64 * 1024 * 1024)
        let result = TokenUsageReader.read(.init(source: .codex, root: root), since: now.addingTimeInterval(-1000), now: now)
        XCTAssertEqual(result.quality, .complete)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.buckets.total }, 30)
        XCTAssertTrue(result.records.contains { $0.id == "large:\(TokenUsageInstance.digest(path.lastPathComponent)):offset-\(offset)" })
        XCTAssertTrue(result.records.allSatisfy { $0.model == "fixture" })
    }

    func testCodexStreamingWaitsForCommittedTail() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("tail.jsonl")
        let usage: [String: Any] = ["input_tokens": 10, "cached_input_tokens": 4, "output_tokens": 5, "total_tokens": 15]
        var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": "tail"]]); data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: ["type": "event_msg", "ordinal": 1, "timestamp": "2033-05-18T03:32:00Z", "payload": ["type": "token_count", "info": ["total_token_usage": usage, "last_token_usage": usage]]]))
        try data.write(to: path)
        let instance = TokenUsageInstance(source: .codex, root: root)
        let partial = TokenUsageReader.read(instance, since: .distantPast, now: now)
        XCTAssertTrue(partial.records.isEmpty)
        XCTAssertTrue(partial.issues.contains("usage.error.partial"))
        data.append(10); try data.write(to: path)
        let committed = TokenUsageReader.read(instance, since: .distantPast, now: now)
        XCTAssertEqual(committed.quality, .complete)
        XCTAssertEqual(committed.records.first?.buckets.total, 15)
        XCTAssertEqual(try Data(contentsOf: path), data)
    }
    func testOpenCodeDualProjectionForkAndIndependentReasoning() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("opencode.db"); var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT);
        CREATE TABLE session_message(id TEXT,session_id TEXT,type TEXT,time_created INTEGER,time_updated INTEGER,data TEXT);
        CREATE TABLE session_v2(id TEXT,fork_session_id TEXT,time_created INTEGER);
        INSERT INTO session_v2 VALUES('original',NULL,1999999000000),('fork','original',1999999990000);
        INSERT INTO message VALUES('same','original',1999999900000,1999999950000,'{"role":"assistant","tokens":{"input":10,"output":3,"reasoning":2,"cache":{"read":20,"write":4}},"time":{"created":1999999900000,"completed":1999999950000}}');
        INSERT INTO session_message SELECT id,session_id,'assistant',time_created,time_updated,data FROM message;
        INSERT INTO session_message SELECT 'fork-copy','fork','assistant',time_created,time_updated,data FROM message;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let result = TokenUsageReader.read(.init(source: .opencode, root: root), since: now.addingTimeInterval(-1000), now: now)
        XCTAssertEqual(result.quality, .complete); XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.buckets.total, 39); XCTAssertEqual(result.records.first?.buckets.output, 5)
    }
    func testFrozenP0DSHCountsMatchValidatedSDK() throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTPET_TOKEN_P0_FIXTURES"] else { throw XCTSkip("Optional private frozen metadata fixture") }
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let samples = file["dsh"] as! [[String: Any]]
        var calls = 0
        var buckets = TokenBuckets.zero
        for sample in samples {
            let header: [String: Any] = ["type": "session", "version": 4, "id": sample["session_id"]!, "isSeeded": sample["seeded"]!]
            let result = TokenUsageParsers.dsh(rows([header] + (sample["events"] as! [[String: Any]])))
            calls += result.records.count
            for record in result.records { buckets = try buckets.adding(record.buckets) }
        }
        XCTAssertEqual(calls, 289)
        let expectedURL = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("dsh-normalized-test-records.json")
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as! [String: Any]
        var expectedBuckets = TokenBuckets.zero
        for row in expected["records"] as! [[String: Any]] {
            let b = row["buckets"] as! [Int64]
            expectedBuckets = try expectedBuckets.adding(.init(input: b[0], cacheRead: b[1], cacheWrite: b[2], output: b[3]))
        }
        XCTAssertEqual(buckets, expectedBuckets)
    }

    func testSelfContainedZstdLargeOutputAndCorruption() throws {
        let compressed = Data(base64Encoded: "KLUv/QRY3AAAmHsidHlwZSI6ImZpeHR1cmUifQoBANX/LZ9hTAAACGkBAPz/ORACTAAACCIBAPz/ORACTAAACHgBAPz/ORACTQAACHQBAIwyHQgBIrKfVA==")!
        func decode(_ data: Data) -> (Int32, Data) {
            var pointer: UnsafeMutableRawPointer?, count = 0
            let code = data.withUnsafeBytes { usage_zstd_decode($0.baseAddress, $0.count, 2 * 1024 * 1024, &pointer, &count) }
            defer { usage_zstd_free(pointer) }
            return (code, pointer.map { Data(bytes: $0, count: count) } ?? Data())
        }
        let valid = decode(compressed)
        XCTAssertEqual(valid.0, 0)
        XCTAssertEqual(valid.1, Data(String(repeating: "{\"type\":\"fixture\"}\n", count: 30000).utf8))
        XCTAssertEqual(decode(Data(compressed.dropLast(3))).0, 1)
        XCTAssertLessThan(decode(Data("broken frame".utf8)).0, 0)
    }

    func testCompressedNativeFileColdReadIsIdempotent() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("sessions/compressed-fixture")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.v4.jsonl.zstd")
        let compressed = Data(base64Encoded: "KLUv/QRY7QUA0s0nH2BpmwMN022L7Cxt61f/58aHxoKgqHIVZpQGEAAbjgeG1lozWnGTEp8Xe5RcibMojV43R0lLeUEfWSypF/S1gWXJZwSYfMERkER8xoFW9IR0sEyh4wWZ+qrvQKPF1gs6N43PIDjQT876DLTC1ecnUvUJwKJcPappaFdFItDm5jfQ4/MX24WDOJirfqkkIUab4xPAdcVnlI7q1eirxXoJCgBOGykFQ7JSxoRDLuC7WbrBusTxexOq6FXET/kijg==")!
        try compressed.write(to: file)
        let instance = TokenUsageInstance(source: .dsh, root: root)
        let first = TokenUsageReader.read(instance, since: .distantPast, now: now)
        let second = TokenUsageReader.read(instance, since: .distantPast, now: now)
        XCTAssertEqual(first.quality, .complete)
        XCTAssertEqual(first.records.count, 1); XCTAssertEqual(first.records[0].agent, .agy)
        XCTAssertEqual(first.records[0].buckets.total, 35)
        XCTAssertEqual(first.records, second.records)
        XCTAssertEqual(try Data(contentsOf: file), compressed)
        try Data(compressed.dropLast(3)).write(to: file)
        XCTAssertEqual(TokenUsageReader.read(instance, since: .distantPast, now: now).quality, .partial)
    }
}
