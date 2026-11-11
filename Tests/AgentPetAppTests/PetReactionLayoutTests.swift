import AppKit
import SwiftUI
import XCTest
@testable import agentpet

@MainActor
final class PetReactionLayoutTests: XCTestCase {
    func testClearBubbleBackgroundKeepsTextVisible() throws {
        let settings = BubbleSettings.shared
        let oldOpacity = settings.opacity, oldTheme = settings.theme
        defer { settings.opacity = oldOpacity; settings.theme = oldTheme }
        settings.theme = .light
        for (index, view) in [AnyView(ChatBubble(text: "Visible message")),
                     AnyView(PetReactionBubble(text: "Visible message", readingWidth: true))].enumerated() {
            func pixels(at opacity: Double) throws -> (opaque: Int, text: Int) {
                settings.opacity = opacity
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                if let path = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"],
                   let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("bubble-\(index)-\(Int(opacity * 100)).png"))
                }
                var opaque = 0, text = 0
                var maxAlpha: CGFloat = 0, visible = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if color.alphaComponent > 0.95 { opaque += 1 }
                        maxAlpha = max(maxAlpha, color.alphaComponent)
                        if color.alphaComponent > 0.2 { visible += 1 }
                        // Primary styling can compound to ~0.72 alpha; count
                        // readable glyph cores, not only nearly opaque pixels.
                        if color.alphaComponent > 0.6 && color.redComponent < 0.4
                            && color.greenComponent < 0.4 && color.blueComponent < 0.4 { text += 1 }
                    }
                }
                print("background render \(index) opacity \(opacity): opaque=\(opaque) text=\(text) visible=\(visible) maxAlpha=\(maxAlpha)")
                return (opaque, text)
            }
            let filled = try pixels(at: 1)
            let clear = try pixels(at: 0)
            XCTAssertGreaterThan(filled.opaque, 100)
            XCTAssertEqual(clear.opaque, 0, "A clear bubble must not retain a material/opaque backing")
            XCTAssertGreaterThan(clear.text, 20, "Text must remain visible when the background is cleared")
            XCTAssertGreaterThanOrEqual(clear.text, Int(Double(filled.text) * 0.8))
        }
    }

    func testSpeechUsesSeparateHostAndQuotaOwnsIt() {
        let settings = BubbleSettings.shared
        let enabled = settings.petBubbleEnabled
        defer { settings.petBubbleEnabled = enabled }
        settings.petBubbleEnabled = true
        let model = PetWindowModel(key: "speech-layout-test")
        let host = NSHostingView(rootView: FloatingPetView(model: model))
        let before = host.fittingSize
        model.quotaText = "额度较低，文字独占窗口"
        let speech = NSHostingView(rootView: PetSpeechView(model: model))
        XCTAssertLessThanOrEqual(speech.fittingSize.width, 293)
        XCTAssertGreaterThan(speech.fittingSize.height, 30)
        XCTAssertEqual(PetSpeechView.notice(model), model.quotaText)
        XCTAssertEqual(host.fittingSize.height, before.height, accuracy: 1,
                       "Speech content is hosted outside the task/body window")
        model.speechHeight = speech.fittingSize.height
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, before.height, accuracy: 1,
                       "The pet body is independent of both message panels")
    }
    func testTapReactionUsesIndependentSpeechHost() {
        let model = PetWindowModel(key: "reaction-layout-test")
        model.petTap()
        XCTAssertFalse(model.petReactionLine.isEmpty)
        XCTAssertTrue(IdleSpeechSettings.shared.lines.contains(model.petReactionLine),
                      "The production model must use the selected personality pool")
        let host = NSHostingView(rootView: PetSpeechView(model: model))
        XCTAssertGreaterThan(host.fittingSize.height, 20)
        model.quotaText = "important"
        XCTAssertEqual(PetSpeechView.notice(model), "important")
        model.stopInteraction()
    }

    func testReactionTextUsesItsCompleteIntrinsicSize() {
        for text in ["Oh! Hello~", "Hi there! 👋", "More pets please!", "Can't stop smiling! 🥰", "MAXIMUM LOVE! 💖", "你好，很高兴见到你！"] {
            let host = NSHostingView(rootView: PetReactionBubble(text: text))
            let textSize = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            XCTAssertGreaterThanOrEqual(host.fittingSize.width, textSize.width + 19, text)
            XCTAssertGreaterThanOrEqual(host.fittingSize.height, textSize.height + 9, text)
            XCTAssertLessThanOrEqual(host.fittingSize.width, 301, text)
        }
    }
}
