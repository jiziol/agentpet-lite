import XCTest
@testable import AgentPetCore

final class CodexReviewModeTests: XCTestCase {
    private let sid = "review-session"
    private func date(_ n: Double) -> Date { Date(timeIntervalSince1970: n) }
    private func record(_ type: String, _ n: Double, _ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": n, "payload": payload])
    }
    private func context(_ id: String, _ n: Double, _ reviewer: String?, policy: String? = nil) throws -> Data {
        var payload: [String: Any] = ["turn_id": id]
        if let reviewer { payload["approvals_reviewer"] = reviewer }
        if let policy { payload["approval_policy"] = policy }
        return try record("turn_context", n, payload)
    }
    private func settings(_ n: Double, _ reviewer: String, session: String = "review-session", policy: String? = nil) throws -> Data {
        var native: [String: Any] = ["approvals_reviewer": reviewer]
        if let policy { native["approval_policy"] = policy }
        return try record("event_msg", n, ["type": "thread_settings_applied", "thread_id": session, "thread_settings": native])
    }
    private func mode(_ lines: [Data], turn: String = "turn", at n: Double = 10) -> CodexReviewMode? {
        CodexReviewMode.parse(lines, sessionID: sid, turnID: turn, at: date(n))
    }

    func testExplicitAutomaticReviewerIsWork() throws {
        XCTAssertEqual(mode([try context("turn", 1, "auto_review")]), .automatic)
        XCTAssertEqual(mode([try context("turn", 1, "user")]), .user)
    }
    func testUnknownReviewerNeverAssumesAutomatic() throws {
        XCTAssertNil(mode([try context("turn", 1, nil)]))
        XCTAssertNil(mode([try context("turn", 1, "future-reviewer")]))
        XCTAssertNil(mode([]))
    }
    func testSettingsSwitchIsEvaluatedAtHookTimestamp() throws {
        let lines = [try context("turn", 1, "auto_review"), try settings(5, "user")]
        XCTAssertEqual(mode(lines, at: 4), .automatic)
        XCTAssertEqual(mode(lines, at: 6), .user)
    }
    func testOlderSettingsCannotOverrideNewerTurnContext() throws {
        XCTAssertEqual(mode([try settings(1, "auto_review"), try context("turn", 2, "user")]), .user)
    }
    func testForeignThreadSettingsCannotChangeMode() throws {
        XCTAssertEqual(mode([try context("turn", 1, "user"), try settings(2, "auto_review", session: "other")]), .user)
    }
    func testExactTurnIdentityAndNewestTurnBoundaryAreRequired() throws {
        let first = try context("turn", 1, "auto_review")
        XCTAssertNil(mode([first], turn: "other"))
        XCTAssertNil(mode([first, try context("other", 2, "auto_review")]))
        XCTAssertNil(mode([first, try record("event_msg", 2, ["type": "task_started", "turn_id": "other"])]))
    }
    func testOutOfOrderMetadataUsesNativeDates() throws {
        XCTAssertEqual(mode([try settings(5, "user"), try context("turn", 2, "auto_review"), try settings(3, "auto_review")]), .user)
    }
    func testFutureRecordsAndConversationBodiesAreNotEvidence() throws {
        let message = try record("response_item", 2, ["type": "message", "role": "assistant",
            "content": [["text": "thread_settings_applied auto_review turn_context"]]])
        XCTAssertEqual(mode([try context("turn", 1, "user"), message, try context("turn", 20, "auto_review")]), .user)
    }
    func testReadRejectsPartialFinalRecordAndOversizedInput() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("rollout.jsonl")
        let complete = try context("turn", 1, "user")
        var bytes = complete; bytes.append(10); bytes.append(try settings(2, "auto_review"))
        try bytes.write(to: file)
        XCTAssertEqual(CodexReviewMode.read(path: file.path, sessionID: sid, turnID: "turn", at: date(10)), .user)
        XCTAssertNil(mode([Data(repeating: 0x41, count: 16_777_217)]))
        XCTAssertNil(CodexReviewMode.read(path: folder.appendingPathComponent("missing").path, sessionID: sid, turnID: "turn", at: date(10)))
    }

    private func permission(_ n: Double = 2) -> AgentEvent {
        var event = AgentEvent(sessionId: sid, agentKind: .codex, eventName: "waiting", message: "等待批准", timestamp: date(n))
        event.codexPermissionTurnID = "turn"
        return event
    }
    func testOnlyNativePermissionRequestCarriesReviewMarker() throws {
        let raw: [String: Any] = ["session_id": sid, "hook_event_name": "PermissionRequest", "turn_id": "turn", "tool_name": "exec_command", "tool_input": [:]]
        let observed = HookPayload.event(forAgent: .codex, stdin: try JSONSerialization.data(withJSONObject: raw), now: date(2))!
        XCTAssertEqual(observed.codexPermissionTurnID, "turn")
        XCTAssertEqual(observed.eventName, "waiting")
        XCTAssertNil(observed.humanIntervention)
        var pre = raw; pre["hook_event_name"] = "PreToolUse"
        XCTAssertNil(HookPayload.event(forAgent: .codex, stdin: try JSONSerialization.data(withJSONObject: pre), now: date(2))?.codexPermissionTurnID)
    }
    func testAutomaticReviewIsBlueWithoutFakingReadReceiptOrRecursiveMarker() {
        let store = SessionStore()
        store.apply(AgentEvent(sessionId: sid, agentKind: .codex, eventName: "UserPromptSubmit", timestamp: date(1)), now: date(1))
        let reviewed = CodexReviewMode.reviewedPermission(permission(), mode: .automatic)
        XCTAssertNil(reviewed.codexPermissionTurnID)
        XCTAssertEqual(reviewed.eventName, "working")
        store.apply(reviewed, now: date(2))
        let working = store.session(id: sid)!
        XCTAssertEqual(working.state, .working)
        XCTAssertEqual(working.indicator, .running)
        XCTAssertEqual(working.turnStartedAt, date(1))
        XCTAssertNil(working.readAt)
        XCTAssertEqual(working.notificationVersion, 0)
        XCTAssertEqual(CodexReviewMode.reviewedPermission(reviewed, mode: .user), reviewed)
    }
    func testManualOrUnknownReviewerKeepsOrange() {
        for mode: CodexReviewMode? in [.user, nil] {
            let reviewed = CodexReviewMode.reviewedPermission(permission(), mode: mode)
            XCTAssertNil(reviewed.codexPermissionTurnID)
            XCTAssertEqual(reviewed.eventName, "waiting")
            let store = SessionStore(); store.apply(reviewed, now: date(2))
            XCTAssertEqual(store.session(id: sid)?.indicator, .attention)
        }
    }
    func testLateMetadataResultCannotOverrideNewerWorkTurnOrCompletion() {
        for name in ["PreToolUse", "UserPromptSubmit", "Stop"] {
            let store = SessionStore()
            store.apply(AgentEvent(sessionId: sid, agentKind: .codex, eventName: "UserPromptSubmit", timestamp: date(1)), now: date(1))
            store.apply(AgentEvent(sessionId: sid, agentKind: .codex, eventName: name, timestamp: date(3)), now: date(3))
            let newer = store.session(id: sid)
            let reviewed = CodexReviewMode.reviewedPermission(permission(), mode: .automatic)
            XCTAssertNil(store.apply(reviewed, now: date(4)))
            XCTAssertEqual(store.session(id: sid), newer)
            let manual = CodexReviewMode.reviewedPermission(permission(), mode: .user)
            XCTAssertNil(store.apply(manual, now: date(4)))
            XCTAssertEqual(store.session(id: sid), newer)
        }
    }
    func testActualChoiceReplyAndPermissionCardsAreNotConverted() {
        for kind: HumanRequest.Kind in [.choice, .reply, .permission] {
            var event = permission()
            event.humanIntervention = HumanIntervention(action: .asked,
                requests: [HumanRequest(id: "actual-card", kind: kind, createdAt: date(2))])
            let reviewed = CodexReviewMode.reviewedPermission(event, mode: .automatic)
            XCTAssertEqual(reviewed.eventName, "waiting")
            XCTAssertEqual(reviewed.humanIntervention, event.humanIntervention)
            XCTAssertNil(reviewed.codexPermissionTurnID)
            let store = SessionStore(); store.apply(reviewed, now: date(2))
            XCTAssertEqual(store.session(id: sid)?.humanRequests?.count, 1)
            XCTAssertEqual(store.session(id: sid)?.state, .waiting)
        }
        var gated = permission(); gated.approvalRequestId = "user-approval"
        XCTAssertEqual(CodexReviewMode.reviewedPermission(gated, mode: .automatic).eventName, "waiting")
    }
    func testOrdinaryToolsAndOtherAgentsCannotBeClassifiedAsAutomaticReview() {
        let ordinary = AgentEvent(sessionId: sid, agentKind: .codex, eventName: "PreToolUse", timestamp: date(2))
        XCTAssertEqual(CodexReviewMode.reviewedPermission(ordinary, mode: .automatic), ordinary)
        var foreign = permission(); foreign.agentKind = .antigravity
        XCTAssertEqual(CodexReviewMode.reviewedPermission(foreign, mode: .automatic), foreign)
    }
    func testNeverPolicyRequiresNoHumanApprovalRegardlessOfReviewerLabel() throws {
        for reviewer: String? in ["user", "auto_review", "future-reviewer", nil] {
            XCTAssertEqual(mode([try context("turn", 1, reviewer, policy: "never")]), .nonInteractive)
        }
    }
    func testNeverPolicyChangesRespectThePermissionHookTime() throws {
        let stoppedAsking = [try context("turn", 1, "user", policy: "on-request"), try settings(5, "user", policy: "never")]
        XCTAssertEqual(mode(stoppedAsking, at: 4), .user)
        XCTAssertEqual(mode(stoppedAsking, at: 6), .nonInteractive)
        let resumedAsking = [try context("turn", 1, "user", policy: "never"), try settings(5, "user", policy: "on-request")]
        XCTAssertEqual(mode(resumedAsking, at: 4), .nonInteractive)
        XCTAssertEqual(mode(resumedAsking, at: 6), .user)
    }
    func testNeverPolicyCannotCrossThreadTurnOrContextBoundary() throws {
        XCTAssertEqual(mode([try settings(1, "user", policy: "never"), try context("turn", 2, "user", policy: "on-request")]), .user)
        XCTAssertEqual(mode([try context("turn", 1, "user", policy: "on-request"), try settings(2, "user", session: "foreign", policy: "never")]), .user)
        XCTAssertNil(mode([try context("foreign", 1, "user", policy: "never")]))
    }
    func testUnknownPolicyOrReviewerDoesNotInventNoninteractivePermission() throws {
        XCTAssertEqual(mode([try context("turn", 1, "user", policy: "unknown-policy")]), .user)
        XCTAssertNil(mode([try context("turn", 1, "non_interactive")]))
        XCTAssertNil(mode([try context("turn", 1, "never")]))
        XCTAssertNil(mode([try context("turn", 1, nil, policy: "unknown-policy")]))
    }
    func testNoninteractivePermissionRemainsBlueAndIdentifiedCardsStillWait() {
        let bare = CodexReviewMode.reviewedPermission(permission(), mode: .nonInteractive)
        XCTAssertEqual(bare.eventName, "working")
        XCTAssertNil(bare.codexPermissionTurnID)
        XCTAssertEqual(bare.timestamp, date(2))
        for kind: HumanRequest.Kind in [.choice, .reply, .permission] {
            var identified = permission()
            identified.humanIntervention = HumanIntervention(action: .asked,
                requests: [HumanRequest(id: "genuine-card", kind: kind, createdAt: date(2))])
            let reviewed = CodexReviewMode.reviewedPermission(identified, mode: .nonInteractive)
            XCTAssertEqual(reviewed.eventName, "waiting")
            XCTAssertEqual(reviewed.humanIntervention, identified.humanIntervention)
        }
        var gated = permission(); gated.approvalRequestId = "genuine-approval"
        XCTAssertEqual(CodexReviewMode.reviewedPermission(gated, mode: .nonInteractive).eventName, "waiting")
    }
    func testNoninteractiveWorkDoesNotClearExistingOutstandingQuestion() {
        let store = SessionStore()
        var question = AgentEvent(sessionId: sid, agentKind: .codex, eventName: "HumanInput", timestamp: date(1))
        question.humanIntervention = HumanIntervention(action: .asked,
            requests: [HumanRequest(id: "genuine-choice", kind: .choice, createdAt: date(1))])
        store.apply(question, now: date(1))
        store.apply(CodexReviewMode.reviewedPermission(permission(), mode: .nonInteractive), now: date(2))
        XCTAssertEqual(store.session(id: sid)?.indicator, .attention)
        XCTAssertEqual(store.session(id: sid)?.message, "等待你的选择")
        XCTAssertEqual(store.session(id: sid)?.humanRequests?.map(\.id), ["genuine-choice"])
    }

}
