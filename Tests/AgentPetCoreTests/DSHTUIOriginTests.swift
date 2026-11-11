import XCTest
@testable import AgentPetCore

final class DSHTUIOriginTests: XCTestCase {
    private func package(_ root: URL) -> String? {
        switch root.path {
        case "/fixture/tui": return "@deepseek-harness-tui/dsh-tui"
        case "/fixture/dsh": return "@deepseek-ai/dsh"
        default: return nil
        }
    }

    func testOnlyVerifiedPackageEntryScriptsIdentifyTUI() {
        for script in ["/fixture/tui/bin/dsh-tui.js", "/fixture/tui/lib/types/dsh-adapter/host-entry.js"] {
            XCTAssertTrue(DSHTUIOrigin.isTUICommand(["node", script], packageName: package))
        }
        for script in ["/fixture/tui/tools/example.js", "/fixture/unrelated/bin/dsh-tui.js", "./dsh-tui.js"] {
            XCTAssertFalse(DSHTUIOrigin.isTUICommand(["node", script], packageName: package))
        }
        XCTAssertFalse(DSHTUIOrigin.isTUICommand(["node", "/fixture/tui/bin/dsh-tui.js"], packageName: { _ in "unrelated-package" }))
    }

    func testNativeCLIFallbackRequiresItsExactProfileBeforeAppArguments() {
        let command = ["node", "/fixture/dsh/lib/bin.js"]
        XCTAssertTrue(DSHTUIOrigin.isTUICommand(command + ["--profile", "dsh-tui"], packageName: package))
        XCTAssertTrue(DSHTUIOrigin.isTUICommand(command + ["--profile=dsh-tui", "--", "prompt"], packageName: package))
        for args in [["--profile", "desktop"], ["--", "--profile=dsh-tui"],
                     ["plugin", "--profile", "dsh-tui"], ["--config", "x", "--profile=dsh-tui"],
                     ["--patch", "--profile=dsh-tui"], ["--profile=dsh-tui", "--profile=desktop"]] {
            XCTAssertFalse(DSHTUIOrigin.isTUICommand(command + args, packageName: package), "\(args)")
        }
    }

    func testNodeOptionsAndPromptLookalikesDoNotCreateOwnership() {
        let script = "/fixture/tui/bin/dsh-tui.js"
        XCTAssertTrue(DSHTUIOrigin.isTUICommand(["node", "--import", "/fixture/loader.js", script], packageName: package))
        for arguments in [["node", "-e", "run()", script], ["node", "--eval=run()", script],
                          ["node", "--print=run()", script], ["node", "/fixture/work.js", script]] {
            XCTAssertFalse(DSHTUIOrigin.isTUICommand(arguments, packageName: package))
        }
    }

    func testInstalledEntryIdentityUsesPackageMetadataAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data(#"{"name":"@deepseek-harness-tui/dsh-tui"}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        let script = root.appendingPathComponent("bin/dsh-tui.js")
        try Data().write(to: script)
        let link = root.appendingPathComponent("dst")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
        XCTAssertTrue(DSHTUIOrigin.isTUICommand(["node", link.path]))
        try Data(#"{"name":"other-package"}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        XCTAssertFalse(DSHTUIOrigin.isTUICommand(["node", link.path]))
    }

    func testSourceSurvivesLifecycleAndSerializationWithoutChangingTrackingOrReceipts() throws {
        let store = SessionStore()
        let start = Date(timeIntervalSince1970: 10000)
        var event = AgentEvent(sessionId: "tui-codex", agentKind: .codex, eventName: "UserPromptSubmit", timestamp: start)
        event.dshTUI = true
        let original = try XCTUnwrap(store.apply(event, now: start))
        XCTAssertTrue(original.isDSHTUI)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sorted.count, 1, "The source filter must not stop tracking")
        var end = AgentEvent(sessionId: event.sessionId, agentKind: .codex, eventName: "Stop", timestamp: start.addingTimeInterval(1))
        end.turnResult = .completed
        let finished = try XCTUnwrap(store.apply(end, now: end.timestamp))
        XCTAssertTrue(finished.isDSHTUI)
        XCTAssertEqual(finished.state, .done)
        XCTAssertEqual(finished.readThroughVersion, original.readThroughVersion)
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(finished))
        XCTAssertEqual(restored, finished)
        XCTAssertTrue(restored.isDSHTUI)
    }

    func testIndependentResumeClearsSourceButUnknownOrLateHooksCannot() throws {
        let store = SessionStore()
        let start = Date(timeIntervalSince1970: 10000)
        var event = AgentEvent(sessionId: "tui-agy", agentKind: .antigravity, eventName: "working", timestamp: start)
        event.antigravityNewInvocation = true; event.dshTUI = true
        store.apply(event, now: start)
        var tool = event; tool.timestamp = start.addingTimeInterval(1)
        tool.antigravityNewInvocation = false; tool.dshTUI = false
        XCTAssertTrue(try XCTUnwrap(store.apply(tool, now: tool.timestamp)).isDSHTUI)
        var resumed = event; resumed.timestamp = start.addingTimeInterval(2); resumed.dshTUI = false
        XCTAssertFalse(try XCTUnwrap(store.apply(resumed, now: resumed.timestamp)).isDSHTUI)
        store.apply(event, now: start.addingTimeInterval(3))
        XCTAssertFalse(try XCTUnwrap(store.session(id: event.sessionId)).isDSHTUI)
    }

    func testLegacySessionWithoutSourceMarkerRemainsOrdinary() throws {
        let session = AgentSession(id: "legacy", agentKind: .antigravity, state: .working, source: .hook, updatedAt: Date())
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertNil(restored.dshTUI)
        XCTAssertFalse(restored.isDSHTUI)
    }
}
