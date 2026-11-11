import XCTest
import AppKit
import SwiftUI
@testable import agentpet
@testable import AgentPetCore

@MainActor
final class SettingsDisplayPolicyTests: XCTestCase {
    func testSuperchatMigrationKeepsExistingOffAndNewValueWins() {
        let name = "superchat-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(BubbleSettings.loadSuperchatEnabled(defaults: defaults))
        defaults.set(false, forKey: "agentpet.bubble.petBubbleEnabled")
        XCTAssertFalse(BubbleSettings.loadSuperchatEnabled(defaults: defaults))
        defaults.set(true, forKey: "agentpet.bubble.superchatEnabled")
        XCTAssertTrue(BubbleSettings.loadSuperchatEnabled(defaults: defaults))
    }
    func testInvalidTextOpacityAndDurationsHaveSafeDefaults() {
        XCTAssertEqual(BubbleSettings.normalizedTextOpacity(.nan), 1)
        XCTAssertEqual(BubbleSettings.normalizedTextOpacity(-1), 0.2)
        XCTAssertEqual(BubbleSettings.normalizedTextOpacity(2), 1)
        XCTAssertEqual(BubbleSettings.normalizedMessageDuration(.infinity), 5)
        XCTAssertEqual(BubbleSettings.normalizedMessageDuration(8), 8)
    }
    func testSuperchatOffDoesNotHideOrdinaryOrIdleMessages() {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let enabled = settings.superchatEnabled
        defer { settings.superchatEnabled = enabled }
        settings.superchatEnabled = false
        XCTAssertTrue(settings.agentMessagesEnabled)
        XCTAssertTrue(settings.structuredTasksEnabled)
        let pet = PetController()
        pet.showPomodoro("到点")
        pet.showLowQuota(.init(id: "suppressed", text: "不应该显示"))
        XCTAssertNil(pet.systemNotices.current)
        let model = PetWindowModel(key: "isolated-idle")
        model.idleText = "闲聊仍然可见"
        XCTAssertTrue(PetSpeechView.hasContent(model))
        let session = AgentSession(id: "message", agentKind: .codex, state: .working, source: .hook, updatedAt: Date())
        model.idleText = ""
        model.speechRows = [.init(id: UUID(), session: .init(session), label: "@Codex[1]", itemID: "x",
                                 text: "消息仍然可见", expiresAt: Date().addingTimeInterval(5))]
        XCTAssertTrue(PetSpeechView.hasContent(model))
        let host = NSHostingView(rootView: PetSpeechView(model: model))
        XCTAssertGreaterThan(host.fittingSize.height, 25)
        model.speechRows = []; model.quotaText = "被关闭的额度提醒"
        XCTAssertFalse(PetSpeechView.hasContent(model))
    }
    func testTextOpacityChangesGlyphsWithoutDimmingNoticeIconOrBar() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let opacity = settings.opacity, textOpacity = settings.textOpacity, theme = settings.theme
        let center = SystemNoticeCenter(visible: { _ in false }, changed: {})
        defer { center.clear(); settings.opacity = opacity; settings.textOpacity = textOpacity; settings.theme = theme }
        settings.theme = .light; settings.opacity = 0
        let notice = SystemNotice.lowQuota(.init(id: "isolated-render", text: "", percent: 8))
        func counts(_ alpha: Double) throws -> (glyphs: Int, orange: Int) {
            settings.textOpacity = alpha
            let renderer = ImageRenderer(content: SystemNoticeView(source: center, notice: notice))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            var glyphs = 0, orange = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if x > 100 && x < 720 && y > 10 && y < 90 && c.alphaComponent > 0.7
                        && c.redComponent < 0.4 && c.greenComponent < 0.4 { glyphs += 1 }
                    if c.alphaComponent > 0.8 && c.redComponent > 0.8 && c.greenComponent > 0.35
                        && c.greenComponent < 0.7 && c.blueComponent < 0.4 { orange += 1 }
                }
            }
            if let path = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"],
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("text-opacity-\(Int(alpha * 100)).png"))
            }
            return (glyphs, orange)
        }
        let normal = try counts(1), faded = try counts(0.2)
        XCTAssertGreaterThan(normal.glyphs, 100)
        XCTAssertLessThan(faded.glyphs, normal.glyphs / 5)
        XCTAssertGreaterThan(normal.orange, 100)
        XCTAssertEqual(faded.orange, normal.orange, "Icon, accent and progress must be independent of text opacity")
    }

}
