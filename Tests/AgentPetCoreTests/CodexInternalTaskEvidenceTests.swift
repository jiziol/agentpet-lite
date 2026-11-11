import Foundation
import XCTest
import CSQLite
@testable import AgentPetCore

final class CodexInternalTaskEvidenceTests: XCTestCase {
    private let id = "00000000-0000-7000-8000-000000000001"
    private let adjacent = "00000000-0000-7000-8000-000000000002"
    private let instant = Date(timeIntervalSince1970: 1_792_200_000)

    private final class Fixture {
        let home: URL
        let state: URL
        let logs: URL
        init(metadata: Bool = true, index: Bool = true, logVersion: Int = 2) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-internal-evidence-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            state = home.appendingPathComponent("state_5.sqlite")
            logs = home.appendingPathComponent("logs_\(logVersion).sqlite")
            if metadata { try execute("CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT)", at: state) }
            try execute("""
                CREATE TABLE logs(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, ts_nanos INTEGER NOT NULL,
                target TEXT NOT NULL, feedback_log_body TEXT, thread_id TEXT, process_uuid TEXT);
                """, at: logs)
            if index {
                try execute("CREATE INDEX idx_logs_thread_id_ts ON logs(thread_id, ts DESC, ts_nanos DESC, id DESC)", at: logs)
            }
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        func execute(_ sql: String, at path: URL? = nil) throws {
            var db: OpaquePointer?
            guard sqlite3_open((path ?? logs).path, &db) == SQLITE_OK else { throw NSError(domain: "fixture-open", code: 1) }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "fixture-sql", code: 1) }
        }

        func row(id: String, time: Int64, body: String, target: String = "codex_core::session::handlers", process: String = "fixture-process") throws {
            var db: OpaquePointer?, statement: OpaquePointer?
            guard sqlite3_open(logs.path, &db) == SQLITE_OK else { throw NSError(domain: "fixture-open", code: 1) }
            defer { sqlite3_close(db) }
            guard sqlite3_prepare_v2(db, "INSERT INTO logs(ts,ts_nanos,target,feedback_log_body,thread_id,process_uuid) VALUES(?,0,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "fixture-prepare", code: 1) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, time)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, text) in [target, body, id, process].enumerated() {
                sqlite3_bind_text(statement, Int32(offset + 2), text, -1, transient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "fixture-insert", code: 1) }
        }

        func normalThread(id: String, title: String? = nil) throws {
            // UUIDs and the fixture title are controlled test data.
            let value = title.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
            try execute("INSERT INTO threads(id,title) VALUES('\(id)',\(value))", at: state)
        }
    }

    private func input(id: String? = nil, text: String? = nil) -> String {
        let text = text ?? "# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project. fixture continuation"
        let encoded = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return "session_loop{thread_id=\(id ?? self.id)}: Submission { op: TurnInput { request: TurnInputRequest { input: [Text { text: \(encoded), text_elements: [] }] } } }"
    }

    private func exit(id: String? = nil) -> String { "session_loop{thread_id=\(id ?? self.id)}: Agent loop exited" }

    private func titleSource(client: String = "aionui-title", method: String = "thread/start") -> String {
        "app_server.request{otel.kind=\"server\" rpc.method=\"\(method)\" rpc.transport=\"stdio\" app_server.client_name=\"\(client)\" app_server.client_version=\"1\"}:app_server.thread_start.create_thread{}: fixture snapshot ready"
    }

    func testAionUiTitleNativeCreationSpanClassifiesWithoutExitOrPromptInspection() throws {
        for text in ["User: Team fixture", "User: Ordinary chat", "A completely different title input"] {
            let f = try Fixture()
            try f.row(id: id, time: 1_792_199_900, body: input(text: text))
            try f.row(id: id, time: 1_792_199_901, body: titleSource(), target: "codex_core::shell_snapshot")
            try f.row(id: id, time: 1_792_199_902, body: "turn failed", target: "codex_core::session::turn")
            let before = try [f.state, f.logs].map { try Data(contentsOf: $0) }
            let record = try XCTUnwrap(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
            XCTAssertEqual(record.kind, "aionUiTitle")
            XCTAssertNil(record.exitedAt, "Title classification must not invent native exit evidence")
            XCTAssertEqual(record.observedAt, instant)
            XCTAssertEqual(before, try [f.state, f.logs].map { try Data(contentsOf: $0) })
            try f.normalThread(id: id)
            XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        }
    }

    func testTitleClientMentionInPromptWrongTargetOrLaterSpanCannotClassifyNormalTeam() throws {
        let cases: [(String, String, String)] = [
            (input(text: titleSource()), "codex_core::shell_snapshot", "fixture-process"),
            (titleSource(), "fixture::user_output", "fixture-process"),
            (titleSource(client: "aionui"), "codex_core::shell_snapshot", "fixture-process"),
            (titleSource(client: "aionui-title-extra"), "codex_core::shell_snapshot", "fixture-process"),
            (titleSource(method: "turn/start"), "codex_core::shell_snapshot", "fixture-process"),
            ("app_server.request{rpc.method=\"thread/start\" app_server.client_name=\"aionui\" }:" + titleSource(), "codex_core::shell_snapshot", "fixture-process"),
            (titleSource(), "codex_core::shell_snapshot", "other-process"),
        ]
        for (body, target, process) in cases {
            let f = try Fixture()
            try f.row(id: id, time: 1_792_199_900, body: input(text: "Normal team member task"))
            try f.row(id: id, time: 1_792_199_901, body: body, target: target, process: process)
            try f.row(id: id, time: 1_792_199_902, body: exit())
            XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant), body)
        }
    }

    func testTitleSourceRequiresCurrentExactThreadProcessAndValidTurn() throws {
        let f = try Fixture()
        try f.row(id: adjacent, time: 1_792_199_900, body: input(id: adjacent, text: "Title fixture"))
        try f.row(id: adjacent, time: 1_792_199_901, body: titleSource(), target: "codex_core::shell_snapshot")
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        let missingTurn = try Fixture()
        try missingTurn.row(id: id, time: 1_792_199_900, body: titleSource(), target: "codex_core::shell_snapshot")
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: missingTurn.home.path, now: instant))
        let changed = try Fixture()
        try changed.row(id: id, time: 1_792_199_900, body: input(text: "Title fixture"))
        try changed.row(id: id, time: 1_792_199_901, body: titleSource(), target: "codex_core::shell_snapshot")
        try changed.row(id: id, time: 1_792_199_902, body: "new process", process: "another-process")
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: changed.home.path, now: instant))
    }

    func testRedactedDesktopTransientRequiresExactFinalExitAndAbsentNativeThread() throws {
        let modern = "session_loop{thread_id=\(id)}: Submission thread_id=\(id) operation=\"turn_input\" parent_turn_id=None op=TurnInput { requested_settings: ThreadSettingsOverrides { approval_policy: None } }"
        for variant in ["valid", "running", "later", "otherProcess", "normalThread", "cli", "promptQuote"] {
            let f = try Fixture()
            try f.row(id: id, time: 1_792_199_900, body: modern)
            let client = variant == "cli" ? "codex-cli" : "Codex Desktop"
            let span = variant == "promptQuote" ? input(text: titleSource(client: client)) : titleSource(client: client)
            try f.row(id: id, time: 1_792_199_901, body: span, target: "codex_core::shell_snapshot")
            if variant != "running" {
                try f.row(id: id, time: 1_792_199_902, body: exit(), process: variant == "otherProcess" ? "other" : "fixture-process")
            }
            if variant == "later" { try f.row(id: id, time: 1_792_199_903, body: "new activity") }
            if variant == "normalThread" { try f.normalThread(id: id) }
            let record = CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant)
            if variant == "valid" { XCTAssertEqual(record?.kind, "desktopTransient"); XCTAssertNotNil(record?.exitedAt) }
            else { XCTAssertNil(record, variant) }
        }
    }

    private func populate(_ f: Fixture) throws {
        try f.row(id: id, time: 1_792_199_900, body: input())
        try f.row(id: id, time: 1_792_199_950, body: exit())
    }

    func testDesktopOwnerExitWithoutTerminalLogStillIdentifiesDisposableTask() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()
        let owner = "pid:\(pid):\(UUID().uuidString.lowercased())"
        let f = try Fixture()
        try f.row(id: id, time: 1_792_199_900, body: input(text: "Redacted internal input"), process: owner)
        try f.row(id: id, time: 1_792_199_901, body: titleSource(client: "Codex Desktop"),
                  target: "codex_core::shell_snapshot", process: owner)
        try f.row(id: id, time: 1_792_199_902, body: "ToolCall: exec", target: "codex_core::stream_events_utils", process: owner)
        let record = try XCTUnwrap(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        XCTAssertEqual(record.kind, "desktopProcessExited")
        XCTAssertNil(record.exitedAt, "OS absence establishes no exact native exit time or turn result")
    }

    func testLiveUnknownAndReusedOwnerStayVisibleCandidatesAndRetainExactSource() throws {
        let owner = "pid:12345:12345678-1234-4234-8234-123456789abc"
        let f = try Fixture()
        try f.row(id: id, time: 1_792_199_900, body: input(text: "redacted"), process: owner)
        try f.row(id: id, time: 1_792_199_901, body: titleSource(client: "Codex Desktop"),
                  target: "codex_core::shell_snapshot", process: owner)
        for alive: Bool? in [true, nil] {
            let record = try XCTUnwrap(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path,
                now: instant, processIsAlive: { pid in XCTAssertEqual(pid, 12345); return alive }))
            XCTAssertEqual(record.kind, "desktopTransientCandidate", "Alive includes a reused PID; unknown is not exit")
            XCTAssertEqual(record.desktopSource?.process, owner)
            XCTAssertNil(record.exitedAt)
        }
    }

    func testCapturedSourceSurvivesLogRotationButNativeThreadAndConflictingProcessWin() throws {
        let owner = "pid:12345:12345678-1234-4234-8234-123456789abc"
        let f = try Fixture()
        try f.row(id: id, time: 1_792_199_900, body: input(text: "redacted"), process: owner)
        try f.row(id: id, time: 1_792_199_901, body: titleSource(client: "Codex Desktop"),
                  target: "codex_core::shell_snapshot", process: owner)
        let candidate = try XCTUnwrap(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path,
            now: instant, processIsAlive: { _ in true }))
        try f.execute("DELETE FROM logs")
        let before = try [f.state, f.logs].map { try Data(contentsOf: $0) }
        let ended = try XCTUnwrap(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path,
            now: instant, cachedSource: candidate.desktopSource, processIsAlive: { _ in false }))
        XCTAssertEqual(ended.kind, "desktopProcessExited")
        XCTAssertNil(ended.exitedAt)
        XCTAssertEqual(before, try [f.state, f.logs].map { try Data(contentsOf: $0) })
        try f.row(id: id, time: 1_792_199_902, body: "different process", process: "other")
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path,
            now: instant, cachedSource: candidate.desktopSource, processIsAlive: { _ in false }))
        try f.execute("DELETE FROM logs")
        try f.normalThread(id: id)
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path,
            now: instant, cachedSource: candidate.desktopSource, processIsAlive: { _ in false }))
    }

    func testOwnerAbsenceNeedsExactDesktopSourceReadableMetadataAndValidProcessIdentity() throws {
        for variant in ["valid", "cli", "wrongTarget", "quoted", "wrongID", "wrongProcess", "noTurn", "normal", "unreadable", "missingIndex", "badPID", "zeroPID", "badUUID"] {
            let f = try Fixture(metadata: variant != "unreadable", index: variant != "missingIndex")
            let owner = variant == "badPID" ? "pid:-1:12345678-1234-4234-8234-123456789abc" :
                variant == "zeroPID" ? "pid:0:12345678-1234-4234-8234-123456789abc" :
                variant == "badUUID" ? "pid:12345:unknown" : "pid:12345:12345678-1234-4234-8234-123456789abc"
            if variant != "noTurn" { try f.row(id: id, time: 1_792_199_900, body: input(text: "redacted"), process: owner) }
            let span = titleSource(client: variant == "cli" ? "codex-cli" : "Codex Desktop")
            try f.row(id: variant == "wrongID" ? adjacent : id, time: 1_792_199_901,
                body: variant == "quoted" ? input(text: span) : span,
                target: variant == "wrongTarget" ? "fixture::output" : "codex_core::shell_snapshot",
                process: variant == "wrongProcess" ? "other" : owner)
            try f.row(id: id, time: 1_792_199_902, body: "ToolCall: exec", process: owner)
            if variant == "normal" { try f.normalThread(id: id) }
            let result = CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path,
                now: instant, processIsAlive: { _ in false })
            if variant == "valid" { XCTAssertEqual(result?.kind, "desktopProcessExited") }
            else { XCTAssertNil(result, variant) }
        }
    }

    func testCachedSourceCannotCrossSessionHomeOrFutureTime() throws {
        let f = try Fixture()
        for source in [
            CodexInternalTaskEvidence.DesktopSource(sessionID: adjacent, home: f.home.path,
                process: "pid:12345:12345678-1234-4234-8234-123456789abc", lastNativeAt: instant),
            .init(sessionID: id, home: "/other", process: "pid:12345:12345678-1234-4234-8234-123456789abc", lastNativeAt: instant),
            .init(sessionID: id, home: f.home.path, process: "pid:12345:12345678-1234-4234-8234-123456789abc", lastNativeAt: instant.addingTimeInterval(1))
        ] {
            XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path,
                now: instant, cachedSource: source, processIsAlive: { _ in false }))
        }
    }

    func testDesktopEphemeralForkIsRecognizedBeforeExitButPersistedForkWins() throws {
        let f = try Fixture()
        try f.row(id: id, time: 1_792_199_900,
            body: titleSource(client: "Codex Desktop", method: "thread/fork"), target: "codex_core::shell_snapshot")
        try f.row(id: id, time: 1_792_199_901, body: input(text: "Side conversation"))
        try f.row(id: id, time: 1_792_199_902, body: "working", target: "codex_core::session::turn")
        let before = try [f.state, f.logs].map { try Data(contentsOf: $0) }
        let record = try XCTUnwrap(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        XCTAssertEqual(record.kind, "desktopSideConversation")
        XCTAssertNil(record.exitedAt, "A side conversation can be hidden while its real turn is running")
        XCTAssertEqual(before, try [f.state, f.logs].map { try Data(contentsOf: $0) })
        try f.normalThread(id: id, title: "Saved fork")
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
    }

    func testDesktopSideConversationNeedsExactCreationSourceBeforeItsOwnInput() throws {
        for variant in ["wrongClient", "wrongMethod", "wrongTarget", "quotedSpan", "otherProcess", "adjacentID", "laterSpan", "missingMetadata", "noInput"] {
            let f = try Fixture(metadata: variant != "missingMetadata")
            var span = titleSource(client: variant == "wrongClient" ? "codex-cli" : "Codex Desktop",
                                   method: variant == "wrongMethod" ? "thread/start" : "thread/fork")
            if variant == "quotedSpan" { span = input(text: span) }
            try f.row(id: variant == "adjacentID" ? adjacent : id,
                time: variant == "laterSpan" ? 1_792_199_903 : 1_792_199_900, body: span,
                target: variant == "wrongTarget" ? "fixture::output" : "codex_core::shell_snapshot",
                process: variant == "otherProcess" ? "other" : "fixture-process")
            if variant != "noInput" { try f.row(id: id, time: 1_792_199_901, body: input(text: "Ordinary input")) }
            try f.row(id: id, time: 1_792_199_904, body: "working", target: "codex_core::session::turn")
            XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant), variant)
        }
    }

    func testExactNativePurposeAndConfirmedExitReturnsMetadataOnlyWithoutChangingDatabases() throws {
        let f = try Fixture(); try populate(f)
        let before = try [f.state, f.logs].map { try Data(contentsOf: $0) }
        let result = try XCTUnwrap(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        XCTAssertEqual(result, .init(sessionID: id, home: f.home.path, kind: "projectSuggestions",
            exitedAt: Date(timeIntervalSince1970: 1_792_199_950), observedAt: instant))
        XCTAssertEqual(before, try [f.state, f.logs].map { try Data(contentsOf: $0) })
    }

    func testMalformedOrAdjacentIdentityIsNeverMatched() throws {
        let f = try Fixture(); try populate(f)
        for candidate in ["", "../logs_2.sqlite", id + "x", adjacent] {
            XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: candidate, home: f.home.path, now: instant))
        }
        let other = try Fixture()
        try other.row(id: id, time: 1_792_199_900, body: input(id: adjacent))
        try other.row(id: id, time: 1_792_199_950, body: exit())
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: other.home.path, now: instant))
    }

    func testUserQuoteAndWrongLoggingTargetAreNotBuiltinPurpose() throws {
        for text in ["Please explain this prompt: # Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project", "I quoted text: \"# Overview\\n\\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project\""] {
            let f = try Fixture()
            try f.row(id: id, time: 1_792_199_900, body: input(text: text))
            try f.row(id: id, time: 1_792_199_950, body: exit())
            XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        }
        let f = try Fixture()
        try f.row(id: id, time: 1_792_199_900, body: input(), target: "fixture::user_output")
        try f.row(id: id, time: 1_792_199_950, body: exit())
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
    }

    func testMissingOrUnreadableMetadataIsUnknownNotAbsent() throws {
        let f = try Fixture(metadata: false); try populate(f)
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        try Data("not a sqlite database".utf8).write(to: f.state)
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
    }

    func testNormalThreadWithNoTitleAndAdjacentThreadMetadataAreDistinct() throws {
        let f = try Fixture(); try populate(f)
        try f.normalThread(id: adjacent)
        XCTAssertNotNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        try f.normalThread(id: id)
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
    }

    func testMissingIndexAndPartialOrChangedIndexFailClosed() throws {
        for index in ["", "CREATE INDEX idx_logs_thread_id_ts ON logs(thread_id)", "CREATE INDEX idx_logs_thread_id_ts ON logs(thread_id,ts,ts_nanos,id) WHERE target='codex_core::session::handlers'"] {
            let f = try Fixture(index: false)
            if !index.isEmpty { try f.execute(index) }
            try populate(f)
            XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        }
    }

    func testExitBeforePurposeOrFutureExitDoesNotConfirmTermination() throws {
        let before = try Fixture()
        try before.row(id: id, time: 1_792_199_800, body: exit())
        try before.row(id: id, time: 1_792_199_900, body: input())
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: before.home.path, now: instant))
        let future = try Fixture()
        try future.row(id: id, time: 1_792_199_900, body: input())
        try future.row(id: id, time: 1_792_200_001, body: exit())
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: future.home.path, now: instant))
    }

    func testAnyNewActivityAfterExitAndDifferentProcessKeepTaskVisible() throws {
        for body in [input(text: "Ordinary user task"), "session activity", "session_loop{thread_id=\(id)}: op: Shutdown"] {
            let f = try Fixture(); try populate(f)
            try f.row(id: id, time: 1_792_199_960, body: body)
            XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        }
        let f = try Fixture()
        try f.row(id: id, time: 1_792_199_900, body: input(), process: "before")
        try f.row(id: id, time: 1_792_199_950, body: exit(), process: "different")
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
    }

    func testFirstNormalTurnCannotBeReclassifiedByLaterBuiltinLookingText() throws {
        let f = try Fixture()
        try f.row(id: id, time: 1_792_199_890, body: input(text: "Ordinary task"))
        try populate(f)
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
    }

    func testSchemaDriftOrNewerUnknownDatabaseDoesNotFallbackToOldEvidence() throws {
        let f = try Fixture(); try populate(f)
        try f.execute("CREATE TABLE unrelated(id INTEGER)", at: f.home.appendingPathComponent("logs_10.sqlite"))
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        try FileManager.default.removeItem(at: f.home.appendingPathComponent("logs_10.sqlite"))
        try f.execute("ALTER TABLE logs RENAME COLUMN feedback_log_body TO changed_body")
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
    }

    func testUnindexedThreadMetadataAndOversizedNativeRequestAreUnknown() throws {
        let f = try Fixture(); try populate(f)
        try f.execute("DROP TABLE threads; CREATE TABLE threads(id TEXT, title TEXT)", at: f.state)
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: f.home.path, now: instant))
        let large = try Fixture()
        try large.row(id: id, time: 1_792_199_900, body: input() + String(repeating: "x", count: 17_000))
        try large.row(id: id, time: 1_792_199_950, body: exit())
        XCTAssertNil(CodexInternalTaskEvidence.read(sessionID: id, home: large.home.path, now: instant))
    }
}
