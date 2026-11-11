import XCTest
import Foundation
@testable import AgentPetCore

final class AntigravityCompletedTranscriptTests: XCTestCase {
    private func session(_ at: Date, id: String = UUID().uuidString.lowercased()) -> AgentSession {
        var s = AgentSession(id: id, agentKind: .antigravity,
                             state: .working, source: .hook, updatedAt: at)
        s.turnStartedAt = at; s.antigravityEventAt = at; s.antigravityStepFloor = 10
        return s
    }
    private func row(_ at: Date, index: Int = 11, type: String = "PLANNER_RESPONSE",
                     status: String = "DONE", source: String = "MODEL", text: String = "公开完成正文") -> [String: Any] {
        ["step_index": index, "type": type, "status": status, "source": source,
         "created_at": ISO8601DateFormatter().string(from: at), "content": text]
    }
    private func withTranscript(_ body: (String, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("transcript.jsonl").path, directory.path)
    }
    private func write(_ rows: [[String: Any]], to path: String) throws {
        var data = Data()
        for row in rows { data += try JSONSerialization.data(withJSONObject: row); data.append(10) }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    func testOnlyExactCompletedPublicTurnCanReadStopExport() throws {
        try withTranscript { path, _ in
            let at = Date(); var s = session(at)
            try write([row(at, index: 9), row(at, type: "GENERIC"), row(at, status: "RUNNING"),
                       row(at, source: "USER_EXPLICIT"), row(at, text: ""), row(at)], to: path)
            XCTAssertNil(AntigravityCompletedTranscript.read(path: path, boundary: .init(session: s, enabledAt: at)!))
            s.state = .done; s.antigravityTurnResult = .completed
            s.turnEndedAt = Date(); s.antigravityEventAt = s.turnEndedAt
            let boundary = try XCTUnwrap(AntigravityVisibleMessage.Boundary(session: s, enabledAt: at))
            let step = try XCTUnwrap(AntigravityCompletedTranscript.read(path: path, boundary: boundary))
            XCTAssertEqual(step.text, "公开完成正文"); XCTAssertEqual(step.index, 11)
            XCTAssertEqual(step.completedAt, s.turnEndedAt)
            var changed = s; changed.antigravityTurnResult = .cancelled
            XCTAssertNil(AntigravityVisibleMessage.Boundary(session: changed, enabledAt: at))
            changed = s; changed.turnEndedAt = Date().addingTimeInterval(1)
            XCTAssertFalse(boundary.matches(changed))
            changed = s; changed.aionUiConversation = .init(id: "host", nativeSessionID: s.id, agentKind: .antigravity)
            XCTAssertNil(AntigravityCompletedTranscript.read(path: path, boundary: .init(session: changed, enabledAt: at)!))
        }
    }
    func testPriorTurnToolPrivateAndStaleExportCannotBecomePublicReply() throws {
        try withTranscript { path, _ in
            let at = Date(); var s = session(at)
            s.state = .done; s.antigravityTurnResult = .completed; s.turnEndedAt = Date()
            let b = try XCTUnwrap(AntigravityVisibleMessage.Boundary(session: s, enabledAt: at))
            var privateRow = row(at, text: ""); privateRow["thinking"] = "PRIVATE"
            try write([row(at.addingTimeInterval(-5)), row(at,index: 9), row(at,type: "GENERIC"),privateRow],to:path)
            XCTAssertNil(AntigravityCompletedTranscript.read(path:path,boundary:b))
            try write([row(at)],to:path)
            try FileManager.default.setAttributes([.modificationDate: at.addingTimeInterval(-5)],ofItemAtPath:path)
            XCTAssertNil(AntigravityCompletedTranscript.read(path:path,boundary:b))
            try Data(repeating: 120,count:600_000).write(to:URL(fileURLWithPath:path))
            XCTAssertNil(AntigravityCompletedTranscript.read(path:path,boundary:b))
        }
    }
    func testThinkingFieldIsSkippedWithoutBecomingPublicContent() throws {
        let data = Data(#"{"type":"PLANNER_RESPONSE","content":"公开正文\n","thinking":{"nested":["PRIVATE",{"raw":"PRIVATE_RAW"}]},"raw_thinking":"PRIVATE"}"#.utf8)
        let fields = try XCTUnwrap(AntigravityCompletedTranscript.publicFields(data))
        XCTAssertEqual(fields["content"] as? String,"公开正文\n")
        XCTAssertNil(fields["thinking"]); XCTAssertNil(fields["raw_thinking"])
        XCTAssertNil(AntigravityCompletedTranscript.publicFields(Data(#"{"content":"a","content":"b"}"#.utf8)))
    }
    func testStopExportReachesWatcherBeforeDatabaseExistsAndCannotReplayOnRestart() throws {
        try withTranscript { _, directory in
            let at = Date(); var s = session(at)
            let db = directory + "/conversations/\(s.id).db"
            try FileManager.default.createDirectory(atPath:(db as NSString).deletingLastPathComponent,withIntermediateDirectories:true)
            let path = try XCTUnwrap(AntigravityCompletedTranscript.path(database:db,sessionID:s.id))
            try FileManager.default.createDirectory(atPath:(path as NSString).deletingLastPathComponent,withIntermediateDirectories:true)
            try write([row(at.addingTimeInterval(-5),index:9)],to:path)
            let ready = DispatchSemaphore(value:0)
            let watcher = AntigravitySpeechWatcher(database: directory + "/no-host.db") { _, message in
                XCTAssertEqual(message.text,"公开完成正文"); XCTAssertEqual(message.stepIndex,11); ready.signal()
            }
            watcher.watch(path:db,boundary:.init(session:s,enabledAt:at)!)
            XCTAssertEqual(ready.wait(timeout:.now()+0.15),.timedOut)
            try write([row(at)],to:path)
            s.state = .done; s.antigravityTurnResult = .completed
            s.turnEndedAt = Date(); s.antigravityEventAt = s.turnEndedAt
            watcher.watch(path:db,boundary:.init(session:s,enabledAt:at)!)
            XCTAssertEqual(ready.wait(timeout:.now()+1),.success)
            watcher.watch(path:db,boundary:.init(session:s,enabledAt:at)!)
            XCTAssertEqual(ready.wait(timeout:.now()+0.2),.timedOut)
            watcher.retain(sessionIDs:[])
            let restarted = AntigravitySpeechWatcher(database:directory + "/no-host.db") { _, _ in ready.signal() }
            restarted.watch(path:db,boundary:.init(session:s,enabledAt:Date())!)
            XCTAssertEqual(ready.wait(timeout:.now()+0.3),.timedOut)
            restarted.retain(sessionIDs:[])
        }
    }
    // Private historical audit; run via scripts/audit-agy-records.sh.
    // Routine regression above uses synthetic fixtures and remains unconditional.
    #if AGENTPET_NATIVE_RECORD_AUDITS
    func testInstalledTerminalStopExportEqualsNativePublicReplyWhenOptedIn() throws {
        let file = try XCTUnwrap(ProcessInfo.processInfo.environment["AGENTPET_AGY_TERMINAL_RECORD"],
                                 "Use scripts/audit-agy-records.sh terminal RECORD_JSON")
        let r = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as? [String:Any])
        let start = Date(timeIntervalSinceReferenceDate:try XCTUnwrap(r["turnStartedAt"] as? Double))
        var s = session(start, id: try XCTUnwrap(r["id"] as? String))
        s.antigravityStepFloor = try XCTUnwrap(r["antigravityStepFloor"] as? Int)
        s.state = .done; s.antigravityTurnResult = .completed
        s.turnEndedAt = Date(timeIntervalSinceReferenceDate:try XCTUnwrap(r["turnEndedAt"] as? Double))
        s.antigravityEventAt = s.turnEndedAt
        let b = try XCTUnwrap(AntigravityVisibleMessage.Boundary(session:s,enabledAt:start))
        let db = try XCTUnwrap(AntigravityHumanInput.databasePath(sessionID:s.id))
        let path = try XCTUnwrap(AntigravityCompletedTranscript.path(database:db,sessionID:s.id))
        let transcript = try XCTUnwrap(AntigravityCompletedTranscript.read(path:path,boundary:b))
        let native = try XCTUnwrap(AntigravityPublicResponse.read(path:db,boundary:b)?.step)
        XCTAssertEqual(transcript.index,native.index)
        XCTAssertEqual(transcript.text.trimmingCharacters(in:.whitespacesAndNewlines),native.text.trimmingCharacters(in:.whitespacesAndNewlines))
        let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath:path)[.modificationDate] as? Date)
        print("TERMINAL_PUBLIC_EXPORT exact_match=true chars=\(transcript.text.count) export_before_hook_ms=\(s.turnEndedAt!.timeIntervalSince(mtime)*1000) historical_only=true")
    }
    #endif
}
