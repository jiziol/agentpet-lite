import XCTest
@testable import AgentPetCore
@testable import agentpet

final class BubblePresentationTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 100)
    private func session(_ kind: AgentKind, _ id: String, _ state: AgentState = .working) -> AgentSession {
        AgentSession(id: id, agentKind: kind, state: state, source: .hook, updatedAt: at)
    }
    func testPiClickBecomesAvailableWithVerifiedAionUiBinding() {
        var pi = session(.pi, "pi:/synthetic/session.jsonl", .done)
        XCTAssertFalse(BubblePresentation.Row(session: pi).canFocusTerminal)
        pi.aionUiConversation = .init(id: "pi_chat", nativeSessionID: pi.id, agentKind: .pi)
        XCTAssertTrue(BubblePresentation.Row(session: pi).canFocusTerminal)
        pi.aionUiConversation = nil
        pi.terminalProgram = "iTerm.app"
        XCTAssertTrue(BubblePresentation.Row(session: pi).canFocusTerminal)
    }
    func testPiSuccessfulCompletionUsesGreenLampAndTurnDurationUntilRead() throws {
        let store = SessionStore()
        func apply(_ state: String, _ offset: Double) -> AgentSession? {
            let time = at.addingTimeInterval(offset)
            var event = AgentEvent(sessionId: "pi:lamp", agentKind: .pi, eventName: state, timestamp: time)
            if state == "done" { event.turnResult = .completed }
            return store.apply(event, now: time)
        }
        let working = try XCTUnwrap(apply("working", 0))
        XCTAssertEqual(BubblePresentation.Row(session: working).lamp, .running)
        let done = try XCTUnwrap(apply("done", 29))
        let row = BubblePresentation.Row(session: done)
        XCTAssertEqual(done.taskResult, .completed)
        XCTAssertEqual(row.lamp, .success)
        XCTAssertTrue(row.dotIsLit)
        XCTAssertTrue(row.dotSpins)
        XCTAssertEqual(row.indicatorLabel, "成功，未读")
        XCTAssertEqual(row.stateLabel, "已完成")
        XCTAssertEqual(row.messageText, "已完成")
        XCTAssertEqual(row.titleText, "Pi · pi:lamp")
        XCTAssertEqual(row.elapsedString(since: row.elapsedStart, now: try XCTUnwrap(done.turnEndedAt)), "29s")
        XCTAssertEqual(row.indicatorRGB.1, 0.77)
        XCTAssertTrue(store.markOpened(done, at: at.addingTimeInterval(30)))
        let read = BubblePresentation.Row(session: try XCTUnwrap(store.session(id: done.id)))
        XCTAssertEqual(read.lamp, .off)
        XCTAssertFalse(read.dotSpins)
        XCTAssertEqual(read.indicatorLabel, "已读，灯已熄灭")
        let next = try XCTUnwrap(apply("working", 40))
        XCTAssertNil(next.taskResult)
        XCTAssertEqual(BubblePresentation.Row(session: next).lamp, .running)
    }
    func testPiWaitingAndUnsuccessfulIdleNeverUseSuccessLamp() throws {
        for state: AgentState in [.registered, .working, .waiting, .idle] {
            let pi = session(.pi, "pi:other", state)
            XCTAssertNil(pi.taskResult)
            XCTAssertNotEqual(BubblePresentation.Row(session: pi).lamp, .success)
        }
        XCTAssertEqual(BubblePresentation.Row(session: session(.pi, "pi:waiting", .waiting)).lamp, .attention)
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionId: "pi:aborted", agentKind: .pi,
            eventName: "working", timestamp: at), now: at)
        let idle = try XCTUnwrap(store.apply(AgentEvent(sessionId: "pi:aborted", agentKind: .pi,
            eventName: "idle", message: "任务已停止", timestamp: at.addingTimeInterval(1)), now: at.addingTimeInterval(1)))
        XCTAssertNil(idle.taskResult)
        XCTAssertEqual(BubblePresentation.Row(session: idle).lamp, .off)
        XCTAssertEqual(BubblePresentation.Row(session: idle).messageText, "任务已停止")
        let unknown = session(.cli, "generic", .done)
        XCTAssertEqual(BubblePresentation.Row(session: unknown).lamp, .unknown)
        let legacy = session(.pi, "pi:legacy", .done)
        XCTAssertEqual(BubblePresentation.Row(session: legacy).lamp, .unknown)
        XCTAssertEqual(BubblePresentation.Row(session: legacy).stateLabel, "结果未知")
        var passive = session(.pi, "passive", .done); passive.source = .passive
        XCTAssertNil(passive.taskResult)
        XCTAssertEqual(BubblePresentation.Row(session: passive).lamp, .unknown)
        var waiting = session(.pi, "pi:waiting-after-done", .waiting)
        waiting.piTurnResult = .completed
        XCTAssertEqual(BubblePresentation.Row(session: waiting).lamp, .attention)
    }
    func testPersistedAOHelperDoesNotBecomeATaskBubbleWhileSameTitleUserTaskRemains() throws {
        var helper = session(.codex, "ao-helper")
        helper.title = "Suggest the single most useful next message..."
        helper.project = NSHomeDirectory() + "/.ao/data/background-tasks/title-123"
        helper.codexHasNativeThreadRecord = true
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(helper))
        var ordinary = session(.codex, "user-task")
        ordinary.title = helper.title
        ordinary.project = "/synthetic/user-project"
        XCTAssertEqual(BubblePresentation.groups([restored, ordinary], settings: .init()).map(\.session.id), [ordinary.id])
        XCTAssertEqual(restored.state, .working)
        XCTAssertEqual(restored.notificationVersion, helper.notificationVersion)
    }

    func testDSHACPBackgroundTitleRowsDoNotRemainAfterTheRealTaskIsRead() throws {
        let observation = DSHObservation(schema: 1, profileID: String(repeating: "a", count: 24),
            hostID: "11111111-1111-4111-8111-111111111111", hostStartedAt: at.addingTimeInterval(-10),
            nativeSessionID: "22222222-2222-4222-8222-222222222222", revision: 2, nativeSeq: 3,
            turn: 1, phase: .done, result: .completed, pending: [], startedAt: at.addingTimeInterval(-1),
            endedAt: at, baseline: false, heartbeat: false, gap: false,
            navigationSocket: "/tmp/agentpet-dsh-502/h-ACP123/nav.sock")
        var actual = session(.dsh, observation.sessionKey, .done)
        actual.dsh = observation; actual.notificationVersion = 1; actual.readThroughVersion = 0
        actual.project = "/synthetic/standalone-workspace"
        func background(_ id: String, suffix: String) -> AgentSession {
            var native = observation; native.nativeSessionID = id
            var helper = session(.dsh, native.sessionKey, .done)
            helper.dsh = native; helper.notificationVersion = 1
            helper.project = NSHomeDirectory() + "/.ao/data/background-tasks/title-" + suffix
            return helper
        }
        let first = background("33333333-3333-4333-8333-333333333333", suffix: "123")
        let second = background("44444444-4444-4444-8444-444444444444", suffix: "456")
        let restored = try JSONDecoder().decode([AgentSession].self, from: JSONEncoder().encode([first, second]))
        for grouping: BubbleSessionGrouping in [.byKind, .allSessions] {
            let settings = BubblePresentation.Configuration(sessionGrouping: grouping, now: at, readResultRetention: .fiveSeconds)
            XCTAssertEqual(BubblePresentation.groups(restored + [actual], settings: settings).map(\.session.id), [actual.id])
            var read = actual
            read.readThroughVersion = 1; read.readAt = at; read.readDisplayRevision = read.displayRevision ?? 0
            let later = BubblePresentation.Configuration(sessionGrouping: grouping, now: at.addingTimeInterval(6), readResultRetention: .fiveSeconds)
            XCTAssertTrue(BubblePresentation.groups(restored + [read], settings: later).isEmpty)
        }
        XCTAssertFalse(BubblePresentation.Row(session: first).canFocusTerminal)
        XCTAssertEqual(restored.map(\.readThroughVersion), [0, 0], "filtering internal helpers never fabricates read receipts")
    }

    func testExitedInternalSuggestionIsExcludedWithoutHidingAnonymousCLI() {
        var internalTask = session(.codex, "internal")
        internalTask.codexInternalTaskKind = "projectSuggestions"
        internalTask.codexInternalTaskExitedAt = at.addingTimeInterval(10)
        let ordinary = session(.codex, "ordinary")
        XCTAssertEqual(BubblePresentation.visible([internalTask, ordinary], settings: .init()).map(\.id), [ordinary.id])
        XCTAssertEqual(BubblePresentation.groups([internalTask, ordinary], settings: .init()).map(\.session.id), [ordinary.id])
        XCTAssertFalse(BubblePresentation.Row(session: internalTask).canFocusTerminal)
        XCTAssertTrue(SessionNotificationPolicy.effects(before: nil, session: internalTask).isEmpty)
        internalTask.state = .done
        XCTAssertTrue(SessionNotificationPolicy.effects(before: .working, session: internalTask).isEmpty)
        internalTask.updatedAt = at.addingTimeInterval(11)
        internalTask.state = .working
        XCTAssertEqual(BubblePresentation.visible([internalTask, ordinary], settings: .init()).count, 2)
    }
    func testOpenCodeChildIsHiddenAndIndependentSameTitleRootRemains() {
        var parent = session(.opencode, "ses_Parent")
        parent.title = "相同标题"
        var child = session(.opencode, "ses_Child", .done)
        child.title = "探索任务 (@explore subagent)"; child.opencodeParentSessionID = parent.id
        var independent = session(.opencode, "ses_Independent")
        independent.title = parent.title
        let rows = BubblePresentation.groups([parent, child, independent], settings: .init())
        XCTAssertEqual(Set(rows.map { $0.session.id }), [parent.id, independent.id])
        var otherKind = child; otherKind.agentKind = .codex; otherKind.state = .working
        XCTAssertEqual(BubblePresentation.visible([otherKind], settings: .init()).count, 1)
    }

    func testAionUiTitleIsExcludedWhileSolAndDeepSeekTeamMembersRemain() {
        var title = session(.codex, "aux-title")
        title.model = "default"
        title.codexInternalTaskKind = "aionUiTitle"
        title.codexInternalTaskObservedAt = at.addingTimeInterval(1)
        var leader = session(.codex, "team-leader")
        leader.model = "gpt-6.1-sol"
        leader.aionUiConversation = .init(id: "aion-leader", nativeSessionID: leader.id, agentKind: .codex)
        var member = session(.opencode, "team-member")
        member.model = "deepseek-v4.1-flash"
        member.aionUiConversation = .init(id: "aion-member", nativeSessionID: member.id, agentKind: .opencode)
        let anonymous = session(.codex, "ordinary-anonymous")
        XCTAssertEqual(Set(BubblePresentation.visible([title, leader, member, anonymous], settings: .init()).map(\.id)),
                       [leader.id, member.id, anonymous.id])
        XCTAssertEqual(Set(BubblePresentation.groups([title, leader, member], settings: .init()).map(\.session.id)),
                       [leader.id, member.id])
        XCTAssertTrue(SessionNotificationPolicy.effects(before: nil, session: title).isEmpty)
        title.state = .done
        XCTAssertTrue(SessionNotificationPolicy.effects(before: .working, session: title).isEmpty)
    }
    func testIndependentNativeSessionsAndCollapsedKindsKeepPriorityAndCount() {
        var input: [AgentSession] = []
        for kind: AgentKind in [.codex, .antigravity, .opencode, .dsh, .claude, .pi] {
            input += [session(kind, kind.rawValue + "1"), session(kind, kind.rawValue + "2", .waiting)]
        }
        let groups = BubblePresentation.groups(input, settings: .init())
        XCTAssertEqual(groups.count, 9)
        for kind: AgentKind in [.codex, .antigravity, .opencode] {
            let rows = groups.filter { $0.session.agentKind == kind }
            XCTAssertEqual(rows.map(\.count), [1, 1])
            XCTAssertEqual(rows.map(\.session.state), [.waiting, .working])
        }
        for kind: AgentKind in [.dsh, .claude, .pi] {
            let rows = groups.filter { $0.session.agentKind == kind }
            XCTAssertEqual(rows.map(\.count), [2])
            XCTAssertEqual(rows.first?.session.state, .waiting)
        }
    }
    func testReadCompletedAndUnreadSurviveStateFilterButNotHiddenKind() {
        var read = session(.codex, "read", .done)
        read.notificationVersion = 1; read.readThroughVersion = 1
        read.readAt = at; read.readDisplayRevision = read.displayRevision ?? 0
        var unread = session(.codex, "unread", .done); unread.notificationVersion = 1
        let idle = session(.codex, "idle", .idle)
        let config = BubblePresentation.Configuration(minStateFilter: .workingOnly)
        XCTAssertEqual(BubblePresentation.visible([read, unread, idle], settings: config).map(\.id), ["read", "unread"])
        var hidden = config; hidden.hiddenKinds = [.codex]
        XCTAssertTrue(BubblePresentation.visible([read, unread], settings: hidden).isEmpty)
    }
    func testCapsDoNotTruncateCarouselOrExpandedAndUnknownNamesStaySeparate() {
        let input = (0..<4).map { session(.claude, "s\($0)") }
        var config = BubblePresentation.Configuration(sessionGrouping: .allSessions, displayMode: .list, maxSessions: 2)
        XCTAssertEqual(BubblePresentation.groups(input, settings: config).count, 2)
        XCTAssertEqual(BubblePresentation.groups(input, settings: config, expanded: true).count, 4)
        config.displayMode = .carousel
        XCTAssertEqual(BubblePresentation.groups(input, settings: config).count, 4)
        var a = session(.unknown, "a"); a.agentName = "foo"
        var b = session(.unknown, "b"); b.agentName = "bar"
        XCTAssertEqual(BubblePresentation.groups([a,b], settings: .init()).count, 2)
    }
    func testRunningReadReceiptStillUsesBlueIndicatorAndFrozenEndUsesSameClock() {
        var s = session(.codex, "s"); s.readAt = at; s.readDisplayRevision = 0
        s.turnStartedAt = at; s.turnEndedAt = at.addingTimeInterval(75)
        let row = BubblePresentation.Row(session: s)
        XCTAssertEqual(s.indicator, .running)
        XCTAssertEqual(row.indicatorRGB.0, 59 / 255.0)
        XCTAssertTrue(row.dotSpins)
        XCTAssertEqual(row.elapsedString(since: row.elapsedStart, now: s.turnEndedAt!), "1m")
    }
    func testRealMessagesIgnoreLegacyCustomOverrides() {
        var s = session(.claude, "s"); s.message = "  activity  "
        XCTAssertEqual(BubblePresentation.Row(session: s, line: { _ in "built-in" }).messageText, "activity")
        XCTAssertEqual(BubblePresentation.Row(session: s, customMessages: true, line: { _ in "custom" }).messageText, "activity")
        s.state = .done
        XCTAssertEqual(BubblePresentation.Row(session: s, line: { _ in "localized" }).messageText, "activity")
        s.agentKind = .opencode
        XCTAssertEqual(BubblePresentation.Row(session: s).messageText, "  activity  ")
        s.state = .waiting; s.message = nil; s.humanRequests = []
        XCTAssertEqual(BubblePresentation.Row(session: s).messageText, "等待你的回复")
    }
    func testReactionVisibilityIndependentOfChatToggleAndMissingPet() {
        XCTAssertTrue(BubblePresentation.hasContent(reaction: "Hi", showChat: false, petID: nil, multiAgent: true, sessions: [], chatLine: "", settings: .init()))
        XCTAssertFalse(BubblePresentation.hasContent(reaction: "", showChat: true, petID: nil, multiAgent: true, sessions: [session(.claude,"s")], chatLine: "Hi", settings: .init()))
    }

    // MARK: - AionUI Teams

    private func teamSession(_ id: String, state: AgentState = .working,
                             role: AionUiConversation.TeamRole?, teamID: String = "team_a",
                             teamName: String? = "Team Alpha", kind: AgentKind = .codex,
                             verifiedAt: Date? = nil) -> AgentSession {
        var value = session(kind, id, state)
        value.aionUiConversation = .init(id: "chat_" + id, nativeSessionID: id, agentKind: kind,
                                         teamID: teamID, teamName: teamName, teamRole: role)
        // A verified role carries the live check the daemon stamps on every
        // successful poll; tests that need a lapsed, earlier-launch or missing
        // check override it.
        if let role {
            value.aionUiVerification = .init(conversationID: "chat_" + id, teamID: teamID, teamRole: role,
                                             sessionCreatedAt: value.createdAt, verifiedAt: verifiedAt ?? at,
                                             launchEpoch: AionUiVerificationLaunch.epoch)
        }
        return value
    }

    func testTeamCollapsesMembersAndFollowsOnlyTheLead() {
        let lead = teamSession("lead", state: .working, role: .lead)
        var mate = teamSession("mate", state: .done, role: .teammate)
        mate.notificationVersion = 5
        let groups = BubblePresentation.groups([lead, mate], settings: .init())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "team-team_a")
        XCTAssertEqual(groups[0].team?.name, "Team Alpha")
        XCTAssertEqual(groups[0].team?.leaderMissing, false)
        XCTAssertEqual(groups[0].session.id, "lead")
        XCTAssertEqual(groups[0].count, 1)
        XCTAssertEqual(BubblePresentation.Row(session: groups[0].session, team: groups[0].team).lamp, .running)
    }

    func testTeamUnknownLeadKeepsNeutralIdentityAndHidesMemberPending() throws {
        var member = teamSession("m1", state: .waiting, role: nil, teamName: nil)
        member.pendingApproval = .init(requestId: "req", toolName: "Bash", summary: "rm -rf")
        let groups = BubblePresentation.groups([member], settings: .init())
        XCTAssertEqual(groups.count, 1)
        let team = try XCTUnwrap(groups[0].team)
        XCTAssertEqual(team.name, "AionUI Team")
        XCTAssertTrue(team.leaderMissing)
        XCTAssertEqual(groups[0].session.id, "m1")
        let row = BubblePresentation.Row(session: groups[0].session, team: team)
        XCTAssertFalse(row.showsPendingApproval)
        XCTAssertFalse(row.isWaitingDisplay)
        XCTAssertEqual(row.lamp, .unknown)
        XCTAssertEqual(row.stateLabel, "主Agent状态未知")
        XCTAssertEqual(row.messageText, "主Agent状态未知")
        XCTAssertEqual(row.indicatorLabel, "主Agent状态未知")
        XCTAssertFalse(row.visibleTokens(BubbleLayout.original).contains { [.model, .project, .elapsed].contains($0.token) })
    }

    func testTeamVerifiedLeadApprovalKeepsTeamIdentity() throws {
        var lead = teamSession("lead2", state: .waiting, role: .lead)
        lead.pendingApproval = .init(requestId: "req2", toolName: "Bash", summary: "deploy")
        let groups = BubblePresentation.groups([lead], settings: .init())
        let team = try XCTUnwrap(groups[0].team)
        let row = BubblePresentation.Row(session: groups[0].session, team: team)
        XCTAssertTrue(row.showsPendingApproval)
        XCTAssertTrue(row.isWaitingDisplay)
    }

    func testUnknownTeamCarrierStaysStableRegardlessOfMemberActivity() {
        let first = BubblePresentation.groups([teamSession("b", state: .done, role: nil),
                                               teamSession("a", state: .working, role: nil)], settings: .init())
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].session.id, "a")   // smallest id, not the busiest member
        var busy = teamSession("a", state: .working, role: nil)
        busy.updatedAt = at.addingTimeInterval(99)
        let second = BubblePresentation.groups([teamSession("b", state: .done, role: nil), busy], settings: .init())
        XCTAssertEqual(second[0].session.id, "a")
    }

    func testTeamSwitchIsIndependentFromKindFiltersAndHidesWholeGroup() {
        let lead = teamSession("lead3", state: .working, role: .lead)
        var hidden = BubblePresentation.Configuration()
        hidden.hiddenKinds = [.codex]
        XCTAssertEqual(BubblePresentation.groups([lead], settings: hidden).count, 1)
        var off = hidden
        off.showAionUiTeams = false
        XCTAssertTrue(BubblePresentation.groups([lead], settings: off).isEmpty)
        let plain = session(.codex, "plain")
        XCTAssertTrue(BubblePresentation.groups([plain], settings: hidden).isEmpty)
        XCTAssertEqual(BubblePresentation.groups([plain], settings: .init()).count, 1)
    }

    func testMultipleTeamsAndOrdinarySessionsRemainSeparate() {
        let a = teamSession("a1", state: .working, role: .lead, teamID: "team_a", teamName: "Alpha")
        let b = teamSession("b1", state: .waiting, role: .lead, teamID: "team_b", teamName: "Beta")
        let groups = BubblePresentation.groups([a, b, session(.claude, "plain")], settings: .init())
        XCTAssertEqual(Set(groups.map(\.id)), ["team-team_a", "team-team_b", "claude-plain"])
    }

    func testTeamDedupeAcrossGroupingAndDisplayModes() {
        let members = [teamSession("m1", state: .working, role: nil), teamSession("m2", state: .done, role: nil)]
        for grouping: BubbleSessionGrouping in [.byKind, .allSessions] {
            for mode: BubbleDisplayMode in [.list, .carousel, .compact] {
                let config = BubblePresentation.Configuration(sessionGrouping: grouping, displayMode: mode)
                let groups = BubblePresentation.groups(members, settings: config)
                XCTAssertEqual(groups.count, 1, "\(grouping)/\(mode)")
                XCTAssertEqual(groups[0].team?.leaderMissing, true, "\(grouping)/\(mode)")
            }
        }
    }

    func testHasContentMatchesTeamRowsAndRetentionExpiry() {
        var lead = teamSession("h1", state: .done, role: .lead)
        lead.codexTurnResult = .completed
        lead.notificationVersion = 1
        lead.displayRevision = 2
        lead.readThroughVersion = 1
        lead.readAt = at
        lead.readDisplayRevision = 2
        let expired = BubblePresentation.Configuration(now: at.addingTimeInterval(3600), readResultRetention: .threeSeconds)
        XCTAssertTrue(BubblePresentation.groups([lead], settings: expired).isEmpty)
        XCTAssertFalse(BubblePresentation.hasContent(reaction: "", showChat: true, petID: "pet", multiAgent: true,
                                                     sessions: [lead], chatLine: "", settings: expired))
        // A *stale* working member (no activity evidence inside the accepted
        // 300 s window) never keeps the read/expired Team alive; a fresh one
        // does, and that case is covered by
        // testFreshMemberWorkingKeepsReadExpiredTeamVisibleAndNotGreen.
        let mate = teamSession("h2", state: .working, role: .teammate)
        XCTAssertFalse(BubblePresentation.hasContent(reaction: "", showChat: true, petID: "pet", multiAgent: true,
                                                     sessions: [lead, mate], chatLine: "", settings: expired))
        let fresh = BubblePresentation.Configuration(now: at, readResultRetention: .threeSeconds)
        XCTAssertTrue(BubblePresentation.hasContent(reaction: "", showChat: true, petID: "pet", multiAgent: true,
                                                    sessions: [lead], chatLine: "", settings: fresh))
    }

    @MainActor
    func testPetEligibilityKeepsOnlyVerifiedLeadAndRespectsSwitch() {
        let lead = teamSession("p-lead", state: .working, role: .lead)
        let mate = teamSession("p-mate", state: .working, role: .teammate)
        let unverified = teamSession("p-unverified", state: .working, role: nil)
        let ordinary = session(.claude, "p-plain")
        XCTAssertEqual(PetController.teamEligible([lead, mate, unverified, ordinary], teamsShown: true).map(\.id),
                       ["p-lead", "p-plain"])
        XCTAssertEqual(PetController.teamEligible([lead, mate, unverified, ordinary], teamsShown: false).map(\.id),
                       ["p-plain"])
    }

    @MainActor
    func testLeaderlessTeamReachesBubbleDisplayWhilePetMoodStaysNeutral() throws {
        let member = teamSession("disp", state: .working, role: nil, teamName: nil)
        let ordinary = session(.claude, "disp-plain", .idle)
        let raw = [member, ordinary]
        // The leader-driven set excludes the leaderless Team: no busy mood.
        let leaders = PetController.teamEligible(raw, teamsShown: true)
        XCTAssertEqual(leaders.map(\.id), [ordinary.id])
        XCTAssertEqual(MoodResolver.aggregate(leaders), .idle)
        // The home window's display projection still carries the member so the
        // neutral Team row reaches the native bubble.
        let planned: Set<String> = [ordinary.id]
        let display = PetController.displayProjection(raw: raw, plannedIDs: planned, defaultWindow: true,
                                                      teamsShown: true)
        XCTAssertEqual(Set(display.map(\.id)), [member.id, ordinary.id])
        let rows = BubblePresentation.groups(display, settings: .init())
        XCTAssertEqual(rows.count, 2)
        let teamRow = try XCTUnwrap(rows.first { $0.team != nil })
        XCTAssertEqual(teamRow.team?.leaderMissing, true)
        XCTAssertEqual(BubblePresentation.Row(session: teamRow.session, team: teamRow.team).lamp, .unknown)
        // Switch off and non-home windows keep the pre-Team behavior.
        XCTAssertEqual(PetController.displayProjection(raw: raw, plannedIDs: planned, defaultWindow: true,
                                                       teamsShown: false).map(\.id), [ordinary.id])
        XCTAssertEqual(PetController.displayProjection(raw: raw, plannedIDs: planned, defaultWindow: false,
                                                       teamsShown: true).map(\.id), [ordinary.id])
        // Every Team member reaches the home window's display list so the
        // collapsed Team row can weigh member activity; an unverified mark
        // still only yields the neutral row. The carrier's identity/timer stay
        // the leader's.
        let lead = teamSession("disp-lead", state: .working, role: .lead)
        XCTAssertEqual(PetController.displayProjection(raw: [member, lead], plannedIDs: [lead.id],
                                                       defaultWindow: true, teamsShown: true).map(\.id),
                       [lead.id, member.id])
    }

    // MARK: - D: member activity in the Team row

    /// A leader whose own turn already ended (read, past retention) but whose
    /// members were verified by the live check.
    private func finishedReadLead(_ id: String = "d-lead", result: CodexTurnResult = .completed) -> AgentSession {
        var lead = teamSession(id, state: .done, role: .lead)
        lead.codexTurnResult = result
        lead.notificationVersion = 1
        lead.readThroughVersion = 1
        // Read long before `at` so the read-result retention has already passed
        // while a member's activity at `at` is still fresh.
        lead.readAt = at.addingTimeInterval(-3600)
        lead.displayRevision = 2
        lead.readDisplayRevision = 2
        return lead
    }

    private var expiredReadLead: BubblePresentation.Configuration {
        BubblePresentation.Configuration(now: at, readResultRetention: .threeSeconds)
    }

    func testFreshMemberWorkingKeepsReadExpiredTeamVisibleAndNotGreen() throws {
        let lead = finishedReadLead()
        let mate = teamSession("d-mate", state: .working, role: .teammate)
        // The leader alone would be evicted: read result past its retention.
        XCTAssertTrue(BubblePresentation.groups([lead], settings: expiredReadLead).isEmpty)
        let groups = BubblePresentation.groups([lead, mate], settings: expiredReadLead)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.id, "team-team_a")
        XCTAssertEqual(group.session.id, lead.id)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.lamp, .running)
        XCTAssertEqual(row.stateLabel, "成员执行中")
        XCTAssertEqual(row.messageText, "成员执行中")
        XCTAssertTrue(BubblePresentation.hasContent(reaction: "", showChat: true, petID: "pet", multiAgent: true,
                                                    sessions: [lead, mate], chatLine: "", settings: expiredReadLead))
    }

    func testLeaderSuccessIsNotPresentedAsTeamSuccessWhileMembersWork() throws {
        var lead = teamSession("d-green", state: .done, role: .lead)
        lead.codexTurnResult = .completed
        lead.notificationVersion = 1
        XCTAssertEqual(BubblePresentation.Row(session: lead).lamp, .success)
        let mate = teamSession("d-mate", state: .working, role: .teammate)
        let groups = BubblePresentation.groups([lead, mate], settings: .init(now: at))
        let group = try XCTUnwrap(groups.first)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.lamp, .running)
        XCTAssertEqual(row.stateLabel, "成员执行中")
        XCTAssertEqual(row.indicatorLabel, "成员执行中")
        // The same Team copy is not rendered twice.
        XCTAssertFalse(row.visibleTokens(BubbleLayout.detailed).map(\.token).contains(.stateLabel))
    }

    func testLeaderTimerAndIdentityAreKeptWhileMembersWork() throws {
        var lead = finishedReadLead()
        lead.turnStartedAt = at.addingTimeInterval(-90)
        lead.stateSince = at.addingTimeInterval(-90)
        let mate = teamSession("d-mate", state: .working, role: .teammate)
        let groups = BubblePresentation.groups([lead, mate], settings: expiredReadLead)
        let group = try XCTUnwrap(groups.first)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.titleText, "Team Alpha")
        XCTAssertEqual(row.elapsedStart, at.addingTimeInterval(-90))
        XCTAssertEqual(row.session.id, lead.id)
    }

    func testStaleUnverifiedOrStoppedMembersNeverKeepTheTeamBusy() {
        let lead = finishedReadLead()
        // Leftover `working` from a stopped host: no activity evidence is recent.
        var stale = teamSession("d-stale", state: .working, role: .teammate)
        stale.updatedAt = at.addingTimeInterval(-3600)
        stale.stateSince = at.addingTimeInterval(-3600)
        XCTAssertTrue(BubblePresentation.groups([lead, stale], settings: expiredReadLead).isEmpty)
        // An unverified mark never counts as member activity.
        let unverified = teamSession("d-unverified", state: .working, role: nil, teamName: nil)
        XCTAssertTrue(BubblePresentation.groups([lead, unverified], settings: expiredReadLead).isEmpty)
        // A cancelled member is not working.
        var cancelled = teamSession("d-cancelled", state: .done, role: .teammate)
        cancelled.codexTurnResult = .cancelled
        XCTAssertTrue(BubblePresentation.groups([lead, cancelled], settings: expiredReadLead).isEmpty)
    }

    func testLeaderApprovalFailureAndCancelOutrankMemberActivity() throws {
        let mate = teamSession("d-mate", state: .working, role: .teammate)
        // Failure keeps its own meaning while members still work.
        var failed = teamSession("d-failed", state: .done, role: .lead)
        failed.codexTurnResult = .failed
        failed.notificationVersion = 1
        let failureGroups = BubblePresentation.groups([failed, mate], settings: .init(now: at))
        let failureGroup = try XCTUnwrap(failureGroups.first)
        XCTAssertEqual(BubblePresentation.Row(session: failureGroup.session, team: failureGroup.team).lamp, .failure)
        // A verified lead's pending approval keeps the approval row.
        var waiting = teamSession("d-waiting", state: .waiting, role: .lead)
        waiting.pendingApproval = .init(requestId: "req", toolName: "Bash", summary: "deploy")
        let approvalGroup = try XCTUnwrap(BubblePresentation.groups([waiting, mate], settings: .init(now: at)).first)
        let row = BubblePresentation.Row(session: approvalGroup.session, team: approvalGroup.team)
        XCTAssertTrue(row.showsPendingApproval)
        XCTAssertTrue(row.isWaitingDisplay)
        XCTAssertEqual(row.lamp, .attention)
        // A cancelled lead keeps its cancel meaning (no member takeover).
        var cancelled = teamSession("d-cancelled-lead", state: .done, role: .lead, kind: .opencode)
        cancelled.opencodeTurnResult = .cancelled
        let cancelledGroup = try XCTUnwrap(BubblePresentation.groups([cancelled, mate], settings: .init(now: at)).first)
        XCTAssertTrue(cancelledGroup.session.isStopped)
        XCTAssertEqual(BubblePresentation.Row(session: cancelledGroup.session, team: cancelledGroup.team).lamp, .off)
        XCTAssertEqual(BubblePresentation.Row(session: cancelledGroup.session, team: cancelledGroup.team).stateLabel,
                       "已停止")
        // The lead's own working state is never rewritten by a member.
        let workingLead = teamSession("d-working", state: .working, role: .lead)
        let group = try XCTUnwrap(BubblePresentation.groups([workingLead, mate], settings: .init(now: at)).first)
        XCTAssertEqual(BubblePresentation.Row(session: group.session, team: group.team).stateLabel, "工作中")
    }

    // MARK: - C: cached Team verification and its lifecycle

    /// A Team association whose live re-check lapsed (role dropped, raw mark
    /// kept) must not present its cached result as current.
    func testClearedTeamVerificationPresentsNeutralUnknownWithoutCachedGreen() throws {
        var lead = teamSession("c-lead", state: .done, role: nil, teamName: "Team Alpha")
        lead.codexTurnResult = .completed
        lead.notificationVersion = 1
        XCTAssertEqual(BubblePresentation.Row(session: lead).lamp, .success, "the cached result alone is green")
        let groups = BubblePresentation.groups([lead], settings: .init(now: at))
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.id, "team-team_a")
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.lamp, .unknown)
        XCTAssertEqual(row.stateLabel, "主Agent状态未知")
        XCTAssertEqual(row.messageText, "主Agent状态未知")
        XCTAssertEqual(row.indicatorLabel, "主Agent状态未知")
        // The neutral copy is not rendered twice, and a lead-less row exposes no
        // carrier model/project/timer.
        let tokens = row.visibleTokens(BubbleLayout.detailed).map(\.token)
        XCTAssertFalse(tokens.contains(.stateLabel))
        XCTAssertFalse(tokens.contains(.model))
        XCTAssertFalse(tokens.contains(.elapsed))
        XCTAssertTrue(tokens.contains(.message))
    }

    /// A read + evicted Team row must not come back just because its cached
    /// verification was dropped.
    func testDroppedVerificationDoesNotReviveAReadEvictedTeamRow() {
        var lead = finishedReadLead("c-revive", result: .completed)
        lead.aionUiConversation = .init(id: "chat_c-revive", nativeSessionID: lead.id, agentKind: .codex,
                                        teamID: "team_a", teamName: "Team Alpha", teamRole: nil)
        XCTAssertTrue(BubblePresentation.groups([lead], settings: expiredReadLead).isEmpty)
        // Still-visible content (unread completion) keeps the neutral row.
        var unread = teamSession("c-unread", state: .done, role: nil)
        unread.codexTurnResult = .completed
        unread.notificationVersion = 1
        XCTAssertEqual(BubblePresentation.groups([unread], settings: expiredReadLead).count, 1)
    }

    /// The same identity heals when its live verification comes back.
    func testRestoredTeamVerificationHealsTheRow() throws {
        var lead = teamSession("c-heal", state: .done, role: nil, teamName: "Team Alpha")
        lead.codexTurnResult = .completed
        lead.notificationVersion = 1
        let unverified = try XCTUnwrap(BubblePresentation.groups([lead], settings: .init(now: at)).first)
        XCTAssertEqual(unverified.team?.leaderMissing, true)
        XCTAssertEqual(BubblePresentation.Row(session: unverified.session, team: unverified.team).stateLabel,
                       "主Agent状态未知")
        // A successful re-check restores the verified role and stamps a fresh
        // check: the row is leader-driven again (still never the team's success).
        lead.aionUiConversation = .init(id: "chat_c-heal", nativeSessionID: lead.id, agentKind: .codex,
                                        teamID: "team_a", teamName: "Team Alpha", teamRole: .lead)
        lead.aionUiVerification = .init(conversationID: "chat_c-heal", teamID: "team_a", teamRole: .lead,
                                        sessionCreatedAt: lead.createdAt, verifiedAt: at,
                                        launchEpoch: AionUiVerificationLaunch.epoch)
        let healed = BubblePresentation.groups([lead], settings: .init(now: at))
        let group = try XCTUnwrap(healed.first)
        XCTAssertEqual(group.team?.leaderMissing, false)
        XCTAssertEqual(group.team?.identityUnconfirmed, false)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.stateLabel, "主Agent回合已完成，团队完成未确认")
        XCTAssertEqual(row.lamp, .unknown)
    }

    /// A Team row never claims the lead's own completion as the Team's, even
    /// when every member is merely idle or already done.
    func testTeamSuccessIsNotPresentedAsTeamCompletionWithoutTeamEvidence() throws {
        var lead = teamSession("c-team-done", state: .done, role: .lead)
        lead.codexTurnResult = .completed
        lead.notificationVersion = 1
        var idleMate = teamSession("c-team-idle", state: .idle, role: .teammate)
        idleMate.updatedAt = at.addingTimeInterval(-3600)
        var doneMate = teamSession("c-team-done-mate", state: .done, role: .teammate)
        doneMate.codexTurnResult = .completed
        // Standing alone the leader's own success is untouched.
        XCTAssertEqual(BubblePresentation.Row(session: lead).lamp, .success)
        for members in [[lead], [lead, idleMate], [lead, idleMate, doneMate]] {
            let group = try XCTUnwrap(BubblePresentation.groups(members, settings: .init(now: at)).first)
            let row = BubblePresentation.Row(session: group.session, team: group.team)
            XCTAssertEqual(row.lamp, .unknown, "members: \(members.count)")
            XCTAssertEqual(row.stateLabel, "主Agent回合已完成，团队完成未确认")
            XCTAssertEqual(row.messageText, "主Agent回合已完成，团队完成未确认")
            XCTAssertEqual(row.indicatorLabel, "主Agent回合已完成，团队完成未确认")
        }
    }

    /// A lapsed or missing live check is stated explicitly, and the cached
    /// result is never presented as the current one.
    func testLapsedTeamVerificationIsExplicitlyUnconfirmed() throws {
        var lead = teamSession("c-lapsed", state: .done, role: .lead)
        lead.codexTurnResult = .completed
        lead.notificationVersion = 1
        // Old cached check: the row keeps the last result but not its currency.
        lead.aionUiVerification = .init(conversationID: "chat_c-lapsed", teamID: "team_a", teamRole: .lead,
                                        sessionCreatedAt: lead.createdAt,
                                        verifiedAt: at.addingTimeInterval(-BubblePresentation.teamVerificationStallWindow - 1),
                                        launchEpoch: AionUiVerificationLaunch.epoch)
        let stale = try XCTUnwrap(BubblePresentation.groups([lead], settings: .init(now: at)).first)
        XCTAssertEqual(stale.team?.identityUnconfirmed, true)
        let staleRow = BubblePresentation.Row(session: stale.session, team: stale.team)
        XCTAssertEqual(staleRow.lamp, .unknown)
        XCTAssertEqual(staleRow.stateLabel, "主Agent已完成，当前无法确认")
        // A failed re-check drops the cached check entirely.
        var dropped = lead
        dropped.aionUiVerification = nil
        let gone = try XCTUnwrap(BubblePresentation.groups([dropped], settings: .init(now: at)).first)
        XCTAssertEqual(gone.team?.identityUnconfirmed, true)
        XCTAssertEqual(BubblePresentation.Row(session: gone.session, team: gone.team).messageText,
                       "主Agent已完成，当前无法确认")
        // A check from an earlier launch is history too, even when seconds old.
        var earlierLaunch = lead
        earlierLaunch.aionUiVerification = .init(conversationID: "chat_c-lapsed", teamID: "team_a", teamRole: .lead,
                                                 sessionCreatedAt: lead.createdAt, verifiedAt: at,
                                                 launchEpoch: "previous-launch")
        XCTAssertEqual(BubblePresentation.groups([earlierLaunch], settings: .init(now: at)).first?.team?.identityUnconfirmed,
                       true)
        // A recreated session (same id, different createdAt) cannot inherit it.
        var recreated = lead
        recreated.createdAt = at.addingTimeInterval(5)
        XCTAssertNil(recreated.attestableAionUiVerification)
        // A changed role invalidates it too.
        var promoted = lead
        promoted.aionUiConversation = .init(id: "chat_c-lapsed", nativeSessionID: lead.id, agentKind: .codex,
                                            teamID: "team_a", teamName: "Team Alpha", teamRole: .teammate)
        XCTAssertNil(promoted.attestableAionUiVerification)
        // Neither a lapsed check nor member activity can keep a busy Team.
        var member = teamSession("c-lapsed-mate", state: .working, role: .teammate)
        member.aionUiVerification = nil
        var read = finishedReadLead("c-lapsed-read")
        read.aionUiVerification = nil
        XCTAssertTrue(BubblePresentation.groups([read, member], settings: expiredReadLead).isEmpty)
    }

    /// Every lead state says "current state unconfirmed" on a lapsed check,
    /// while approval, failure and cancellation keep their own meaning.
    func testUnconfirmedTeamRowSaysSoAcrossEveryState() throws {
        func unconfirmed(_ id: String, _ state: AgentState, human: Bool = false,
                         result: CodexTurnResult? = nil, kind: AgentKind = .codex) -> AgentSession {
            var lead = teamSession(id, state: state, role: .lead, kind: kind)
            lead.codexTurnResult = kind == .codex ? result : nil
            if kind == .opencode { lead.opencodeTurnResult = result }
            if human { lead.humanRequests = [.init(id: id + "-req", kind: .reply, createdAt: at)] }
            if state == .done || state == .working { lead.notificationVersion = 1 }
            lead.aionUiVerification = nil
            return lead
        }
        let cases: [(String, AgentSession, BubblePresentation.Row.Lamp, String)] = [
            ("working", unconfirmed("u-work", .working), .unknown, "工作中，当前无法确认"),
            ("waiting", unconfirmed("u-wait", .waiting, human: true), .attention, "等待中，当前无法确认"),
            ("failed", unconfirmed("u-fail", .done, result: .failed), .failure, "失败，当前无法确认"),
            // A cancelled codex lead is never displayed at all (its own
            // cancellation already acknowledged it), so a non-codex lead is
            // used to exercise the row.
            ("cancelled", unconfirmed("u-stop", .done, result: .cancelled, kind: .opencode), .off, "已停止，当前无法确认"),
            ("completed", unconfirmed("u-done", .done, result: .completed), .unknown, "主Agent已完成，当前无法确认"),
            // A no-result pi turn already says "结果未知" on its own.
            ("noResult", unconfirmed("u-nil", .done, kind: .pi), .unknown, "结果未知，当前无法确认"),
            ("idle", unconfirmed("u-idle", .idle, kind: .opencode), .off, "空闲，当前无法确认"),
            ("registered", unconfirmed("u-reg", .registered), .unknown, "已连接，当前无法确认"),
        ]
        for (name, lead, lamp, label) in cases {
            let group = try XCTUnwrap(BubblePresentation.groups([lead], settings: .init(now: at)).first,
                                      "\(name) must stay visible")
            let row = BubblePresentation.Row(session: group.session, team: group.team)
            XCTAssertEqual(row.lamp, lamp, name)
            XCTAssertEqual(row.stateLabel, label, name)
            XCTAssertEqual(row.indicatorLabel, label, name)
            XCTAssertEqual(row.messageText, label, name)
            // The lead's own real state is never rewritten, only not presented
            // as current.
            XCTAssertEqual(group.session.state, lead.state, name)
            XCTAssertEqual(group.session.taskResult, lead.taskResult, name)
        }
        // A fresh verified member outranks the lead's unconfirmed state.
        var member = teamSession("u-mate", state: .working, role: .teammate)
        member.updatedAt = at
        let withMember = try XCTUnwrap(BubblePresentation.groups([unconfirmed("u-work2", .working), member],
                                                                 settings: .init(now: at)).first)
        let memberRow = BubblePresentation.Row(session: withMember.session, team: withMember.team)
        XCTAssertEqual(memberRow.lamp, .running)
        XCTAssertEqual(memberRow.stateLabel, "成员执行中")
        // A lead-less Team with fresh member activity states both.
        let leaderless = try XCTUnwrap(BubblePresentation.groups([member], settings: .init(now: at)).first)
        let leaderlessRow = BubblePresentation.Row(session: leaderless.session, team: leaderless.team)
        XCTAssertEqual(leaderlessRow.lamp, .running)
        XCTAssertEqual(leaderlessRow.stateLabel, "主Agent状态未知，成员执行中")
    }

    /// A lead that only claims `working` without fresh native activity is not
    /// presented as current work; nothing is timed out, failed or cleaned.
    func testStaleLeadWorkingActivityIsNotPresentedAsCurrentWork() throws {
        var lead = teamSession("u-stale-lead", state: .working, role: .lead)
        lead.updatedAt = at.addingTimeInterval(-BubblePresentation.teamMemberActivityWindow - 1)
        lead.stateSince = lead.updatedAt
        let group = try XCTUnwrap(BubblePresentation.groups([lead], settings: .init(now: at)).first)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(group.session.state, .working, "the raw session is never rewritten")
        XCTAssertEqual(group.team?.activityUnconfirmed, true)
        XCTAssertEqual(row.lamp, .unknown)
        XCTAssertEqual(row.stateLabel, "主Agent活动未确认")
        XCTAssertFalse(row.dotSpins == false)   // neutral lamp, not off: still visible
        // A fresh member keeps the row and shows real member activity instead.
        var member = teamSession("u-stale-mate", state: .working, role: .teammate)
        member.updatedAt = at
        let withMember = try XCTUnwrap(BubblePresentation.groups([lead, member], settings: .init(now: at)).first)
        let memberRow = BubblePresentation.Row(session: withMember.session, team: withMember.team)
        XCTAssertEqual(memberRow.lamp, .running)
        XCTAssertEqual(memberRow.stateLabel, "成员执行中")
        // A fresh verified lead still shows its own running state.
        var fresh = teamSession("u-fresh-lead", state: .working, role: .lead)
        fresh.updatedAt = at
        fresh.stateSince = at
        let freshRow = try XCTUnwrap(BubblePresentation.groups([fresh], settings: .init(now: at)).first)
        XCTAssertEqual(BubblePresentation.Row(session: freshRow.session, team: freshRow.team).stateLabel, "工作中")
        XCTAssertEqual(BubblePresentation.Row(session: freshRow.session, team: freshRow.team).lamp, .running)
    }

    // MARK: - Team lamp colours (colour closeout)

    private let purpleRGB = (0x8B / 255.0, 0x5C / 255.0, 0xF6 / 255.0)
    private let grayRGB = (0x6B / 255.0, 0x72 / 255.0, 0x80 / 255.0)
    private let redRGB = (0xEF / 255.0, 0x44 / 255.0, 0x44 / 255.0)
    private let blueRGB = (0x3B / 255.0, 0x82 / 255.0, 0xF6 / 255.0)

    private func assertSameColor(_ actual: (Double, Double, Double), _ expected: (Double, Double, Double),
                                 accuracy: Double = 0.0001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.0, expected.0, accuracy: accuracy, "red channel", file: file, line: line)
        XCTAssertEqual(actual.1, expected.1, accuracy: accuracy, "green channel", file: file, line: line)
        XCTAssertEqual(actual.2, expected.2, accuracy: accuracy, "blue channel", file: file, line: line)
    }

    /// A Team row that cannot confirm the Team's completion is purple (unread,
    /// lit, breathing), deliberately distinct from both failure red and the
    /// read/off gray; real failure, running, approval and ordinary-row colours
    /// are untouched.
    func testTeamUnconfirmedLampUsesPurpleDistinctFromReadOffAndFailure() throws {
        // Team completion withheld: unknown + purple + still lit/spinning.
        var done = teamSession("color-done", state: .done, role: .lead)
        done.codexTurnResult = .completed
        done.notificationVersion = 1
        let doneGroup = try XCTUnwrap(BubblePresentation.groups([done], settings: .init(now: at)).first)
        let doneRow = BubblePresentation.Row(session: doneGroup.session, team: doneGroup.team)
        XCTAssertEqual(doneRow.lamp, .unknown)
        assertSameColor(doneRow.indicatorRGB, purpleRGB)
        XCTAssertTrue(doneRow.dotIsLit)
        XCTAssertTrue(doneRow.dotSpins)

        // Identity confirmation lapsed: the same unconfirmed colour.
        var lapsed = done
        lapsed.aionUiVerification = nil
        let lapsedGroup = try XCTUnwrap(BubblePresentation.groups([lapsed], settings: .init(now: at)).first)
        let lapsedRow = BubblePresentation.Row(session: lapsedGroup.session, team: lapsedGroup.team)
        XCTAssertEqual(lapsedRow.lamp, .unknown)
        assertSameColor(lapsedRow.indicatorRGB, purpleRGB)
        XCTAssertTrue(lapsedRow.dotIsLit)

        // An acknowledged Team row goes dark *and* changes colour: an unread
        // unconfirmed Team must never look like a read one.
        var readDone = done
        readDone.readThroughVersion = readDone.notificationVersion
        readDone.readAt = at
        readDone.readDisplayRevision = readDone.displayRevision ?? 0
        let readGroup = try XCTUnwrap(BubblePresentation.groups([readDone], settings: .init(now: at)).first)
        let readRow = BubblePresentation.Row(session: readGroup.session, team: readGroup.team)
        XCTAssertEqual(readRow.lamp, .off)
        XCTAssertFalse(readRow.dotIsLit)
        assertSameColor(readRow.indicatorRGB, grayRGB)
        XCTAssertNotEqual(readRow.indicatorRGB.0, doneRow.indicatorRGB.0,
                          "unconfirmed Team must not share the read/off colour")
        XCTAssertNotEqual(readRow.indicatorRGB.2, doneRow.indicatorRGB.2,
                          "unconfirmed Team must not share the read/off colour")

        // A real Team failure is still red.
        var failed = teamSession("color-failed", state: .done, role: .lead)
        failed.codexTurnResult = .failed
        failed.notificationVersion = 1
        let failedGroup = try XCTUnwrap(BubblePresentation.groups([failed], settings: .init(now: at)).first)
        let failedRow = BubblePresentation.Row(session: failedGroup.session, team: failedGroup.team)
        XCTAssertEqual(failedRow.lamp, .failure)
        assertSameColor(failedRow.indicatorRGB, redRGB)
        XCTAssertNotEqual(failedRow.indicatorRGB.0, doneRow.indicatorRGB.0,
                          "failure must stay distinct from unconfirmed")

        // Fresh verified member activity stays blue.
        let member = teamSession("color-mate", state: .working, role: .teammate)
        let readLead = finishedReadLead("color-read")
        let runningGroup = try XCTUnwrap(BubblePresentation.groups([readLead, member],
                                                                   settings: expiredReadLead).first)
        let runningRow = BubblePresentation.Row(session: runningGroup.session, team: runningGroup.team)
        XCTAssertEqual(runningRow.lamp, .running)
        assertSameColor(runningRow.indicatorRGB, blueRGB)
        XCTAssertEqual(runningRow.stateLabel, "成员执行中")

        // A verified lead's own approval keeps the amber attention lamp.
        var waiting = teamSession("color-wait", state: .waiting, role: .lead)
        waiting.pendingApproval = .init(requestId: "color-req", toolName: "Bash", summary: "deploy")
        let waitingGroup = try XCTUnwrap(BubblePresentation.groups([waiting], settings: .init(now: at)).first)
        let waitingRow = BubblePresentation.Row(session: waitingGroup.session, team: waitingGroup.team)
        XCTAssertEqual(waitingRow.lamp, .attention)
        assertSameColor(waitingRow.indicatorRGB, (0xF5 / 255.0, 0x9E / 255.0, 0x0B / 255.0))

        // Ordinary rows keep the existing colours: unknown stays red, success green.
        var plainUnknown = session(.codex, "color-plain-unknown", .done)
        plainUnknown.notificationVersion = 1
        XCTAssertEqual(BubblePresentation.Row(session: plainUnknown).lamp, .unknown)
        assertSameColor(BubblePresentation.Row(session: plainUnknown).indicatorRGB, redRGB)
        var plainSuccess = session(.codex, "color-plain-success", .done)
        plainSuccess.codexTurnResult = .completed
        plainSuccess.notificationVersion = 1
        XCTAssertEqual(BubblePresentation.Row(session: plainSuccess).lamp, .success)
        assertSameColor(BubblePresentation.Row(session: plainSuccess).indicatorRGB, (0.13, 0.77, 0.37))
    }

    /// The elapsed timer of a Team row is visibly the lead's.
    func testTeamElapsedLabelNamesTheLeaderTimer() throws {
        let lead = teamSession("c-timer", state: .working, role: .lead)
        let mate = teamSession("c-timer-mate", state: .working, role: .teammate)
        let group = try XCTUnwrap(BubblePresentation.groups([lead, mate], settings: .init(now: at)).first)
        let row = BubblePresentation.Row(session: group.session, team: group.team)
        XCTAssertEqual(row.elapsedText(since: at.addingTimeInterval(-90), now: at), "主Agent计时 1m")
        XCTAssertEqual(BubblePresentation.Row(session: lead).elapsedText(since: at.addingTimeInterval(-90), now: at),
                       "1m")
    }

    /// Members entering the display list must not drive mood, speech or
    /// approval: those stay leader-driven.
    @MainActor
    func testTeamMembersInTheDisplayListDriveNeitherSpeechNorMemberApproval() throws {
        var lead = teamSession("v-lead", state: .working, role: .lead)
        lead.codexTurnID = "t"
        var member = teamSession("v-mate", state: .waiting, role: .teammate)
        member.codexTurnID = "t"
        member.pendingApproval = .init(requestId: "req", toolName: "Bash", summary: "member-only")
        member.humanRequests = [.init(id: "member-req", kind: .choice, createdAt: at)]
        let display = PetController.displayProjection(raw: [lead, member], plannedIDs: [lead.id],
                                                      defaultWindow: true, teamsShown: true)
        XCTAssertEqual(Set(display.map(\.id)), [lead.id, member.id])
        // Speech stays leader-driven: the member contributes nothing.
        var speech = PetSpeechState(globalCooldown: 0)
        func candidate(_ session: AgentSession) -> PetSpeechState.Candidate {
            .init(fence: .init(session, turnID: "t"), itemID: "one",
                  timestamp: at, revision: 0, content: .snapshot("text"))
        }
        speech.receive(candidate(member), session: member, now: at)
        speech.receive(candidate(lead), session: lead, now: at)
        XCTAssertEqual(speech.visible(sessions: display, hiddenKinds: [], showTeams: true, now: at).map(\.session.id),
                       [lead.id])
        XCTAssertEqual(speech.visible(sessions: display, hiddenKinds: [], showTeams: false, now: at).count, 0)
        // The collapsed Team row never surfaces a member's approval.
        let group = try XCTUnwrap(BubblePresentation.groups(display, settings: .init(now: at)).first { $0.team != nil })
        XCTAssertEqual(group.session.id, lead.id)
        XCTAssertFalse(BubblePresentation.Row(session: group.session, team: group.team).showsPendingApproval)
        // Member activity never moves pet eligibility, which stays leader-driven.
        XCTAssertEqual(PetController.teamEligible([lead, member], teamsShown: true).map(\.id), [lead.id])
    }

    func testTeamMembersReachTheBubbleDisplayProjection() {
        let lead = teamSession("d-proj-lead", state: .done, role: .lead)
        let mate = teamSession("d-proj-mate", state: .working, role: .teammate)
        let unverified = teamSession("d-proj-unverified", state: .working, role: nil, teamName: nil)
        let ordinary = session(.claude, "d-proj-plain")
        let display = PetController.displayProjection(raw: [lead, mate, unverified, ordinary],
                                                      plannedIDs: [lead.id, ordinary.id], defaultWindow: true,
                                                      teamsShown: true)
        XCTAssertEqual(Set(display.map(\.id)), [lead.id, mate.id, unverified.id, ordinary.id])
        // The members collapse into the single leader-driven Team row.
        let teams = BubblePresentation.groups(display, settings: .init(now: at)).filter { $0.team != nil }
        XCTAssertEqual(teams.count, 1)
        XCTAssertEqual(teams.first?.session.id, lead.id)
    }
}
