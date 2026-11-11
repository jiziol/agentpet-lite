import XCTest
@testable import AgentPetCore

final class AOBackgroundTaskTests: XCTestCase {
    private var root: String { NSHomeDirectory() + "/.ao/data/background-tasks/" }

    func testReservedWorkspaceRequiresExactCanonicalParentAndNumericSuffix() {
        XCTAssertTrue(CodexHookOrigin.isAOBackgroundWorkspace(root + "title-1196212565"))
        for project in [root + "title-", root + "title-123-extra", root + "title-１２３",
                        root + "title-123/child", root + "other-123", root + "../title-123",
                        root + "title-123/", "/synthetic/project/title-123"] {
            XCTAssertFalse(CodexHookOrigin.isAOBackgroundWorkspace(project), project)
        }
    }

    func testPersistedWorkingAndCompletedHelpersAreFilteredWithoutChangingLifecycleOrReceipts() throws {
        for kind: AgentKind in [.codex, .opencode, .pi] {
            for state: AgentState in [.working, .done] {
                var value = AgentSession(id: "synthetic-helper", agentKind: kind,
                    project: root + "title-123", title: "Synthetic helper", state: state,
                    source: .hook, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
                value.codexHasNativeThreadRecord = true
                value.notificationVersion = 4
                value.readThroughVersion = 2
                let encoded = try JSONEncoder().encode(value)
                let restored = try JSONDecoder().decode(AgentSession.self, from: encoded)
                XCTAssertTrue(restored.isAOBackgroundTask)
                XCTAssertTrue(restored.isCodexInternalTask)
                XCTAssertEqual(restored, value)
                XCTAssertEqual(restored.state, state)
                XCTAssertEqual(restored.readThroughVersion, 2)
                XCTAssertTrue(SessionNotificationPolicy.effects(before: nil, session: restored).isEmpty)
            }
        }
    }

    func testInteractiveRoutesAndOrdinarySameTitleTasksRemainVisible() {
        let helper = AgentSession(id: "synthetic-helper", agentKind: .codex,
            project: root + "title-123", title: "Suggest the single most useful next message...",
            state: .working, source: .hook, updatedAt: Date())
        var ordinary = helper; ordinary.project = "/synthetic/user-project"
        XCTAssertFalse(ordinary.isCodexInternalTask)
        for change: (inout AgentSession) -> Void in [
            { $0.codexDesktop = true }, { $0.terminalProgram = "Terminal" },
            { $0.terminalTTY = "/dev/ttys001" }, { $0.terminalFocusURL = "synthetic://terminal" },
            { $0.opencodeNavigationSocket = "/tmp/synthetic-nav.sock" },
            { $0.pendingApproval = .init(requestId: "approval", toolName: "synthetic", summary: "synthetic") },
            { $0.humanRequests = [.init(id: "question", kind: .choice, createdAt: Date())] }
        ] {
            var routed = helper; change(&routed)
            XCTAssertFalse(routed.isCodexInternalTask)
        }
    }

    func testDSHACPHostSocketDoesNotTurnReservedHelpersIntoInteractiveTasks() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        for state: AgentState in [.working, .done] {
            let observation = DSHObservation(schema: 1, profileID: String(repeating: "a", count: 24),
                hostID: "11111111-1111-4111-8111-111111111111", hostStartedAt: at.addingTimeInterval(-10),
                nativeSessionID: "22222222-2222-4222-8222-222222222222", revision: 2, nativeSeq: 3,
                turn: 1, phase: state == .working ? .working : .done, result: state == .working ? nil : .completed,
                pending: [], startedAt: at.addingTimeInterval(-1), endedAt: state == .working ? nil : at,
                baseline: false, heartbeat: false, gap: false, navigationSocket: "/tmp/agentpet-dsh-502/h-ACP123/nav.sock")
            var helper = AgentSession(id: observation.sessionKey, agentKind: .dsh, project: root + "title-123",
                state: state, source: .hook, updatedAt: at)
            helper.dsh = observation; helper.notificationVersion = 1
            let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(helper))
            XCTAssertTrue(restored.isAOBackgroundTask, "a host-wide socket does not prove a desktop Client or formal AO session")
            XCTAssertTrue(restored.isCodexInternalTask)
            XCTAssertTrue(SessionNotificationPolicy.effects(before: .working, session: restored).isEmpty)
            XCTAssertEqual(restored, helper, "classification must not rewrite lifecycle or read state")
            var ordinary = restored; ordinary.project = "/synthetic/standalone-workspace"
            XCTAssertFalse(ordinary.isAOBackgroundTask)
            var bound = restored
            bound.aoBinding = .init(sessionID: "standalone-1", projectID: AOHostMapping.standaloneProjectID,
                agentKind: .dsh, origin: .nativeIdentity, boundAt: at)
            XCTAssertFalse(bound.isAOBackgroundTask, "explicit AO ownership wins over scratch-source classification")
            var waiting = restored; waiting.humanRequests = [.init(id: "question", kind: .reply, createdAt: at)]
            XCTAssertFalse(waiting.isAOBackgroundTask, "a real human obligation must stay visible")
        }
    }
}
