import XCTest
@testable import AgentPetCore
@testable import agentpet

final class PetSpeechStateTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_000)
    private func session(_ id: String = "s", kind: AgentKind = .codex) -> AgentSession {
        var value = AgentSession(id: id, agentKind: kind, state: .working, source: .hook, updatedAt: at)
        value.createdAt = at; value.codexTurnID = "t"; value.opencodeTurnID = kind == .opencode ? "t" : nil; value.turnStartedAt = at
        if kind == .antigravity { value.antigravityStepFloor = 0 }
        if kind == .dsh {
            value.dsh = DSHObservation(schema: 1, profileID: String(repeating: "a", count: 24),
                hostID: "11111111-1111-4111-8111-111111111111", hostStartedAt: at.addingTimeInterval(-1),
                nativeSessionID: id, revision: 1, nativeSeq: 1, turn: 1, phase: .working,
                result: nil, pending: [], startedAt: at, endedAt: nil,
                baseline: false, heartbeat: false, gap: false, navigationSocket: nil)
        }
        return value
    }
    private func candidate(_ session: AgentSession, item: String = "one", time: Double = 0,
                           revision: Int = 0, content: PetSpeechState.Candidate.Content = .snapshot("正在检查窗口")) -> PetSpeechState.Candidate {
        .init(fence: .init(session, turnID: session.agentKind == .dsh ? "1" : "t"), itemID: item, timestamp: at.addingTimeInterval(time), revision: revision, content: content)
    }
    func testConfiguredDurationPreservesExistingDeadlineAndSurvivesClear() {
        var state = PetSpeechState(duration: 8)
        let s = session()
        state.receive(candidate(s), session: s, now: at)
        XCTAssertEqual(state.rows.first?.expiresAt, at.addingTimeInterval(8))
        state.setDuration(3)
        state.receive(candidate(s, time: 1, revision: 1, content: .snapshot("更新")), session: s, now: at.addingTimeInterval(1))
        XCTAssertEqual(state.rows.first?.expiresAt, at.addingTimeInterval(8))
        state.clear()
        state.receive(candidate(s, time: 9, revision: 2), session: s, now: at.addingTimeInterval(9))
        XCTAssertEqual(state.rows.first?.expiresAt, at.addingTimeInterval(12))
    }
    func testSeventhPushesOldestAndSameSessionCannotOccupyMultipleSlots() {
        var state = PetSpeechState(globalCooldown: 0)
        let sessions = (0..<8).map { session("s\($0)") }
        for value in sessions { state.receive(candidate(value), session: value, now: at) }
        XCTAssertEqual(state.rows.count, 6)
        XCTAssertEqual(state.rows.map(\.session.id), Array(sessions.suffix(6).map(\.id)))
        let s = sessions.last!
        state.receive(candidate(s, item: "next", time: 2), session: s, now: at.addingTimeInterval(2))
        XCTAssertEqual(state.rows.filter { $0.session.id == s.id }.count, 1)
        XCTAssertEqual(state.rows.last?.label, "@Codex[8]")
    }
    func testUpdatesKeepStableIDAndOriginalDeadlineAndDoNotResurrect() {
        var state = PetSpeechState(); let s = session()
        state.receive(candidate(s, content: .snapshot("第一版")), session: s, now: at)
        let original = state.rows[0]
        state.receive(candidate(s, time: 1, revision: 1, content: .delta("补充")), session: s, now: at.addingTimeInterval(1))
        XCTAssertEqual(state.rows[0].text, "第一版")
        state.advance(now: at.addingTimeInterval(2))
        XCTAssertEqual(state.rows[0].text, "第一版补充")
        XCTAssertEqual(state.rows[0].id, original.id)
        XCTAssertEqual(state.rows[0].expiresAt, at.addingTimeInterval(5))
        state.advance(now: at.addingTimeInterval(4.99))
        XCTAssertFalse(state.rows.isEmpty)
        state.advance(now: at.addingTimeInterval(5))
        XCTAssertTrue(state.rows.isEmpty)
        state.receive(candidate(s, time: 6, revision: 2), session: s, now: at.addingTimeInterval(6))
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertNil(state.nextExpiry)
    }
    func testSnapshotReplacesDeltaAndDuplicatesOrOlderVersionsCannotOverwrite() {
        var state = PetSpeechState(); let s = session()
        state.receive(candidate(s, content: .delta("without baseline")), session: s, now: at)
        XCTAssertTrue(state.rows.isEmpty)
        state.receive(candidate(s, content: .snapshot("甲")), session: s, now: at)
        state.receive(candidate(s, revision: 1, content: .delta("乙")), session: s, now: at)
        state.receive(candidate(s, revision: 2, content: .snapshot("甲乙丙")), session: s, now: at)
        state.receive(candidate(s, revision: 1, content: .delta("乙")), session: s, now: at)
        state.advance(now: at.addingTimeInterval(2))
        XCTAssertEqual(state.rows.first?.text, "甲乙丙")
    }
    func testWhitespaceDeltaAndNumberSurviveTurnChange() {
        var state = PetSpeechState(); let s = session()
        state.receive(candidate(s, content: .snapshot("hello")), session: s, now: at)
        state.receive(candidate(s, revision: 1, content: .delta(" ")), session: s, now: at)
        state.receive(candidate(s, revision: 2, content: .delta("world")), session: s, now: at)
        state.advance(now: at.addingTimeInterval(2))
        XCTAssertEqual(state.rows.first?.text, "hello world")
        let label = state.rows.first?.label
        var next = s; next.codexTurnID = "next"; next.turnStartedAt = at.addingTimeInterval(4)
        state.reconcile([next], now: at.addingTimeInterval(4))
        let message = PetSpeechState.Candidate(fence: .init(next, turnID: "next"), itemID: "new-turn",
            timestamp: at.addingTimeInterval(4), revision: 0, content: .snapshot("new turn"))
        state.receive(message, session: next, now: at.addingTimeInterval(4))
        XCTAssertEqual(state.rows.first?.label, label)
    }

    func testGlobalPacingAndRotationAcrossEightBusySources() {
        var state = PetSpeechState()
        let kinds: [AgentKind] = [.codex, .opencode, .antigravity, .dsh, .gemini, .claude, .pi, .cli]
        let sessions = kinds.enumerated().map { session("s\($0.offset)", kind: $0.element) }
        var seen = Set<String>()
        for tick in 0..<100 {
            let t = Double(tick) / 10
            for s in sessions { state.receive(candidate(s, item: "\(tick)", time: t), session: s, now: at.addingTimeInterval(t)) }
            state.advance(now: at.addingTimeInterval(t))
            seen.formUnion(state.rows.map(\.session.id))
            XCTAssertLessThanOrEqual(state.rows.count, 6)
            XCTAssertEqual(Set(state.rows.map(\.session)).count, state.rows.count)
        }
        XCTAssertEqual(seen.count, 8)
        state.advance(now: at.addingTimeInterval(20))
        XCTAssertTrue(state.rows.isEmpty); XCTAssertNil(state.nextExpiry)
    }
    func testImportantEightSecondsDropsOrdinaryTrafficAndDoesNotReplay() {
        var state = PetSpeechState(); let s = session()
        state.receive(candidate(s), session: s, now: at)
        state.beginImportant(now: at)
        XCTAssertEqual(state.nextExpiry, at.addingTimeInterval(8)); XCTAssertTrue(state.rows.isEmpty)
        state.receive(candidate(s, item: "hidden", time: 7), session: s, now: at.addingTimeInterval(7))
        state.advance(now: at.addingTimeInterval(7.99)); XCTAssertNotNil(state.importantUntil)
        state.advance(now: at.addingTimeInterval(8)); XCTAssertNil(state.importantUntil)
        XCTAssertTrue(state.rows.isEmpty); XCTAssertNil(state.nextExpiry)
        state.receive(candidate(s, item: "hidden", time: 8.1, revision: 1), session: s, now: at.addingTimeInterval(8.1))
        XCTAssertTrue(state.rows.isEmpty, "Revisions of a suppressed item cannot replay after a notice")
        state.receive(candidate(s, item: "new", time: 8.2), session: s, now: at.addingTimeInterval(8.2))
        XCTAssertEqual(state.rows.first?.itemID, "new")
    }
    func testVisibleTimeNoticeConsumesSuppressedRevisionsWithoutLateCooldown() {
        for elapsed: Double in [5, 30] {
            var state = PetSpeechState(); let s = session()
            state.beginImportant(now: at, controlled: true)
            XCTAssertNil(state.nextExpiry, "The system notice, not a second timer, owns expiry")
            state.receive(candidate(s, item: "suppressed", time: elapsed - 1), session: s, now: at.addingTimeInterval(elapsed - 1))
            state.advance(now: at.addingTimeInterval(elapsed))
            XCTAssertTrue(state.rows.isEmpty)
            state.endImportant(now: at.addingTimeInterval(elapsed))
            state.receive(candidate(s, item: "suppressed", time: elapsed + 0.1, revision: 1), session: s, now: at.addingTimeInterval(elapsed + 0.1))
            XCTAssertTrue(state.rows.isEmpty, "A revision of an item consumed during the notice cannot replay")
            state.receive(candidate(s, item: "fresh", time: elapsed + 0.2), session: s, now: at.addingTimeInterval(elapsed + 0.2))
            XCTAssertEqual(state.rows.first?.itemID, "fresh", "Fresh messages resume as soon as the notice ends")
        }
    }
    func testExactBirthTurnGenerationCancelAndSourceFilters() {
        var state = PetSpeechState(); let s = session()
        state.receive(candidate(s), session: s, now: at)
        XCTAssertTrue(state.visible(sessions: [s], hiddenKinds: [.codex], now: at).isEmpty)
        var next = s; next.createdAt = at.addingTimeInterval(1)
        XCTAssertTrue(state.visible(sessions: [next], hiddenKinds: [], now: at).isEmpty)
        next = s; next.codexTurnID = "new"
        state.reconcile([next], now: at); XCTAssertTrue(state.rows.isEmpty)
        state.receive(candidate(s), session: next, now: at); XCTAssertTrue(state.rows.isEmpty)
        state.receive(candidate(s), session: s, now: at)
        next = s; next.interactionGeneration = 2
        state.reconcile([next], now: at); XCTAssertTrue(state.rows.isEmpty)
        state.receive(candidate(s), session: s, now: at)
        next = s; next.codexTurnResult = .cancelled
        state.reconcile([next], now: at); XCTAssertNil(state.nextExpiry)
    }
    func testStaleFutureRecordsBoundsAndClear() {
        var state = PetSpeechState(globalCooldown: 0); let s = session()
        state.receive(candidate(s, time: -1), session: s, now: at)
        state.receive(candidate(s, time: 3), session: s, now: at)
        state.receive(candidate(s), session: s, now: at.addingTimeInterval(5))
        XCTAssertTrue(state.rows.isEmpty)
        state.receive(candidate(s, content: .snapshot("   ")), session: s, now: at)
        XCTAssertTrue(state.rows.isEmpty, "Whitespace cannot create a label-only card")
        state.clear()
        for i in 0..<150 {
            let current = session("\(i)")
            state.receive(candidate(current, content: .snapshot(String(repeating: "鲸", count: 2000))), session: current, now: at)
        }
        XCTAssertEqual(state.channelCount, 128)
        XCTAssertTrue(state.rows.allSatisfy { $0.text.count == 20 })
        state.clear(); XCTAssertNil(state.nextExpiry); XCTAssertEqual(state.channelCount, 0)
    }
    func testCodexNativeClockFallbackAndTwentyVisibleCharacters() throws {
        var s = session(); s.codexTurnID = nil; s.codexLifecycleAt = at; s.turnStartedAt = at.addingTimeInterval(0.08)
        s.interactionGeneration = 7
        func message(_ start: Date) throws -> CodexVisibleMessage {
            let data = try JSONSerialization.data(withJSONObject: ["type": "response_item", "timestamp": at.addingTimeInterval(1).timeIntervalSince1970,
                "payload": ["type": "message", "role": "assistant", "phase": "commentary", "content": [["type": "output_text", "text": "正在检查主题。接下来修改窗口。"]]]])
            return try XCTUnwrap(CodexVisibleMessage.parse(data, turnID: "t", turnStartedAt: start))
        }
        var state = PetSpeechState()
        state.receive(try message(at.addingTimeInterval(-1)), session: s, now: at.addingTimeInterval(2))
        XCTAssertTrue(state.rows.isEmpty)
        state.receive(try message(at), session: s, now: at.addingTimeInterval(2))
        XCTAssertEqual(state.rows.first?.text, "正在检查主题。接下来修改窗口。")
        XCTAssertEqual(state.rows.first?.label, "@Codex[1]")
        XCTAssertEqual(PetSpeechState.compactText(String(repeating: "👨‍👩‍👧‍👦", count: 25)).count, 20)
    }
    func testShortOpeningDoesNotHideFollowingContentAndTwentyCharacterBudgetIncludesEllipsis() {
        XCTAssertEqual(PetSpeechState.compactText("好的。正在核对窗口布局。"), "好的。正在核对窗口布局。")
        XCTAssertEqual(PetSpeechState.compactText("完成！\n正在检查下一项。"), "完成！ 正在检查下一项。")
        let exact = "好的。" + String(repeating: "甲", count: 17)
        XCTAssertEqual(PetSpeechState.compactText(exact), exact)
        XCTAssertEqual(PetSpeechState.compactText(exact + "乙"), String(exact.prefix(19)) + "…")
        XCTAssertEqual(PetSpeechState.compactText("\u{0000}好的。\t继续检查。"), "好的。 继续检查。")
    }

    func testUnverifiedTeamMemberStaysSilentWhileVerifiedLeadSpeaks() {
        var member = session("member")
        member.aionUiConversation = .init(id: "chat_member", nativeSessionID: member.id,
                                          agentKind: .codex, teamID: "team_a")
        var state = PetSpeechState(globalCooldown: 0)
        state.receive(candidate(member, content: .snapshot("成员活动中")), session: member, now: at)
        XCTAssertEqual(state.rows.count, 1)
        // A Team mark that is not yet verified must never fall back to the
        // ordinary per-kind filter and leak member speech.
        XCTAssertTrue(state.visible(sessions: [member], hiddenKinds: [], showTeams: true, now: at).isEmpty)
        XCTAssertTrue(state.visible(sessions: [member], hiddenKinds: [], showTeams: true,
                                    now: at.addingTimeInterval(0.1)).isEmpty)
        var lead = session("lead")
        lead.aionUiConversation = .init(id: "chat_lead", nativeSessionID: lead.id, agentKind: .codex,
                                        teamID: "team_a", teamName: "Team Alpha", teamRole: .lead)
        state.receive(candidate(lead, item: "lead-item"), session: lead, now: at)
        XCTAssertEqual(state.visible(sessions: [member, lead], hiddenKinds: [], showTeams: true, now: at).map(\.session.id),
                       ["lead"])
        XCTAssertTrue(state.visible(sessions: [member, lead], hiddenKinds: [], showTeams: false, now: at).isEmpty)
    }
}
