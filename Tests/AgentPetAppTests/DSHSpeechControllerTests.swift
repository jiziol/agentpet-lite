import AppKit
import SwiftUI
import XCTest
@testable import AgentPetCore
@testable import agentpet

@MainActor
final class DSHSpeechControllerTests: XCTestCase {
    func testSyntheticPublicFrameTraversesCoordinatorIntoFiveSecondNativePanel() throws {
        _ = NSApplication.shared
        // Use the same epoch precision as the JSON frame; Unix conversion can
        // put the frame 119 ns behind an unrounded Date and fail the strict fence.
        let at = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
        // A portable synthetic protocol fixture, not a private host recording
        // or evidence of a fresh DSH/model interaction.
        let fields: [String: Any] = [
            "schema": "agentpet.dsh.speech.v1", "profile_id": String(repeating: "a", count: 24),
            "host_id": "11111111-1111-4111-8111-111111111111",
            "host_started_at": at.addingTimeInterval(-10).timeIntervalSince1970,
            "session_id": "synthetic-panel-session", "turn": 1, "native_seq": 3,
            "observation_revision": 2, "item_id": "3", "revision": 1,
            "timestamp": at.timeIntervalSince1970, "role": "assistant", "part_type": "text",
            "mode": "snapshot", "text": "好的。正在验证DSH消息气泡。"
        ]
        let message = try XCTUnwrap(DSHVisibleMessage.decode(JSONSerialization.data(withJSONObject: fields)))
        let obs = DSHObservation(schema: 1, profileID: message.profileID, hostID: message.hostID,
            hostStartedAt: message.hostStartedAt, nativeSessionID: message.sessionID,
            revision: message.observationRevision, nativeSeq: message.nativeSeq, turn: message.turn,
            phase: .working, result: nil, pending: [], startedAt: at, endedAt: nil,
            baseline: false, heartbeat: false, gap: false, navigationSocket: nil)
        var session = AgentSession(id: message.sessionKey, agentKind: .dsh, state: .working, source: .hook, updatedAt: at)
        session.createdAt = at; session.turnStartedAt = at; session.dsh = obs
        let settings = BubbleSettings.shared
        let enabled = settings.petBubbleEnabled, hidden = settings.hiddenKinds
        let controller = PetController(), split = controllerSplit()
        let oldShow = controller.showChat
        controller.splitPet = false; controller.showChat = true
        settings.petBubbleEnabled = true; settings.hiddenKinds = []
        defer {
            controller.clearProgress(); PetWindowController.shared.stop()
            controller.splitPet = split; controller.showChat = oldShow
            settings.petBubbleEnabled = enabled; settings.hiddenKinds = hidden
        }
        controller.update(sessions: [session])
        var state = DSHSpeechState(); state.reset(enabled: true, now: at)
        state.receive([message], now: at)
        let drained = state.drain(sessions: [session], now: at)
        print("DSH_FIXTURE timestampDelta=\(message.timestamp.timeIntervalSince(at)) drained=\(drained.count)")
        XCTAssertEqual(drained.count, 1)
        let shownAt = Date()
        for (text, target) in drained { controller.showProgress(text, session: target) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "AgentPet Lite Pet Messages" && $0.isVisible })
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<PetSpeechView>)
        let model = host.rootView.model
        XCTAssertEqual(model.speechRows.first?.label, "@DSH[1]")
        XCTAssertEqual(model.speechRows.first?.text, "好的。正在验证DSH消息气泡。")
        let expires = try XCTUnwrap(model.speechRows.first?.expiresAt)
        XCTAssertEqual(expires.timeIntervalSince(shownAt), 5, accuracy: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(3.1))
        XCTAssertTrue(panel.isVisible); XCTAssertEqual(model.speechRows.first?.expiresAt, expires)
        RunLoop.main.run(until: expires.addingTimeInterval(0.15))
        XCTAssertFalse(panel.isVisible); XCTAssertTrue(model.speechRows.isEmpty)
    }
    private func controllerSplit() -> Bool { PetController.shared.splitPet }
}
