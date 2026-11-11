import XCTest
@testable import AgentPetCore

final class CodexInternalTaskStateTests: XCTestCase {
    func testAOUnpublishedSuggestionWorkspaceIsHiddenWithoutChangingReceipts() {
        var value = AgentSession(id: UUID().uuidString, agentKind: .codex,
            project: NSHomeDirectory() + "/.ao/data/background-tasks/title-3742907397",
            title: "Suggest the single most useful next message", state: .done,
            source: .hook, updatedAt: Date())
        value.codexHasNativeThreadRecord = true // stale cache after ephemeral exit
        value.notificationVersion = 9; value.readThroughVersion = 3
        let before = value
        XCTAssertTrue(value.isCodexInternalTask)
        XCTAssertEqual(value, before)
        XCTAssertEqual(value.readThroughVersion, 3)
        value.title = "Any other internal title"
        XCTAssertTrue(value.isCodexInternalTask) // source, not English text
        value.project = "/project/normal"
        XCTAssertFalse(value.isCodexInternalTask)
    }

    func testAOBackgroundWorkspaceRequiresExactReservedDirectoryAndDecimalSuffix() {
        let base = "/synthetic/.ao/data"
        XCTAssertTrue(CodexHookOrigin.isAOBackgroundWorkspace(base + "/background-tasks/title-123", dataDirectory: base))
        for path in [base + "/background-tasks/title-", base + "/background-tasks/title-abc",
                     base + "/background-tasks/title-123/sub", base + "/worktrees/title-123",
                     base + "/background-tasks-other/title-123", base + "/background-tasks/../title-123",
                     "/other/.ao/data/background-tasks/title-123"] {
            XCTAssertFalse(CodexHookOrigin.isAOBackgroundWorkspace(path, dataDirectory: base), path)
        }
    }

    func testInteractiveTargetsAndApprovalsAreNeverHiddenByAOScratchWorkspace() {
        let value = AgentSession(id: UUID().uuidString, agentKind: .codex,
            project: NSHomeDirectory() + "/.ao/data/background-tasks/title-123",
            state: .working, source: .hook, updatedAt: Date())
        var desktop = value; desktop.codexDesktop = true
        var terminal = value; terminal.terminalProgram = "iTerm.app"
        var approval = value; approval.pendingApproval = .init(requestId: "request", toolName: "tool", summary: "approval")
        var hosted = value; hosted.aoBinding = .init(sessionID: "leader", projectID: "project", agentKind: .codex, origin: .hookEnvironment, boundAt: Date())
        var nativeRoute = value; nativeRoute.agentKind = .opencode; nativeRoute.opencodeNavigationSocket = "/tmp/native.sock"
        for session in [desktop, terminal, approval, hosted, nativeRoute] { XCTAssertFalse(session.isCodexInternalTask) }
    }

    func testAOOpenCodeAndPiBackgroundCallsAreExcludedBySourceWithoutHidingInteractiveWork() {
        for kind: AgentKind in [.opencode, .pi] {
            var session = AgentSession(id: UUID().uuidString, agentKind: kind,
                project: NSHomeDirectory() + "/.ao/data/background-tasks/title-123",
                title: "R5 jump testing", state: .done, source: .hook, updatedAt: Date())
            session.notificationVersion = 4; session.readThroughVersion = 1
            let before = session
            XCTAssertTrue(session.isCodexInternalTask, "AO scratch calls are independent of harness")
            XCTAssertEqual(session, before)
            session.aoBinding = .init(sessionID: "worker", projectID: "project", agentKind: kind,
                origin: .hookEnvironment, boundAt: Date())
            XCTAssertFalse(session.isCodexInternalTask)
            session.aoBinding = nil
            session.pendingApproval = .init(requestId: "approval", toolName: "tool", summary: "approval")
            XCTAssertFalse(session.isCodexInternalTask)
        }
    }

