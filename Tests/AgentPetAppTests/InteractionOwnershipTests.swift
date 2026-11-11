import AppKit
import XCTest
@testable import agentpet

@MainActor
final class InteractionOwnershipTests: XCTestCase {
    private func image() -> CGImage {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    func testSameModelReopenRejectsOldLayoutAndFallbackAndCapturesCurrentMessage() async {
        let model = PetWindowModel(key: "synthetic", chatLine: "old")
        let owner = PetMessageLayoutRestoration(); let image = image()
        var oldCompletions = 0
        owner.begin(model: model, hasContent: true, timeout: 0.01, capture: { nil }, completion: { _ in oldCompletions += 1 })
        let oldReady = model.onMessageLayoutReady
        let done = expectation(description: "fresh snapshot")
        owner.begin(model: model, hasContent: true, timeout: 0.2, capture: {
            PetBubbleSnapshot(image: image, frame: NSRect(x: 0, y: 0, width: model.chatLine.count, height: 1))
        }, completion: { snapshot in
            XCTAssertEqual(snapshot?.frame.width, 5); done.fulfill()
        })
        model.chatLine = "fresh"
        oldReady?()
        await fulfillment(of: [done], timeout: 1)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(oldCompletions, 0)
        XCTAssertNil(model.onMessageLayoutReady)
        owner.cancel()
    }
    func testSnapshotFailureAndNoMessagesFinishStatusWithoutInvisibleContent() async {
        for hasContent in [true, false] {
            let panel = PetStatsPanelController()
            let owner = PetMessageLayoutRestoration()
            let model = PetWindowModel(key: "synthetic")
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            panel.show(content: view, frame: NSRect(x: 100, y: 100, width: 20, height: 20), petBody: { nil }, animated: false,
                hideMessages: { model.isShowingStats = true }, restoreMessages: { completion in
                    owner.begin(model: model, hasContent: hasContent, timeout: 0.01, capture: { nil }, completion: completion)
                }, onClose: {
                    owner.cancel(); model.messagesTransitionHidden = false; model.isShowingStats = false
                })
            panel.close()
            try? await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(panel.phase, .hidden)
            XCTAssertFalse(model.isShowingStats); XCTAssertFalse(model.messagesTransitionHidden)
            XCTAssertNil(model.onMessageLayoutReady)
            panel.dismissImmediately()
        }
    }
    func testGenerationInvalidatesAlreadyQueuedTimerCallbacks() {
        let owner = InteractionGeneration()
        let old = owner.token; owner.renew()
        XCTAssertFalse(owner.accepts(old)); XCTAssertTrue(owner.accepts(owner.token))
    }
    func testReactionOwnersIndependentCooldownAndTeardownRestoresState() async {
        var sounds = 0
        let first = PetReactionController(sound: { sounds += 1 }, changed: { _ in })
        let second = PetReactionController(sound: {}, changed: { _ in })
        first.tap(); first.tap()
        XCTAssertEqual(first.state.tapCount, 1); XCTAssertEqual(sounds, 1)
        XCTAssertFalse(second.state.isPetted); XCTAssertEqual(second.state.tapCount, 0)
        first.stop(); first.tap()
        XCTAssertEqual(first.state.tapCount, 2)
        first.stop()
        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertFalse(first.state.isPetted); XCTAssertTrue(first.state.line.isEmpty)
        second.stop()
    }
    func testTapReadsCurrentPersonalityAndLiteralCustomWithoutRepeating() {
        let name = "tap-speech-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IdleSpeechSettings(defaults: defaults)
        let reaction = PetReactionController(pickLine: { settings.pick() }, sound: {}, changed: { _ in })
        defer { reaction.stop() }
        for style in WhaleSpeechStyle.allCases {
            settings.style = style
            var previous: String?
            for _ in 0..<20 {
                reaction.tap()
                XCTAssertTrue(style.lines.contains(reaction.state.line))
                XCTAssertNotEqual(reaction.state.line, previous)
                previous = reaction.state.line
                reaction.stop()
            }
        }
        XCTAssertTrue(settings.applyCustom("保留原文～\n第二句！"))
        reaction.tap()
        let first = reaction.state.line
        XCTAssertTrue(["保留原文～", "第二句！"].contains(first))
        reaction.stop(); settings.style = .tsundere; reaction.tap()
        XCTAssertNotEqual(reaction.state.line, first)
        XCTAssertTrue(["保留原文～", "第二句！"].contains(reaction.state.line))
        reaction.stop(); XCTAssertTrue(settings.applyCustom("只有这一句")); reaction.tap()
        XCTAssertEqual(reaction.state.line, "只有这一句")
        reaction.stop(); reaction.tap()
        XCTAssertEqual(reaction.state.line, "只有这一句")
    }
}
