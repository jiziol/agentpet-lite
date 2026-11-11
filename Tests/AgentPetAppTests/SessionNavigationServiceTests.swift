import XCTest
import CSQLite
@testable import AgentPetCore
@testable import agentpet

@MainActor
final class SessionNavigationServiceTests: XCTestCase {
    private final class Backend: SessionNavigationBackend {
        var binding = DSHAntigravityBinding.Lookup.notFound
        var selectedTargets: [DSHObservation] = []
        func dshBinding(_ session: AgentSession) async -> DSHAntigravityBinding.Lookup { calls.append("binding"); return binding }
        var lookup = AionUiMetadata.Lookup.notFound
        var selected = true
        var tuiSelection: OpencodeTUINavigation.Result?
        var focusedSessions: [AgentSession] = []
        var terminal = TerminalFocus.Result.openedTarget
        var accepted = true
        var foreground = true
        var calls: [String] = []
        var openedURLs: [URL] = []
        var onFocus: (() -> Void)?
        var gate: CheckedContinuation<TerminalFocus.Result, Never>?
        var suspendFocus = false
        var dshReceipt: DSHNavigation.Receipt?
        var confirmation: DSHNavigation.Receipt?
        var dshDesktopPID: pid_t? = 42
        var dshActivationOutcome: DSHActivationOutcome = .activated
        var onActivate: (() -> Void)?
        func association(_ session: AgentSession) async -> AionUiMetadata.Lookup { calls.append("association"); return lookup }
        func selectOpencode(_ session: AgentSession) async -> OpencodeTUINavigation.Result {
            calls.append("select")
            if let tuiSelection { return tuiSelection }
            guard session.opencodeNavigationSocket != nil else { return .unsupported }
            return selected ? .selected(.init(program: session.terminalProgram, tty: session.terminalTTY, focusURL: session.terminalFocusURL)) : .failed
        }
        func focusTerminal(_ session: AgentSession) async -> TerminalFocus.Result {
            calls.append("focus"); focusedSessions.append(session); onFocus?()
            if suspendFocus { return await withCheckedContinuation { gate = $0 } }
            return terminal
        }
        func open(_ url: URL, bundleID: String) async -> Bool { calls.append("open:" + bundleID); openedURLs.append(url); return accepted }
        func isFrontmost(bundleID: String) -> Bool { foreground }
        func selectDSH(_ target: DSHObservation, verifyOnly: Bool) async -> DSHNavigation.Receipt? {
            selectedTargets.append(target); calls.append(verifyOnly ? "verifyDSH" : "selectDSH"); return verifyOnly ? confirmation : dshReceipt
        }
        func dshDesktop(peerPID: pid_t) async -> pid_t? { calls.append("ancestor"); return dshDesktopPID }
        func activateDSH(_ pid: pid_t, validate: @escaping @MainActor () -> Bool) async -> DSHActivationOutcome {
            calls.append("activate")
            onActivate?()
            return validate() ? dshActivationOutcome : .superseded
        }
        func isFrontmostDSH(_ pid: pid_t) -> Bool { foreground }
    }
    private func session(_ kind: AgentKind = .claude, id: String = "00000000-0000-4000-8000-000000000005") -> AgentSession {
        .init(id: id, agentKind: kind, state: .working, source: .hook, updatedAt: Date(timeIntervalSince1970: 100), terminalProgram: "iTerm.app")
    }
    private func service(_ backend: Backend, session: @escaping (String) -> AgentSession?,
                         done: @escaping (AgentSession, SessionNavigationResult) -> Void) -> SessionNavigationService {
        SessionNavigationService(backend: backend, session: session, dshTarget: { $0.dsh }, updateAssociation: { _,_ in }, completion: done)
    }
    func testAmbiguousOrLostKnownAionUiNeverFallsBackToTerminal() async {
        for lookup: AionUiMetadata.Lookup in [.ambiguous, .unavailable, .notFound] {
            var s = session(.opencode)
            s.aionUiConversation = .init(id: "conversation", nativeSessionID: s.id, agentKind: s.agentKind)
            let backend = Backend(); backend.lookup = lookup
            let done = expectation(description: "failed association")
            let service = service(backend, session: { _ in s }) { _, result in
                if case .failed = result {} else { XCTFail("must fail") }
                done.fulfill()
            }
            XCTAssertTrue(service.navigate(s))
            await fulfillment(of: [done], timeout: 1)
            XCTAssertEqual(backend.calls, ["association"])
        }
    }
    func testOpencodeSelectsBeforeTabFocusAndActivationAloneIsFailure() async {
        var s = session(.opencode); s.opencodeNavigationSocket = "/fixture/opencode.sock"
        let backend = Backend(); backend.terminal = .activatedApplication
        let done = expectation(description: "terminal failure")
        let service = service(backend, session: { _ in s }) { _, result in
            if case .failed = result {} else { XCTFail("activation must not acknowledge") }
            done.fulfill()
        }
        service.navigate(s); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association", "select", "focus"])
    }
    func testOpencodeWithoutNavigationEntryReportsCapabilityAndNeverFocusesTerminal() async {
        let s = session(.opencode)
        XCTAssertEqual(BubblePresentation.Row(session: s).navigationHint,
                       NSLocalizedString("navigation.opencode.hint", comment: ""))
        let backend = Backend()
        let done = expectation(description: "unsupported navigation")
        let service = service(backend, session: { _ in s }) { _, result in
            guard case .failed(let message) = result else {
                XCTFail("A terminal association cannot supply missing OpenCode session-selection capability")
                done.fulfill(); return
            }
            XCTAssertEqual(message, NSLocalizedString("navigation.opencode.unsupported", comment: ""))
            done.fulfill()
        }
        service.navigate(s); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association", "select"], "Probe TUI capability without falling back to inherited terminal identity")
    }
    func testOpencodeSelectionFailureDoesNotClaimTheTUIIsNotRunning() async {
        var s = session(.opencode); s.opencodeNavigationSocket = "/fixture/opencode.sock"
        let backend = Backend(); backend.selected = false
        let done = expectation(description: "selection failed")
        let service = service(backend, session: { _ in s }) { _, result in
            guard case .failed(let message) = result else { XCTFail("Selection failure must not acknowledge the session"); done.fulfill(); return }
            XCTAssertEqual(message, NSLocalizedString("navigation.opencode.failed", comment: ""))
            done.fulfill()
        }
        service.navigate(s); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association", "select"])
    }
    func testV2UsesTheSelectedTUITerminalInsteadOfTheServerInheritedTerminal() async {
        var s = session(.opencode)
        s.opencodeProcessID = 222; s.terminalProgram = "wrong-server-terminal"; s.terminalTTY = "/dev/ttys001"
        let backend = Backend()
        backend.tuiSelection = .selected(.init(program: "iTerm.app", tty: "/dev/ttys007"))
        let done = expectation(description: "selected TUI focused")
        let service = service(backend, session: { _ in s }) { _, result in
            guard case .opened(.terminalTarget) = result else { XCTFail("Must focus the selected TUI"); done.fulfill(); return }
            done.fulfill()
        }
        XCTAssertTrue(BubblePresentation.Row(session: s).canFocusTerminal)
        service.navigate(s); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.focusedSessions.last?.terminalProgram, "iTerm.app")
        XCTAssertEqual(backend.focusedSessions.last?.terminalTTY, "/dev/ttys007")
        XCTAssertEqual(backend.focusedSessions.last?.id, s.id)
    }
    func testV2AmbiguousUnavailableAndRejectedTargetsNeverFocusOrAcknowledge() async {
        for selection: OpencodeTUINavigation.Result in [.ambiguous, .unavailable, .failed] {
            let s = session(.opencode); let backend = Backend(); backend.tuiSelection = selection
            let done = expectation(description: "fail closed")
            let service = service(backend, session: { _ in s }) { _, result in
                guard case .failed = result else { XCTFail("Unverified target cannot be acknowledged"); done.fulfill(); return }
                done.fulfill()
            }
            service.navigate(s); await fulfillment(of: [done], timeout: 1)
            XCTAssertTrue(backend.focusedSessions.isEmpty)
        }
    }
    func testDeepLinkEvidenceDistinctAndMatchedAionUiPrecedesCodexDesktop() async {
        var s = session(.codex); s.codexDesktop = true
        let backend = Backend()
        backend.lookup = .matched(.init(conversation: .init(id: "conversation", nativeSessionID: s.id, agentKind: .codex), title: nil))
        let done = expectation(description: "link accepted")
        let service = service(backend, session: { _ in s }) { _, result in
            if case .opened(.deepLinkAcceptedAndForeground) = result {} else { XCTFail("wrong evidence") }
            done.fulfill()
        }
        service.navigate(s); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association", "open:com.aionui.app"])
    }

    func testMigratedCLIRefreshEnablesClickAndDesktopRouteWithoutTerminal() async throws {
        for accepted in [true, false] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let id = "11111111-1111-4111-8111-111111111111"
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,originator TEXT,source TEXT); INSERT INTO threads VALUES('\(id)','Migrated','codex-tui','vscode');", nil, nil, nil), SQLITE_OK)
            let store = SessionStore(), at = Date(timeIntervalSince1970: 100)
            store.apply(.init(sessionId: id, agentKind: .codex, eventName: "Stop", timestamp: at), now: at)
            XCTAssertFalse(BubblePresentation.Row(session: try XCTUnwrap(store.session(id: id))).canFocusTerminal)
            // Desktop can evict activity entries while retaining an empty tab topology.
            try JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": ["thread-tab-routes-v1:" + id: ["version": 1, "routes": [], "topology": [:]]]]).write(to: home.appendingPathComponent(".codex-global-state.json"))
            store.updateCodexMetadata(id: id, record: try XCTUnwrap(CodexMetadata.read(sessionID: id, home: home.path)), home: home.path)
            let clicked = try XCTUnwrap(store.session(id: id))
            XCTAssertNil(clicked.terminalProgram)
            XCTAssertTrue(BubblePresentation.Row(session: clicked).canFocusTerminal)
            XCTAssertTrue(clicked.hasUnread)
            let backend = Backend(); backend.accepted = accepted
            let done = expectation(description: "migrated desktop navigation")
            let service = service(backend, session: { store.session(id: $0) }) { value, result in
                if accepted {
                    if case .opened(.deepLinkAcceptedAndForeground) = result {
                        _ = store.markOpened(value, at: at.addingTimeInterval(1))
                    } else { XCTFail("must use desktop deep link") }
                } else if case .failed = result {} else { XCTFail("rejected deep link must fail") }
                done.fulfill()
            }
            service.navigate(clicked)
            await fulfillment(of: [done], timeout: 1)
            XCTAssertEqual(backend.calls, ["association", "open:com.openai.codex"])
            XCTAssertEqual(backend.openedURLs.map(\.absoluteString), ["codex://threads/" + id])
            XCTAssertEqual(store.session(id: id)?.hasUnread, !accepted)
        }
    }

    func testPiExactAionUiAssociationTakesPriorityOverInheritedTerminal() async {
        let s = session(.pi, id: "pi:/synthetic/fixture.jsonl")
        let backend = Backend()
        backend.lookup = .matched(.init(conversation: .init(id: "pi_chat", nativeSessionID: s.id, agentKind: .pi), title: "Pi test"))
        let done = expectation(description: "Pi host navigation")
        let service = service(backend, session: { _ in s }) { _, result in
            if case .opened(.deepLinkAcceptedAndForeground) = result {} else { XCTFail("Pi must use its verified host") }
            done.fulfill()
        }
        service.navigate(s); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association", "open:com.aionui.app"])
    }

    func testUnhostedPiRetainsTerminalNavigationAndAmbiguityCannotOpenIt() async {
        for ambiguous in [false, true] {
            let s = session(.pi), backend = Backend()
            backend.lookup = ambiguous ? .ambiguous : .notFound
            let done = expectation(description: "Pi terminal routing")
            let service = service(backend, session: { _ in s }) { _, result in
                if ambiguous { if case .failed = result {} else { XCTFail("ambiguous host") } }
                else { if case .opened(.terminalTarget) = result {} else { XCTFail("terminal Pi") } }
                done.fulfill()
            }
            service.navigate(s); await fulfillment(of: [done], timeout: 1)
            XCTAssertEqual(backend.calls, ambiguous ? ["association"] : ["association", "focus"])
        }
    }
    func testDelayedSuccessAcknowledgesClickedRevisionOnly() async throws {
        let store = SessionStore(); let at = Date(timeIntervalSince1970: 100)
        let clicked = try XCTUnwrap(store.apply(.init(sessionId: "s", agentKind: .claude, eventName: "working", timestamp: at), now: at))
        let backend = Backend(); backend.suspendFocus = true
        let focused = expectation(description: "focus requested"); backend.onFocus = { focused.fulfill() }
        let done = expectation(description: "old result")
        let service = service(backend, session: { store.session(id: $0) }) { value, result in
            if case .opened = result { _ = store.markOpened(value, at: at.addingTimeInterval(2)) }
            done.fulfill()
        }
        service.navigate(clicked); await fulfillment(of: [focused], timeout: 1)
        _ = store.apply(.init(sessionId: "s", agentKind: .claude, eventName: "done", timestamp: at.addingTimeInterval(1)), now: at.addingTimeInterval(1))
        backend.gate?.resume(returning: .openedTarget); backend.gate = nil
        await fulfillment(of: [done], timeout: 1)
        XCTAssertTrue(try XCTUnwrap(store.session(id: "s")).hasUnread)
        XCTAssertEqual(store.session(id: "s")?.readDisplayRevision, clicked.displayRevision ?? 0)
    }
    func testReplacedInstanceAndStoppedAttemptCannotReceiveReadReceipt() async {
        let clicked = session(); var current = clicked
        let backend = Backend(); backend.suspendFocus = true
        let focused = expectation(description: "focus"); backend.onFocus = { focused.fulfill() }
        let done = expectation(description: "superseded")
        let service = service(backend, session: { _ in current }) { _, result in
            if case .superseded = result {} else { XCTFail("stale instance") }; done.fulfill()
        }
        XCTAssertTrue(service.navigate(clicked)); XCTAssertFalse(service.navigate(clicked))
        await fulfillment(of: [focused], timeout: 1)
        current.createdAt = clicked.createdAt.addingTimeInterval(1)
        backend.gate?.resume(returning: .openedTarget); backend.gate = nil
        await fulfillment(of: [done], timeout: 1)
        backend.onFocus = nil; backend.suspendFocus = false
        service.navigate(current); service.stop()
        await Task.yield()
        XCTAssertEqual(backend.calls, ["association", "focus"])
    }
    func testDSHAgyWithoutTerminalNavigatesExactBindingAndRevalidatesBeforeAcknowledging() async throws {
        for changed in [false, true] {
            var s = session(.antigravity); s.terminalProgram = nil
            XCTAssertTrue(BubblePresentation.Row(session: s).canFocusTerminal)
            let b = Backend()
            let target = try XCTUnwrap(dshSession().dsh)
            let record = DSHAntigravityBinding.Record(profileID: target.profileID, nativeSessionID: target.nativeSessionID)
            b.binding = .matched(record)
            b.dshReceipt = .init(peerPID: 10, clientID: "client", generation: UUID().uuidString)
            b.confirmation = b.dshReceipt
            if changed { b.onActivate = { b.binding = .notFound } }
            let done = expectation(description: "mapped DSH")
            let service = SessionNavigationService(backend: b, session: { _ in s }, dshTarget: { _ in nil },
                dshBridgeTarget: { $0 == record ? target : nil }, updateAssociation: { _,_ in }, completion: { _, result in
                    if changed { if case .failed = result {} else { XCTFail("changed binding must fail") } }
                    else { if case .opened(.dshConfirmed) = result {} else { XCTFail("must require DSH evidence") } }
                    done.fulfill()
                })
            XCTAssertTrue(service.navigate(s)); await fulfillment(of: [done], timeout: 2)
            XCTAssertEqual(b.selectedTargets.map(\.nativeSessionID), [target.nativeSessionID, target.nativeSessionID])
            XCTAssertFalse(b.calls.contains("focus"))
        }
    }

    func testDSHAgyUnknownAmbiguousOrDisconnectedCannotAcknowledgeOrOpenTerminal() async {
        for lookup: DSHAntigravityBinding.Lookup in [.ambiguous, .unavailable, .matched(.init(profileID: "fixture", nativeSessionID: "missing"))] {
            let s = session(.antigravity); let b = Backend(); b.binding = lookup
            let done = expectation(description: "unconfirmed DSH")
            let service = service(b, session: { _ in s }) { _, result in
                if case .failed = result {} else { XCTFail("must fail closed") }; done.fulfill()
            }
            XCTAssertTrue(service.navigate(s)); await fulfillment(of: [done], timeout: 1)
            XCTAssertFalse(b.calls.contains("focus")); XCTAssertFalse(b.calls.contains("selectDSH"))
        }
    }

    func testDSHVerifiesSelectionAfterActivationAndRejectsChangedGeneration() async {
        for sameGeneration in [true, false] {
            var s = session(.dsh)
            s.dsh = .init(schema: 1, profileID: String(repeating: "a", count: 24), hostID: UUID().uuidString,
                hostStartedAt: s.createdAt, nativeSessionID: "fixture", revision: 1, nativeSeq: 1, turn: 1,
                phase: .working, result: nil, pending: [], startedAt: s.createdAt, endedAt: nil,
                baseline: false, heartbeat: false, gap: false, navigationSocket: "/tmp/agentpet-dsh-501/h-test/nav.sock")
            let backend = Backend(); let generation = UUID().uuidString
            backend.dshReceipt = .init(peerPID: 42, clientID: "fixture", generation: generation)
            backend.confirmation = .init(peerPID: 42, clientID: "fixture", generation: sameGeneration ? generation : UUID().uuidString)
            let done = expectation(description: "confirmed")
            let service = service(backend, session: { _ in s }) { _, result in
                if sameGeneration { if case .opened(.dshConfirmed) = result {} else { XCTFail("must confirm") } }
                else { if case .failed = result {} else { XCTFail("must reject") } }
                done.fulfill()
            }
            service.navigate(s); await fulfillment(of: [done], timeout: 1)
            XCTAssertEqual(backend.calls, ["selectDSH", "ancestor", "activate", "verifyDSH"])
        }
    }

    func testDSHSelectionAloneNeverAcknowledgesAnUnverifiedOrRejectedDesktop() async {
        for missingDesktop in [true, false] {
            var s = session(.dsh)
            s.dsh = .init(schema: 1, profileID: String(repeating: "a", count: 24), hostID: UUID().uuidString,
                hostStartedAt: s.createdAt, nativeSessionID: "fixture", revision: 1, nativeSeq: 1, turn: 1,
                phase: .working, result: nil, pending: [], startedAt: s.createdAt, endedAt: nil,
                baseline: false, heartbeat: false, gap: false, navigationSocket: "/tmp/agentpet-dsh-501/h-test/nav.sock")
            let backend = Backend()
            backend.dshReceipt = .init(peerPID: 42, clientID: "fixture", generation: UUID().uuidString)
            backend.dshDesktopPID = missingDesktop ? nil : 42
            backend.dshActivationOutcome = .requestRejected
            let done = expectation(description: "selection is insufficient")
            let service = service(backend, session: { _ in s }) { _, result in
                guard case .failed(let message) = result else { XCTFail("must not acknowledge"); done.fulfill(); return }
                XCTAssertTrue(message.contains(missingDesktop ? "桌面进程" : "窗口切换"))
                done.fulfill()
            }
            service.navigate(s); await fulfillment(of: [done], timeout: 1)
            XCTAssertEqual(backend.calls, missingDesktop ? ["selectDSH", "ancestor"] : ["selectDSH", "ancestor", "activate"])
        }
    }

    private func dshSession() -> AgentSession {
        var s = session(.dsh)
        s.dsh = .init(schema: 1, profileID: String(repeating: "a", count: 24), hostID: UUID().uuidString,
            hostStartedAt: s.createdAt, nativeSessionID: "fixture", revision: 1, nativeSeq: 1, turn: 1,
            phase: .working, result: nil, pending: [], startedAt: s.createdAt, endedAt: nil,
            baseline: false, heartbeat: false, gap: false, navigationSocket: "/tmp/agentpet-dsh-501/h-test/nav.sock")
        return s
    }

    func testDSHActivationReasonsMapToDistinctFailures() async {
        let cases: [(DSHActivationOutcome, String)] = [
            (.appMissing, "桌面进程"), (.bundleMismatch, "桌面进程"), (.terminated, "桌面进程"),
            (.requestRejected, "窗口切换"), (.selfActivationFailed, "窗口切换"), (.yieldRejected, "窗口切换"),
        ]
        for (outcome, expected) in cases {
            let s = dshSession()
            let backend = Backend()
            backend.dshReceipt = .init(peerPID: 42, clientID: "fixture", generation: UUID().uuidString)
            backend.dshActivationOutcome = outcome
            let done = expectation(description: "mapped failure")
            let service = service(backend, session: { _ in s }) { _, result in
                guard case .failed(let message) = result else { XCTFail("must fail: \(outcome)"); done.fulfill(); return }
                XCTAssertTrue(message.contains(expected), "\(outcome)")
                done.fulfill()
            }
            service.navigate(s); await fulfillment(of: [done], timeout: 1)
            XCTAssertEqual(backend.calls, ["selectDSH", "ancestor", "activate"], "\(outcome)")
        }
    }

    func testDSHCancelledActivationSupersedesWithoutPolling() async {
        let s = dshSession()
        let backend = Backend()
        backend.dshReceipt = .init(peerPID: 42, clientID: "fixture", generation: UUID().uuidString)
        backend.dshActivationOutcome = .cancelled
        let done = expectation(description: "superseded")
        let service = service(backend, session: { _ in s }) { _, result in
            if case .superseded = result {} else { XCTFail("cancelled activation must not acknowledge") }
            done.fulfill()
        }
        service.navigate(s); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["selectDSH", "ancestor", "activate"])
    }

    func testDSHAllowedActivationStillRequiresRealFrontmost() async {
        let s = dshSession()
        let backend = Backend()
        backend.dshReceipt = .init(peerPID: 42, clientID: "fixture", generation: UUID().uuidString)
        backend.foreground = false
        let done = expectation(description: "frontmost required")
        let service = service(backend, session: { _ in s }) { _, result in
            guard case .failed(let message) = result else { XCTFail("accepted request is not frontmost proof"); done.fulfill(); return }
            XCTAssertTrue(message.contains("前台"))
            done.fulfill()
        }
        service.navigate(s); await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(backend.calls, ["selectDSH", "ancestor", "activate"])
    }

    func testDSHSourceChangeDuringActivationWaitSupersedesWithoutSwitch() async {
        var current = dshSession()
        let clicked = current
        let backend = Backend()
        backend.dshReceipt = .init(peerPID: 42, clientID: "fixture", generation: UUID().uuidString)
        backend.onActivate = {
            // The host/turn changed while the real activator would be waiting;
            // the navigation token itself was never cancelled.
            guard let dsh = current.dsh else { return }
            current.dsh = .init(schema: dsh.schema, profileID: dsh.profileID, hostID: dsh.hostID,
                                hostStartedAt: dsh.hostStartedAt, nativeSessionID: dsh.nativeSessionID,
                                revision: dsh.revision, nativeSeq: dsh.nativeSeq, turn: (dsh.turn ?? 0) + 1,
                                phase: dsh.phase, result: dsh.result, pending: dsh.pending,
                                startedAt: dsh.startedAt, endedAt: dsh.endedAt, baseline: dsh.baseline,
                                heartbeat: dsh.heartbeat, gap: dsh.gap, navigationSocket: dsh.navigationSocket)
        }
        let done = expectation(description: "superseded")
        let service = service(backend, session: { _ in current }) { _, result in
            if case .superseded = result {} else { XCTFail("changed turn must not switch") }
            done.fulfill()
        }
        service.navigate(clicked); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["selectDSH", "ancestor", "activate"])
    }

    func testVerifiedTeamAssociationNavigatesToTeamRoute() async throws {
        let s = session(.codex)
        let conversation = AionUiConversation(id: "conversation", nativeSessionID: s.id, agentKind: .codex,
                                              teamID: "team_a", teamName: "Team Alpha", teamRole: .lead)
        var stored = s
        stored.aionUiConversation = conversation
        let backend = Backend()
        backend.lookup = .matched(.init(conversation: conversation, title: "Team Alpha"))
        let done = expectation(description: "team route")
        let service = service(backend, session: { _ in stored }) { _, result in
            if case .opened(.deepLinkAcceptedAndForeground) = result {} else { XCTFail("team must open") }
            done.fulfill()
        }
        service.navigate(stored); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association", "open:com.aionui.app"])
        let opened = try XCTUnwrap(backend.openedURLs.first)
        let components = try XCTUnwrap(URLComponents(url: opened, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "route", value: "/team/team_a")])
    }

    func testUnverifiedTeamMarkFailsClosedWithoutOpeningMemberPage() async {
        var s = session(.codex)
        s.aionUiConversation = AionUiConversation(id: "conversation", nativeSessionID: s.id, agentKind: .codex,
                                                  teamID: "team_a")
        let backend = Backend()
        backend.lookup = .matched(.init(conversation: .init(id: "conversation", nativeSessionID: s.id,
                                                            agentKind: .codex, teamID: "team_a"), title: nil))
        let done = expectation(description: "fail closed")
        let service = service(backend, session: { _ in s }) { _, result in
            if case .failed = result {} else { XCTFail("unverified team must fail closed") }
            done.fulfill()
        }
        service.navigate(s); await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.calls, ["association"])
        XCTAssertTrue(backend.openedURLs.isEmpty)
    }

    func testNonTeamAssociationKeepsConversationRoute() async throws {
        let s = session(.claude)
        let conversation = AionUiConversation(id: "conversation", nativeSessionID: s.id, agentKind: .claude)
        let backend = Backend()
        backend.lookup = .matched(.init(conversation: conversation, title: nil))
        let done = expectation(description: "conversation route")
        let service = service(backend, session: { _ in s }) { _, result in
            if case .opened(.deepLinkAcceptedAndForeground) = result {} else { XCTFail("conversation must open") }
            done.fulfill()
        }
        service.navigate(s); await fulfillment(of: [done], timeout: 1)
        let opened = try XCTUnwrap(backend.openedURLs.first)
        let components = try XCTUnwrap(URLComponents(url: opened, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "route", value: "/conversation/conversation")])
    }
}