    private let id = "11111111-1111-4111-8111-111111111111"
    private let otherID = "22222222-2222-4222-8222-222222222222"
    private let home = "/synthetic/codex-home"

    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + value) }

    private func event(_ name: String = "PreToolUse", at time: Double = 10,
                       home override: String? = nil) -> AgentEvent {
        var value = AgentEvent(sessionId: id, agentKind: .codex, eventName: name,
            project: "/synthetic/project", message: "synthetic Git activity", model: "gpt-6-luna", timestamp: date(time))
        value.codexHome = override ?? home
        return value
    }

    private func evidence(sessionID: String? = nil, home override: String? = nil,
                          kind: String = "projectSuggestions", exitedAt: Double = 20,
                          observedAt: Double = 25) -> CodexInternalTaskEvidence.Record {
        CodexInternalTaskEvidence.Record(sessionID: sessionID ?? id, home: override ?? home,
            kind: kind, exitedAt: date(exitedAt), observedAt: date(observedAt))
    }

    private func fixture(_ change: (inout AgentSession) -> Void = { _ in }) -> (SessionReducer, AgentSession) {
        let reducer = SessionReducer()
        var session = AgentSession(id: id, agentKind: .codex, state: .working,
            message: "synthetic Git activity", model: "gpt-6-luna", source: .hook,
            updatedAt: date(10), stateSince: date(5), createdAt: date(1))
        session.codexHome = home
        session.turnStartedAt = date(3)
        session.codexTurnID = "synthetic-turn"
        session.notificationVersion = 7
        session.readThroughVersion = 4
        session.readAt = date(6)
        session.readDisplayRevision = 2
        session.displayRevision = 3
        change(&session)
        reducer.byID[id] = session
        return (reducer, session)
    }

    func testAnonymousLunaWithoutEvidenceRemainsAnOrdinaryTrackedTask() throws {
        let store = SessionStore(staleActiveAfter: 300)
        store.apply(event(), now: date(10))
        store.prune(now: date(10_000))
        let session = try XCTUnwrap(store.session(id: id))
        XCTAssertNil(session.title)
        XCTAssertEqual(session.model, "gpt-6-luna")
        XCTAssertFalse(session.isCodexInternalTask)
        XCTAssertNil(session.codexInternalTaskExitedAt)
        XCTAssertEqual(session.state, .working)
    }

    private func ownerEvidence(kind: String, at time: Double = 25) -> CodexInternalTaskEvidence.Record {
        .init(sessionID: id, home: home, kind: kind, exitedAt: nil, observedAt: date(time),
            desktopSource: .init(sessionID: id, home: home,
                process: "pid:12345:12345678-1234-4234-8234-123456789abc", lastNativeAt: date(10)))
    }

    func testOwnerCandidatePersistsWithoutHidingOrChangingLifecycleThenFiltersOnlyAfterExit() throws {
        let (reducer, before) = fixture()
        XCTAssertTrue(reducer.applyCodexInternalTaskEvidence(expected: before,
            evidence: ownerEvidence(kind: "desktopTransientCandidate")))
        let candidate = try XCTUnwrap(reducer.session(id: id))
        XCTAssertFalse(candidate.isCodexInternalTask)
        XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: candidate,
            evidence: ownerEvidence(kind: "desktopTransientCandidate", at: 30)))
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(candidate))
        XCTAssertEqual(restored, candidate)
        XCTAssertEqual(restored.codexTransientSource?.process, "pid:12345:12345678-1234-4234-8234-123456789abc")
        XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: candidate,
            evidence: ownerEvidence(kind: "desktopProcessExited", at: 24)), "An older observation cannot override a later candidate")
        XCTAssertTrue(reducer.applyCodexInternalTaskEvidence(expected: candidate,
            evidence: ownerEvidence(kind: "desktopProcessExited", at: 35)))
        var ended = try XCTUnwrap(reducer.session(id: id))
        XCTAssertTrue(ended.isCodexInternalTask)
        XCTAssertNil(ended.codexInternalTaskExitedAt)
        XCTAssertNil(ended.codexTurnResult)
        ended.codexInternalTaskKind = nil; ended.codexInternalTaskObservedAt = nil; ended.codexTransientSource = nil
        XCTAssertEqual(ended, before, "Owner detection must not change state, turn times, messages or read/notification watermarks")
    }

    func testOwnerExitCannotHideFormalHostedTerminalApprovalOrNewerActivity() throws {
        let mutations: [(inout AgentSession) -> Void] = [
            { $0.codexHasNativeThreadRecord = true }, { $0.codexDesktop = true },
            { $0.terminalProgram = "iTerm.app" },
            { $0.pendingApproval = .init(requestId: "request", toolName: "tool", summary: "approval") },
            { $0.aoBinding = .init(sessionID: "leader", projectID: "project", agentKind: .codex, origin: .hookEnvironment, boundAt: self.date(10)) }
        ]
        for change in mutations {
            let (reducer, before) = fixture(change)
            XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: before,
                evidence: ownerEvidence(kind: "desktopProcessExited")))
            XCTAssertEqual(reducer.session(id: id), before)
        }
        let (reducer, before) = fixture()
        _ = reducer.applyHook(event(at: 30), now: date(30))
        XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: before,
            evidence: ownerEvidence(kind: "desktopProcessExited", at: 35)))
    }

    func testNewHookUnhidesOwnerExitAndNativeMetadataClearsCandidateSource() throws {
        let (reducer, before) = fixture()
        XCTAssertTrue(reducer.applyCodexInternalTaskEvidence(expected: before,
            evidence: ownerEvidence(kind: "desktopProcessExited")))
        _ = reducer.applyHook(event(at: 30), now: date(30))
        XCTAssertFalse(try XCTUnwrap(reducer.session(id: id)).isCodexInternalTask)
        reducer.updateCodexMetadata(id: id, record: .init(title: "Saved chat", model: "gpt-6-luna",
            rolloutPath: "/synthetic/rollout.jsonl", isDesktop: true), home: home)
        let saved = try XCTUnwrap(reducer.session(id: id))
        XCTAssertNil(saved.codexTransientSource)
        XCTAssertNil(saved.codexInternalTaskKind)
        XCTAssertTrue(saved.codexHasNativeThreadRecord ?? false)
    }

    private func titleEvidence(at time: Double = 25) -> CodexInternalTaskEvidence.Record {
        .init(sessionID: id, home: home, kind: "aionUiTitle", exitedAt: nil, observedAt: date(time))
    }

    func testTitleClassificationPreservesLifecycleReceiptsAndSnapshotWithoutInventingExit() throws {
        let (reducer, before) = fixture { $0.model = "default" }
        XCTAssertTrue(reducer.applyCodexInternalTaskEvidence(expected: before, evidence: titleEvidence()))
        let marked = try XCTUnwrap(reducer.session(id: id))
        XCTAssertTrue(marked.isCodexInternalTask)
        XCTAssertNil(marked.codexInternalTaskExitedAt)
        XCTAssertEqual(marked.codexInternalTaskObservedAt, date(25))
        var withoutDiagnostic = marked
        withoutDiagnostic.codexInternalTaskKind = nil
        withoutDiagnostic.codexInternalTaskObservedAt = nil
        XCTAssertEqual(withoutDiagnostic, before)
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(marked))
        XCTAssertEqual(restored, marked)
        XCTAssertTrue(restored.isCodexInternalTask)
    }

    func testNewHookOrNativeBindingFencesTitleClassificationAndCanRestoreVisibility() throws {
        let store = SessionStore()
        let expected = try XCTUnwrap(store.apply(event(), now: date(10)))
        XCTAssertTrue(store.applyCodexInternalTaskEvidence(expected: expected, evidence: titleEvidence()))
        let newer = try XCTUnwrap(store.apply(event(at: 30), now: date(30)))
        XCTAssertFalse(newer.isCodexInternalTask)
        XCTAssertFalse(store.applyCodexInternalTaskEvidence(expected: expected, evidence: titleEvidence(at: 40)))
        XCTAssertTrue(store.applyCodexInternalTaskEvidence(expected: newer, evidence: titleEvidence(at: 40)))
        store.updateCodexMetadata(id: id, record: .init(title: nil, model: "gpt-6.1-sol", rolloutPath: nil, isDesktop: false), home: home)
        let ordinary = try XCTUnwrap(store.session(id: id))
        XCTAssertFalse(ordinary.isCodexInternalTask)
        XCTAssertNil(ordinary.codexInternalTaskObservedAt)
        XCTAssertFalse(store.applyCodexInternalTaskEvidence(expected: ordinary, evidence: titleEvidence(at: 50)))
    }

    func testActualTeamMemberAndPendingHumanInteractionAlwaysRemainVisible() {
        let changes: [(inout AgentSession) -> Void] = [
            { $0.title = "Team leader" },
            { $0.codexHasNativeThreadRecord = true },
            { $0.codexDesktop = true },
            { $0.terminalProgram = "iTerm.app" },
            { $0.aionUiConversation = .init(id: "team-codex", nativeSessionID: self.id, agentKind: .codex) },
            { $0.pendingApproval = .init(requestId: "approval", toolName: "fixture", summary: "fixture") },
            { $0.humanRequests = [.init(id: "question", kind: .choice, createdAt: self.date(9))] },
        ]
        for change in changes {
            let (reducer, before) = fixture(change)
            _ = reducer.applyCodexInternalTaskEvidence(expected: before, evidence: titleEvidence())
            XCTAssertFalse(reducer.session(id: id)?.isCodexInternalTask ?? true)
        }
        var unproved = fixture { $0.model = "default" }.1
        XCTAssertFalse(unproved.isCodexInternalTask)
        unproved.codexInternalTaskKind = "aionUiTitle"
        XCTAssertFalse(unproved.isCodexInternalTask)
        unproved.codexInternalTaskObservedAt = date(25)
        XCTAssertTrue(unproved.isCodexInternalTask)
        unproved.codexInternalTaskObservedAt = .init(timeIntervalSince1970: .infinity)
        XCTAssertFalse(unproved.isCodexInternalTask)
    }

    func testPositiveEvidenceChangesOnlyDiagnosticFieldsAndKeepsSnapshotEligibility() throws {
        for kind in ["projectSuggestions", "desktopTransient"] {
            let (reducer, before) = fixture()
            XCTAssertTrue(reducer.applyCodexInternalTaskEvidence(expected: before, evidence: evidence(kind: kind)))
            var after = try XCTUnwrap(reducer.session(id: id))
            XCTAssertTrue(after.isCodexInternalTask)
            XCTAssertEqual(after.codexInternalTaskExitedAt, date(20))
            XCTAssertTrue(SessionSnapshotDTO.includes(after))
            XCTAssertNil(after.codexTurnResult)
            let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(after))
            XCTAssertTrue(restored.isCodexInternalTask)
            after.codexInternalTaskKind = nil
            after.codexInternalTaskExitedAt = nil
            XCTAssertEqual(after, before, "Classification must not manufacture state, result, timing, notification, or read changes")
        }
    }

    func testDuplicateAndOlderEvidenceCannotEraseOrRewindTheDiagnostic() throws {
        let (reducer, before) = fixture()
        XCTAssertTrue(reducer.applyCodexInternalTaskEvidence(expected: before, evidence: evidence()))
        var expected = try XCTUnwrap(reducer.session(id: id))
        XCTAssertTrue(expected.isCodexInternalTask)
        XCTAssertEqual(expected.codexInternalTaskExitedAt, date(20))
        XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence()))
        XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence(exitedAt: 19)))
        XCTAssertEqual(reducer.session(id: id)?.codexInternalTaskExitedAt, date(20))
        XCTAssertTrue(reducer.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence(exitedAt: 21)))
        expected = try XCTUnwrap(reducer.session(id: id))
        XCTAssertEqual(expected.codexInternalTaskExitedAt, date(21))
    }

    func testWrongSessionHomePurposeAndInvalidTimesNeverClassify() {
        let (reducer, before) = fixture()
        for record in [evidence(sessionID: otherID), evidence(home: "/synthetic/other-home"),
                       evidence(kind: "unknownInternalPurpose"), evidence(exitedAt: 9),
                       evidence(exitedAt: 30, observedAt: 25), evidence(exitedAt: 9, observedAt: 9)] {
            XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: before, evidence: record))
            XCTAssertEqual(reducer.session(id: id), before)
        }
    }

    func testKnownDesktopTerminalAndAionUiBindingsAreNeverClassified() {
        let changes: [(inout AgentSession) -> Void] = [
            { $0.codexDesktop = true },
            { $0.title = "Known user thread" },
            { $0.terminalProgram = "iTerm.app" },
            { $0.terminalTTY = "/dev/ttys001" },
            { $0.terminalFocusURL = "warp://synthetic" },
            { $0.aionUiConversation = AionUiConversation(id: "synthetic-chat", nativeSessionID: self.id, agentKind: .codex) },
        ]
        for change in changes {
            let (reducer, known) = fixture(change)
            XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: known, evidence: evidence()))
            XCTAssertEqual(reducer.session(id: id), known)
        }
        // An association may arrive while the read-only diagnostic query is running.
        let (reducer, expected) = fixture()
        reducer.byID[id]?.codexDesktop = true
        XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence()))
        XCTAssertFalse(reducer.session(id: id)?.isCodexInternalTask ?? true)
    }

    func testLateResultCannotClassifyRemovedReplacedOrDifferentHomeInstance() {
        let (reducer, expected) = fixture()
        reducer.remove(id: id)
        XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence()))
        var replacement = expected
        replacement.createdAt = date(12)
        reducer.byID[id] = replacement
        XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence()))
        replacement = expected
        replacement.codexHome = "/synthetic/new-home"
        reducer.byID[id] = replacement
        XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence()))
        replacement = expected
        replacement.agentKind = .antigravity
        reducer.byID[id] = replacement
        XCTAssertFalse(reducer.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence()))
        XCTAssertEqual(reducer.session(id: id), replacement)
    }

    func testHookAfterNativeExitRejectsDelayedClassification() throws {
        let store = SessionStore()
        let expected = try XCTUnwrap(store.apply(event(), now: date(10)))
        let newer = try XCTUnwrap(store.apply(event(at: 30), now: date(30)))
        XCTAssertFalse(store.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence(observedAt: 40)))
        XCTAssertEqual(store.session(id: id), newer)
    }

    func testAcceptedDiagnosticSurvivesLaterHooksButCannotKeepNewActivityHidden() throws {
        let store = SessionStore()
        let expected = try XCTUnwrap(store.apply(event(), now: date(10)))
        XCTAssertTrue(store.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence()))
        store.apply(event(at: 30), now: date(30))
        XCTAssertEqual(store.session(id: id)?.codexInternalTaskKind, "projectSuggestions")
        XCTAssertFalse(store.session(id: id)?.isCodexInternalTask ?? true)
        XCTAssertEqual(store.session(id: id)?.state, .working)
        XCTAssertNil(store.session(id: id)?.codexTurnResult)
        store.apply(event("Stop", at: 40), now: date(40))
        XCTAssertEqual(store.session(id: id)?.codexInternalTaskKind, "projectSuggestions")
        XCTAssertFalse(store.session(id: id)?.isCodexInternalTask ?? true)
        XCTAssertEqual(store.session(id: id)?.codexInternalTaskExitedAt, date(20))
        XCTAssertNil(store.session(id: id)?.codexTurnResult)
    }

    func testLegacySnapshotWithoutDiagnosticFieldsDecodesAndNewSnapshotRoundTrips() throws {
        let legacy = Data(#"{"id":"11111111-1111-4111-8111-111111111111","agentKind":"codex","state":"working","source":"hook","updatedAt":2,"stateSince":1,"createdAt":0,"codexDesktop":false,"notificationVersion":0,"readThroughVersion":0}"#.utf8)
        let old = try JSONDecoder().decode(AgentSession.self, from: legacy)
        XCTAssertNil(old.codexInternalTaskKind)
        XCTAssertNil(old.codexInternalTaskExitedAt)
        XCTAssertNil(old.codexHasNativeThreadRecord)
        XCTAssertFalse(old.isCodexInternalTask)
        let (reducer, expected) = fixture()
        XCTAssertTrue(reducer.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence()))
        let marked = try XCTUnwrap(reducer.session(id: id))
        let encoded = try JSONEncoder().encode(SessionSnapshotDTO(sessions: [marked]))
        let snapshot = try JSONDecoder().decode(SessionSnapshotDTO.self, from: encoded)
        let restored = SessionReducer()
        restored.restore(snapshot)
        XCTAssertEqual(restored.session(id: id), marked)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(marked)) as? [String: Any])
        XCTAssertEqual(object["codexInternalTaskKind"] as? String, "projectSuggestions")
        XCTAssertNil(object["codexContext"])
    }

    func testInternalPropertyRequiresKnownPurposeCodexKindAndCurrentExit() {
        var session = fixture().1
        session.codexInternalTaskExitedAt = date(20)
        session.codexInternalTaskKind = "unknownInternalPurpose"
        XCTAssertFalse(session.isCodexInternalTask)
        session.codexInternalTaskKind = "projectSuggestions"
        XCTAssertTrue(session.isCodexInternalTask)
        session.agentKind = .opencode
        XCTAssertFalse(session.isCodexInternalTask)
    }

    func testEverySuccessfulNativeThreadRecordSupersedesTheInternalFallback() throws {
        let records = [
            CodexMetadata.Record(title: "Normal user thread", model: "example-model", rolloutPath: nil, isDesktop: true),
            CodexMetadata.Record(title: nil, model: "gpt-6-luna", rolloutPath: nil, isDesktop: false),
            CodexMetadata.Record(title: nil, model: nil, rolloutPath: "/synthetic/rollout.jsonl", isDesktop: false),
        ]
        for record in records {
            let store = SessionStore()
            let expected = try XCTUnwrap(store.apply(event(), now: date(10)))
            XCTAssertTrue(store.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence()))
            XCTAssertTrue(store.session(id: id)?.isCodexInternalTask ?? false)
            store.updateCodexMetadata(id: id, record: record, home: home)
            let visible = try XCTUnwrap(store.session(id: id))
            XCTAssertFalse(visible.isCodexInternalTask)
            XCTAssertNil(visible.codexInternalTaskKind)
            XCTAssertNil(visible.codexInternalTaskExitedAt)
            XCTAssertEqual(visible.codexHasNativeThreadRecord, true)
            XCTAssertEqual(visible.state, .working)
            XCTAssertNil(visible.codexTurnResult)
        }
    }

    func testTitlelessUnchangedNativeRecordFencesBothOldAndNewFallbackReads() throws {
        let store = SessionStore()
        let expected = try XCTUnwrap(store.apply(event(), now: date(10)))
        // All existing display/source fields stay unchanged; the explicit source
        // fact must still fence a diagnostic query already in flight.
        store.updateCodexMetadata(id: id,
            record: CodexMetadata.Record(title: nil, model: "gpt-6-luna", rolloutPath: nil, isDesktop: false), home: home)
        let current = try XCTUnwrap(store.session(id: id))
        XCTAssertEqual(current.title, expected.title)
        XCTAssertEqual(current.model, expected.model)
        XCTAssertEqual(current.updatedAt, expected.updatedAt)
        XCTAssertFalse(store.applyCodexInternalTaskEvidence(expected: expected, evidence: evidence()))
        XCTAssertFalse(store.applyCodexInternalTaskEvidence(expected: current, evidence: evidence()))
        XCTAssertEqual(store.session(id: id), current)
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(restored.codexHasNativeThreadRecord, true)
        XCTAssertFalse(restored.isCodexInternalTask)
    }

    func testMissingExitHostBindingOrPendingHumanInteractionNeverHidesAMarkedRecord() {
        var marked = fixture().1
        marked.codexInternalTaskKind = "projectSuggestions"
        XCTAssertFalse(marked.isCodexInternalTask)
        marked.codexInternalTaskExitedAt = date(20)
        XCTAssertTrue(marked.isCodexInternalTask)
        let changes: [(inout AgentSession) -> Void] = [
            { $0.codexDesktop = true },
            { $0.codexHasNativeThreadRecord = true },
            { $0.terminalProgram = "iTerm.app" },
            { $0.terminalTTY = "/dev/ttys001" },
            { $0.terminalFocusURL = "warp://synthetic" },
            { $0.aionUiConversation = AionUiConversation(id: "synthetic-chat", nativeSessionID: self.id, agentKind: .codex) },
            { $0.pendingApproval = PendingApproval(requestId: "synthetic-approval", toolName: "synthetic", summary: "synthetic") },
            { $0.humanRequests = [HumanRequest(id: "synthetic-question", kind: .choice, createdAt: self.date(9))] },
            { $0.updatedAt = self.date(21) },
            { $0.codexInternalTaskExitedAt = Date(timeIntervalSince1970: .infinity) },
        ]
        for change in changes {
            var visible = marked
            change(&visible)
            XCTAssertFalse(visible.isCodexInternalTask)
            XCTAssertEqual(visible.codexInternalTaskKind, "projectSuggestions")
        }
    }
}
