import XCTest
@testable import AgentPetCore

final class CodexVisibleMessageTests: XCTestCase {
    private func record(role: String = "assistant", phase: String? = "commentary", type: String = "message",
                        text: String = "Checking the window", contentType: String = "output_text") throws -> Data {
        var payload: [String: Any] = ["type": type, "role": role, "content": [["type": contentType, "text": text]]]
        if let phase { payload["phase"] = phase }
        return try JSONSerialization.data(withJSONObject: ["type": "response_item", "timestamp": "2026-10-08T07:00:00Z", "payload": payload])
    }
    func testOnlyExplicitVisibleAssistantPhasesAreAccepted() throws {
        for phase in ["commentary", "final_answer"] {
            let value = try XCTUnwrap(CodexVisibleMessage.parse(record(phase: phase), turnID: "t"))
            XCTAssertEqual(value.text, "Checking the window")
            XCTAssertEqual(value.turnID, "t")
        }
        for role in ["user", "system", "developer", "tool"] {
            XCTAssertNil(CodexVisibleMessage.parse(try record(role: role), turnID: "t"))
        }
        XCTAssertNil(CodexVisibleMessage.parse(try record(phase: nil), turnID: "t"))
        XCTAssertNil(CodexVisibleMessage.parse(try record(phase: "analysis"), turnID: "t"))
        XCTAssertNil(CodexVisibleMessage.parse(try record(type: "reasoning"), turnID: "t"))
        XCTAssertNil(CodexVisibleMessage.parse(try record(contentType: "reasoning_text"), turnID: "t"))
        XCTAssertNil(CodexVisibleMessage.parse(try record(), turnID: nil))
    }
    func testLimitsAndControls() throws {
        let value = try XCTUnwrap(CodexVisibleMessage.parse(record(text: "One\n\u{0000} two\tthree"), turnID: "t"))
        XCTAssertEqual(value.text, "One two three")
        let long = try XCTUnwrap(CodexVisibleMessage.parse(record(text: String(repeating: "鲸", count: 1000)), turnID: "t"))
        XCTAssertEqual(long.text.count, 161)
        XCTAssertTrue(long.text.hasSuffix("…"))
        XCTAssertNil(CodexVisibleMessage.parse(Data(repeating: 32, count: 1_048_577), turnID: "t"))
    }

    func testWatcherDoesNotReplayAttachmentAndDeliversNewCompleteRecord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout.jsonl")
        let start = Data("{\"type\":\"event_msg\",\"timestamp\":\"2026-10-08T07:00:00Z\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"t\"}}\n".utf8)
        var initial = start; initial.append(try record(text: "old")); initial.append(10)
        try initial.write(to: file)
        let attached = expectation(description: "attached")
        let received = expectation(description: "new message")
        let watcher = CodexLifecycleWatcher(messageHandler: { id, value in
            XCTAssertEqual(id, "s"); XCTAssertEqual(value.text, "new"); received.fulfill()
        }, handler: { _, _ in attached.fulfill() })
        watcher.setMessagesEnabled(true)
        watcher.watch(sessionID: "s", path: file.path)
        wait(for: [attached], timeout: 3)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close(); watcher.retain(sessionIDs: []) }
        try handle.seekToEnd(); try handle.write(contentsOf: record(text: "new")); try handle.write(contentsOf: Data([10]))
        wait(for: [received], timeout: 3)
    }
}
