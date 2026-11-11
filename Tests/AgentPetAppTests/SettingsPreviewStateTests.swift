import XCTest
import AgentPetCore
@testable import agentpet

final class SettingsPreviewStateTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_000)

    func testNativeResultFixturesUseCurrentLampsAndFreezeElapsedForEverySource() throws {
        for kind: AgentKind in [.codex, .antigravity, .opencode, .dsh, .claude, .pi] {
            for status: SettingsPreviewState.Status in [.completed, .failed, .stopped] {
                var preview = SettingsPreviewState()
                let id = try XCTUnwrap(preview.add(kind, now: at))
                preview.setStatus(status, id: id, now: at.addingTimeInterval(12))
                let session = try XCTUnwrap(preview.sessions.first)
                XCTAssertEqual(session.taskResult, status.result, "\(kind)")
                XCTAssertEqual(session.turnStartedAt, at)
                XCTAssertEqual(session.turnEndedAt, at.addingTimeInterval(12))
                let row = BubblePresentation.Row(session: session)
                XCTAssertEqual(row.lamp, status == .completed ? .success : status == .failed ? .failure : .off)
                // Claude/Pi retain the production legacy state clock; this
                // preview must not imply that their partial adapter was upgraded.
                XCTAssertEqual(row.elapsedString(since: row.elapsedStart, now: session.turnEndedAt!),
                               row.usesTaskDetails ? "12s" : "0s")
                if kind == .dsh { XCTAssertEqual(session.dsh?.valid, true) }
            }
        }
    }

    func testUnreadCompletionRemainsUntilReadThenUsesSelectedRetention() throws {
        var preview = SettingsPreviewState()
        let id = try XCTUnwrap(preview.add(.codex, now: at))
        preview.setStatus(.completed, id: id, now: at.addingTimeInterval(1))
        var config = BubblePresentation.Configuration(now: at.addingTimeInterval(100), readResultRetention: .threeSeconds)
        XCTAssertEqual(BubblePresentation.visible(preview.sessions, settings: config).map(\.id), [id])
        preview.markRead(id, now: config.now)
        XCTAssertEqual(BubblePresentation.Row(session: preview.sessions[0]).lamp, .off)
        config.now = at.addingTimeInterval(102.9)
        XCTAssertEqual(BubblePresentation.visible(preview.sessions, settings: config).count, 1)
        config.now = at.addingTimeInterval(103)
        XCTAssertTrue(BubblePresentation.visible(preview.sessions, settings: config).isEmpty)
        config.readResultRetention = .tenSeconds
        XCTAssertEqual(BubblePresentation.visible(preview.sessions, settings: config).count, 1)
    }

    func testReadingWaitingDoesNotResolveRequestOrHideActiveTask() throws {
        var preview = SettingsPreviewState()
        let id = try XCTUnwrap(preview.add(.opencode, now: at))
        preview.setStatus(.waiting, id: id, now: at.addingTimeInterval(1))
        preview.markRead(id, now: at.addingTimeInterval(2))
        let session = preview.sessions[0]
        XCTAssertEqual(session.state, .waiting)
        XCTAssertEqual(session.humanRequests?.count, 1)
        XCTAssertTrue(session.hasReadReceipt)
        XCTAssertNil(session.turnEndedAt)
        XCTAssertEqual(BubblePresentation.visible(preview.sessions,
            settings: .init(now: at.addingTimeInterval(300))).count, 1)
    }

    func testNewTurnInvalidatesOldReceiptAndOldReply() throws {
        var preview = SettingsPreviewState()
        let id = try XCTUnwrap(preview.add(.codex, now: at))
        preview.reply(to: id, duration: 5, now: at)
        preview.setStatus(.completed, id: id, now: at.addingTimeInterval(1))
        preview.markRead(id, now: at.addingTimeInterval(1))
        preview.setStatus(.working, id: id, now: at.addingTimeInterval(2))
        let session = preview.sessions[0]
        XCTAssertEqual(session.interactionGeneration, 2)
        XCTAssertEqual(session.turnStartedAt, at.addingTimeInterval(2))
        XCTAssertNil(session.turnEndedAt)
        XCTAssertNil(session.taskResult)
        XCTAssertFalse(session.hasReadReceipt)
        XCTAssertEqual(session.indicator, .running)
        XCTAssertTrue(preview.visibleReplies(hiddenKinds: [], now: at.addingTimeInterval(2)).isEmpty)
    }

    func testReplyPreviewUsesProductionSixRowCapTruncationAndExpiry() throws {
        var preview = SettingsPreviewState()
        for i in 0..<7 {
            let now = at.addingTimeInterval(Double(i) * 0.6)
            let id = try XCTUnwrap(preview.add(.opencode, now: now))
            preview.reply(to: id, duration: 5, now: now)
        }
        let now = at.addingTimeInterval(3.6)
        let rows = preview.visibleReplies(hiddenKinds: [], now: now)
        XCTAssertEqual(rows.count, PetSpeechState.maximumRows)
        XCTAssertTrue(rows.allSatisfy { $0.text.count <= 20 })
        XCTAssertTrue(preview.visibleReplies(hiddenKinds: [.opencode], now: now).isEmpty)
        preview.advance(now: at.addingTimeInterval(9))
        XCTAssertTrue(preview.visibleReplies(hiddenKinds: [], now: at.addingTimeInterval(9)).isEmpty)
    }

    func testClearingPreviewResetsOnlyItsOwnSyntheticData() throws {
        var a = SettingsPreviewState()
        var b = SettingsPreviewState()
        let id = try XCTUnwrap(a.add(.antigravity, now: at))
        b.add(.codex, now: at)
        a.reply(to: id, duration: 5, now: at)
        a.clear()
        XCTAssertTrue(a.sessions.isEmpty)
        XCTAssertTrue(a.visibleReplies(hiddenKinds: [], now: at).isEmpty)
        XCTAssertEqual(b.sessions.count, 1)
    }
}
