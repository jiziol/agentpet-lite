import AppKit
import SwiftUI
import XCTest
@testable import AgentPetCore
@testable import agentpet

@MainActor
final class AntigravitySpeechControllerTests: XCTestCase {
    func testNativeAgyPanelLabelDeadlineWithdrawalAndTurnFence() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let enabled = settings.petBubbleEnabled, hidden = settings.hiddenKinds
        defer { settings.petBubbleEnabled = enabled; settings.hiddenKinds = hidden }
        settings.petBubbleEnabled = true; settings.hiddenKinds = []
        let controller = PetController(); controller.splitPet = false; controller.showChat = true
        defer { controller.clearProgress(); PetWindowController.shared.stop() }
        let at = Date()
        var s = AgentSession(id: UUID().uuidString.lowercased(), agentKind: .antigravity, state: .working, source: .hook, updatedAt: at)
        s.createdAt = at; s.turnStartedAt = at; s.antigravityEventAt = at; s.antigravityStepFloor = 10
        controller.update(sessions: [s])
        // The first native SwiftUI body must finish its initial layout before
        // measuring the anchor; this check concerns subsequent speech updates.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let body = try XCTUnwrap(NSApp.windows.first { $0.title == "AgentPet Lite Body" && $0.isVisible })
        let frame = body.frame
        let boundary = try XCTUnwrap(AntigravityVisibleMessage.Boundary(session: s, enabledAt: at))
        func message(_ text: String, revision: Int, mode: AntigravityVisibleMessage.Mode = .snapshot) -> AntigravityVisibleMessage {
            .init(boundary: boundary, executionID: "current-execution", stepIndex: 10, timestamp: Date(), revision: revision, mode: mode, text: text)
        }
        controller.showProgress(message("正在检查认证逻辑与当前窗口中的消息归属", revision: 1), session: s)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "AgentPet Lite Pet Messages" && $0.isVisible })
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<PetSpeechView>)
        let model = host.rootView.model
        XCTAssertEqual(model.speechRows.first?.label, "@agy[1]")
        XCTAssertLessThanOrEqual(model.speechRows.first!.text.count, 20)
        let expires = model.speechRows.first!.expiresAt
        controller.showProgress(message("修订后的正文", revision: 2), session: s)
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        XCTAssertEqual(model.speechRows.first?.expiresAt, expires)
        XCTAssertEqual(body.frame, frame)
        controller.showProgress(message("", revision: 3, mode: .withdraw), session: s)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(model.speechRows.isEmpty)
        controller.showProgress(message("晚到修订不能重播", revision: 4), session: s)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(model.speechRows.isEmpty)
        var next = s; next.antigravityStepFloor = 11; next.antigravityEventAt = Date()
        controller.update(sessions: [next])
        controller.showProgress(message("旧轮次", revision: 5), session: next)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(model.speechRows.isEmpty)
        XCTAssertEqual(body.frame, frame)
    }
}
