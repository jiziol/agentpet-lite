import AppKit
import SwiftUI
import XCTest
import AgentPetCore
@testable import agentpet

@MainActor
final class OpencodeSpeechControllerTests: XCTestCase {
    func testDecodedOpenCodeFramesReachIndependentNativePanelAndExpire() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let enabled = settings.petBubbleEnabled, hidden = settings.hiddenKinds
        defer { settings.petBubbleEnabled = enabled; settings.hiddenKinds = hidden }
        settings.petBubbleEnabled = true; settings.hiddenKinds = []
        let controller = PetController()
        controller.splitPet = false; controller.showChat = true
        defer { controller.clearProgress(); PetWindowController.shared.stop() }
        let at = Date()
        let sessions = (1...2).map { n -> AgentSession in
            var s = AgentSession(id: "ses_Native\(n)", agentKind: .opencode, state: .working, source: .hook, updatedAt: at)
            s.createdAt = at; s.turnStartedAt = at; s.opencodeTurnID = "msg_User\(n)"; s.opencodeProcessID = 123
            s.title = "隔离 OpenCode 面板验证 \(n)"
            return s
        }
        controller.update(sessions: sessions)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let body = try XCTUnwrap(NSApp.windows.first { $0.title == "AgentPet Lite Body" && $0.isVisible })
        let originalBody = body.frame
        func message(_ session: AgentSession, parent: String? = nil, mode: String = "snapshot", revision: Int = 1) throws -> OpencodeVisibleMessage {
            let frame: [String: Any] = ["schema": OpencodeVisibleMessage.schema, "session_id": session.id,
                "parent_id": parent ?? session.opencodeTurnID!, "message_id": "msg_Assistant", "part_id": "prt_Text",
                "process_id": 123, "revision": revision, "timestamp": Date().timeIntervalSince1970,
                "mode": mode, "text": mode == "withdraw" ? "" : "正在核对窗口布局",
                "role": "assistant", "part_type": "text", "synthetic": false, "ignored": false]
            return try EventCoding.decoder.decode(OpencodeVisibleMessage.self, from: JSONSerialization.data(withJSONObject: frame))
        }
        for session in sessions { controller.showProgress(try message(session), session: session) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "AgentPet Lite Pet Messages" && $0.isVisible })
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<PetSpeechView>)
        let model = host.rootView.model
        XCTAssertEqual(model.speechRows.map(\.label), ["@OpenCode[1]", "@OpenCode[2]"])
        XCTAssertEqual(model.speechRows.map(\.text), ["正在核对窗口布局", "正在核对窗口布局"])
        XCTAssertEqual(body.frame, originalBody)
        XCTAssertLessThanOrEqual(panel.frame.width, 293)
        controller.showProgress(try message(sessions[0], parent: "msg_Old"), session: sessions[0])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.speechRows.count, 2)
        controller.showProgress(try message(sessions[0], mode: "withdraw", revision: 2), session: sessions[0])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.speechRows.map(\.label), ["@OpenCode[2]"])
        RunLoop.main.run(until: Date().addingTimeInterval(2.7))
        XCTAssertEqual(model.speechRows.count, 1, "The new five-second display must remain past three seconds")
        XCTAssertTrue(panel.isVisible)
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        XCTAssertTrue(model.speechRows.isEmpty); XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(body.frame, originalBody)
    }
}
