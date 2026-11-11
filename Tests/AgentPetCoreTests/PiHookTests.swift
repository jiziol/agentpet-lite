import XCTest
@testable import AgentPetCore

/// Integration tests for Pi (pi.dev). Pi has no Claude-style command hooks; it
/// loads a TypeScript extension from ~/.pi/agent/extensions/ that reports state
/// through stdin JSON to the `agentpet hook` CLI.
final class PiHookTests: XCTestCase {

    private func tmp(_ name: String) -> String {
        NSTemporaryDirectory() + "agentpet-test-\(UUID().uuidString)/\(name)"
    }

    func testPiSpec() {
        let spec = AgentHooks.spec(for: .pi)!
        XCTAssertEqual(spec.style, .piExtension)
        XCTAssertTrue(spec.settingsPath.hasSuffix("/.pi/agent/extensions/agentpet.ts"))
        // The extension hardcodes its own pi.on() handlers, so no events are
        // registered through the generic installer.
        XCTAssertTrue(spec.events.isEmpty)
    }

    func testPiExtensionContent() {
        let ts = HookInstaller.piExtension(binary: "/x/agentpet")
        XCTAssertTrue(ts.contains("observe(\"session_start\""))
        XCTAssertTrue(ts.contains("observe(\"agent_start\""))
        XCTAssertTrue(ts.contains("observe(\"agent_end\""))
        XCTAssertTrue(ts.contains("observe(\"agent_settled\""))
        XCTAssertTrue(ts.contains("observe(\"ui_prompt_start\""))
        XCTAssertTrue(ts.contains("observe(\"ui_prompt_end\""))
        XCTAssertTrue(ts.contains("--agent"))
        XCTAssertTrue(ts.contains("pi"))
        // Must look "ours" so isInstalled detection works.
        XCTAssertTrue(PiPlugin.isOwned(ts))
    }

    func testPiExtensionInstallRoundTrip() throws {
        let spec = AgentHooks.spec(for: .pi)!
        let path = tmp("agentpet.ts")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let cmd = "\"/x/agentpet\" hook --agent pi"
        try HookInstaller.installToDisk(command: cmd, path: path, events: spec.events, style: .piExtension)
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(source.contains("AGENTPET_BIN"))
        let prefix = "const AGENTPET_BIN = "
        let line = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.hasPrefix(prefix) })
        let binary = try JSONDecoder().decode(String.self, from: Data(line.dropFirst(prefix.count).utf8))
        XCTAssertEqual(binary, "/x/agentpet", "compare the decoded path, allowing JSON slash escaping")
        XCTAssertTrue(HookInstaller.isInstalledOnDisk(path: path, events: spec.events, style: .piExtension))
        try HookInstaller.uninstallFromDisk(path: path, events: spec.events, style: .piExtension)
        XCTAssertFalse(HookInstaller.isInstalledOnDisk(path: path, events: spec.events, style: .piExtension))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "extension file removed on uninstall")
    }

    func testPiNormalisedStatesSentByExtension() {
        // The extension sends normalised AgentState raw values directly.
        XCTAssertEqual(StateMapper.state(for: .pi, eventName: "registered"), .registered)
        XCTAssertEqual(StateMapper.state(for: .pi, eventName: "working"), .working)
        XCTAssertEqual(StateMapper.state(for: .pi, eventName: "done"), .done)
    }

    func testPiNativeEventNamesFallback() {
        XCTAssertEqual(StateMapper.state(for: .pi, eventName: "session_start"), .registered)
        XCTAssertEqual(StateMapper.state(for: .pi, eventName: "agent_start"), .working)
        XCTAssertNil(StateMapper.state(for: .pi, eventName: "agent_end"), "low-level end can precede automatic continuation")
        XCTAssertEqual(StateMapper.state(for: .pi, eventName: "agent_settled"), .done)
        XCTAssertEqual(StateMapper.state(for: .pi, eventName: "session_shutdown"), .done)
        XCTAssertTrue(StateMapper.isSessionEnd(for: .pi, eventName: "session_shutdown"))
        XCTAssertEqual(StateMapper.state(for: .pi, eventName: "ui_prompt_start"), .waiting)
        // UI dialogs come from the aggregate native prompt events.
        XCTAssertNil(StateMapper.state(for: .pi, eventName: "extension_ui_request"))
    }

    func testPiEventViaExplicitFlags() {
        // Legacy explicit flags remain supported for the run wrapper.
        let args = HookArguments.parse(["--agent", "pi", "--event", "working", "--session", "pi:/proj", "--project", "/proj"])
        let event = args.makeEvent(now: Date())
        XCTAssertEqual(event?.agentKind, .pi)
        XCTAssertEqual(event?.eventName, "working")
        XCTAssertEqual(event?.project, "/proj")
    }

    func testPiInCatalog() {
        let pi = AgentCatalog.all.first { $0.kind == .pi }
        XCTAssertNotNil(pi)
        XCTAssertTrue(pi?.isSupported ?? false)
        XCTAssertEqual(pi?.displayName, "Pi")
    }

    func testPreviousTemplatesRemainOwnedButModifiedFilesArePreserved() {
        for binary in ["/x/agentpet", "/app's $literal `safe`/agentpet"] {
            for source in [PiPlugin.source(binary: binary), PiPlugin.previousSettledSource(binary: binary), PiPlugin.previousSource(binary: binary), PiPlugin.legacySource(binary: binary)] {
                XCTAssertTrue(PiPlugin.isOwned(source))
                XCTAssertFalse(PiPlugin.isOwned(source + "\n// user's customization"))
            }
        }
    }

    func testOnlyExplicitSettledResultProvesSuccessAndSurvivesSerialization() throws {
        let at = Date(timeIntervalSince1970: 100)
        for (name, result) in [("done", "completed"), ("done", ""), ("done", "invalid"), ("agent_settled", "completed")] {
            let data = try JSONSerialization.data(withJSONObject: ["session_id": "pi:result",
                "hook_event_name": name, "turn_result": result])
            let event = try XCTUnwrap(HookPayload.event(forAgent: .pi, stdin: data, now: at))
            let reducer = SessionReducer()
            let done = try XCTUnwrap(reducer.apply(event, now: at))
            let expected: CodexTurnResult? = name == "done" && result == "completed" ? .completed : nil
            XCTAssertEqual(done.taskResult, expected)
            let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(done))
            XCTAssertEqual(restored.taskResult, expected)
            var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(done)) as? [String: Any])
            old.removeValue(forKey: "piTurnResult")
            let legacy = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: old))
            XCTAssertNil(legacy.taskResult, "Old snapshots cannot prove success")
        }
    }

    func testLowLevelEndCannotFinishActiveSessionAndShutdownRemovesIt() {
        let reducer = SessionReducer()
        let start = Date(timeIntervalSince1970: 100)
        func event(_ name: String, _ offset: Double) -> AgentEvent {
            AgentEvent(sessionId: "pi:fixture", agentKind: .pi, eventName: name, timestamp: start.addingTimeInterval(offset))
        }
        _ = reducer.apply(event("working", 0), now: start)
        XCTAssertNil(reducer.apply(event("agent_end", 1), now: start.addingTimeInterval(1)))
        XCTAssertEqual(reducer.sessions.first?.state, .working)
        _ = reducer.apply(event("agent_settled", 2), now: start.addingTimeInterval(2))
        XCTAssertEqual(reducer.sessions.first?.state, .done)
        _ = reducer.apply(event("session_shutdown", 3), now: start.addingTimeInterval(3))
        XCTAssertTrue(reducer.sessions.isEmpty)
    }
}
