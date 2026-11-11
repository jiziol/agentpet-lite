import AppKit
import XCTest
@testable import AgentPetCore
@testable import agentpet

@MainActor
final class PetClickDisambiguationTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 7_000)
    private var settings: BubbleSettings { .shared }
    nonisolated private static let anchorKey = "agentpet.petAnchors.v1"
    private nonisolated(unsafe) var savedAnchors: Any?
    private nonisolated(unsafe) var didPrepareAnchors = false

    override nonisolated func setUpWithError() throws {
        didPrepareAnchors = false
        try TestIsolation.require()
        savedAnchors = UserDefaults.standard.object(forKey: Self.anchorKey)
        didPrepareAnchors = true
    }

    override nonisolated func tearDown() {
        defer { super.tearDown() }
        guard didPrepareAnchors else { return }
        didPrepareAnchors = false
        if let savedAnchors {
            UserDefaults.standard.set(savedAnchors, forKey: Self.anchorKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.anchorKey)
        }
    }

    private func makeController(_ sessions: [AgentSession] = []) throws
        -> (PetWindowController, NSWindow, PetWindowModel, NSPoint) {
        _ = NSApplication.shared
        let controller = PetWindowController()
        let before = Set(NSApp.windows.map(\.windowNumber))
        let specs = PetWindowPlanner.plan(sessions: sessions, split: false, mappings: [],
                                          defaultPetID: "click-disambiguation-preview")
        controller.sync(specs: specs) { _ in
            .init(petID: "click-disambiguation-preview",
                  mood: sessions.isEmpty ? .idle : .working,
                  sessions: sessions, count: sessions.count, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let body = try XCTUnwrap(NSApp.windows.first {
            !before.contains($0.windowNumber)
                && $0.title == "AgentPet Lite Body"
                && ($0.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model.key == "default"
                && $0.isVisible
        })
        let model = try XCTUnwrap((body.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model)
        let petBody = try XCTUnwrap(model.petBodyView)
        let point = petBody.convert(NSPoint(x: petBody.bounds.midX, y: petBody.bounds.midY), to: nil)
        return (controller, body, model, point)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
                       clicks: Int) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 1, clickCount: clicks, pressure: 1)!
    }

    private func click(_ controller: PetWindowController, at point: NSPoint, in window: NSWindow,
                       clicks: Int) {
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: window, clicks: clicks))
        controller.handlePetClickEvent(event(.leftMouseUp, at: point, in: window, clicks: clicks))
    }

    /// Simulates the production geometry: the window follows the cursor while
    /// the window-relative point stays fixed. `steps` are cumulative screen
    /// offsets; each step moves the window before the drag event is delivered.
    private func followDrag(_ controller: PetWindowController, from point: NSPoint,
                            in window: NSWindow, clicks: Int,
                            steps: [(CGFloat, CGFloat)]) {
        let origin = window.frame.origin
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: window, clicks: clicks))
        for (dx, dy) in steps {
            window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
            controller.handlePetClickEvent(event(.leftMouseDragged, at: point,
                                                 in: window, clicks: clicks))
        }
        window.setFrameOrigin(NSPoint(x: origin.x + (steps.last?.0 ?? 0),
                                     y: origin.y + (steps.last?.1 ?? 0)))
        controller.handlePetClickEvent(event(.leftMouseUp, at: point, in: window, clicks: clicks))
    }

    private func drag(_ controller: PetWindowController, from point: NSPoint, in window: NSWindow,
                      clicks: Int, delta: CGFloat = 20) {
        followDrag(controller, from: point, in: window, clicks: clicks, steps: [(delta, 0)])
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var clickWindow: TimeInterval { NSEvent.doubleClickInterval }

    func testSingleClickWaitsForSystemWindowThenPetsExactlyOnce() throws {
        let saved = settings.taskBubbleClickThrough
        let savedSuperchat = settings.superchatEnabled
        settings.taskBubbleClickThrough = false
        settings.superchatEnabled = true
        let notices = PetController.shared.systemNotices
        notices.clear()
        let (controller, body, model, point) = try makeController()
        defer {
            controller.stop(); notices.clear()
            settings.taskBubbleClickThrough = saved
            settings.superchatEnabled = savedSuperchat
        }
        click(controller, at: point, in: body, clicks: 1)
        wait(clickWindow * 0.4)
        XCTAssertEqual(model.petTapCount, 0, "No pet business before the system double-click window ends")
        XCTAssertTrue(model.petReactionLine.isEmpty)
        XCTAssertNil(notices.current, "A single click never posts click-through feedback")

        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 1)
        XCTAssertFalse(model.petReactionLine.isEmpty, "The original single-click reaction/message runs once")
        XCTAssertFalse(settings.taskBubbleClickThrough, "A single click never toggles")
        XCTAssertNil(notices.current)
    }

    func testDoubleClickAtBoundaryTogglesOnceAndSuppressesAllSingleBusiness() async throws {
        let saved = settings.taskBubbleClickThrough
        let savedSuperchat = settings.superchatEnabled
        settings.taskBubbleClickThrough = false
        settings.superchatEnabled = true
        let notices = PetController.shared.systemNotices
        notices.clear()
        let (controller, body, model, point) = try makeController()
        defer {
            controller.stop(); notices.clear()
            settings.taskBubbleClickThrough = saved
            settings.superchatEnabled = savedSuperchat
        }
        click(controller, at: point, in: body, clicks: 1)
        let secondClick = expectation(description: "Second native click inside the system window")
        // Schedule the input itself before the single-click deadline. Returning
        // from run(until:) can be late and would change this into a late click.
        DispatchQueue.main.asyncAfter(deadline: .now() + clickWindow * 0.9) {
            MainActor.assumeIsolated {
                XCTAssertEqual(model.petTapCount, 0)
                self.click(controller, at: point, in: body, clicks: 2)
                secondClick.fulfill()
            }
        }
        await fulfillment(of: [secondClick], timeout: clickWindow + 3)
        XCTAssertTrue(settings.taskBubbleClickThrough, "Double-click toggles exactly once")
        XCTAssertEqual(model.petTapCount, 0, "A double-click has no pet animation")
        XCTAssertEqual(notices.current?.kind, .clickThroughOn, "Exactly one Superchat feedback is shown")
        XCTAssertTrue(model.petReactionLine.isEmpty, "The old pet-line feedback must not also appear")

        // One continuous native 1→2→3→4 sequence: only clickCount 2 toggles.
        // 3/4 must not be treated as a second independent double-click.
        click(controller, at: point, in: body, clicks: 3)
        click(controller, at: point, in: body, clicks: 4)
        XCTAssertTrue(settings.taskBubbleClickThrough)
        XCTAssertEqual(model.petTapCount, 0)
        wait(clickWindow + 0.25)
        XCTAssertEqual(model.petTapCount, 0, "No late single callback after the double-click")
        XCTAssertTrue(settings.taskBubbleClickThrough)

        // After the system reset, each independent double-click toggles once.
        click(controller, at: point, in: body, clicks: 1)
        click(controller, at: point, in: body, clicks: 2)
        XCTAssertFalse(settings.taskBubbleClickThrough)
        XCTAssertEqual(model.petTapCount, 0)
        XCTAssertEqual(notices.current?.kind, .clickThroughOff)
        wait(clickWindow + 0.2)
        click(controller, at: point, in: body, clicks: 1)
        click(controller, at: point, in: body, clicks: 2)
        XCTAssertTrue(settings.taskBubbleClickThrough)
        XCTAssertEqual(model.petTapCount, 0)
        XCTAssertEqual(notices.current?.kind, .clickThroughOn)
    }

    func testIndependentClicksOutsideWindowBecomeTwoSinglesAndAlternatingGesturesLeaveNoResidue() throws {
        let saved = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = false
        let (controller, body, model, point) = try makeController()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = saved
        }
        click(controller, at: point, in: body, clicks: 1)
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 1)
        // A valid slow double within the system interval is still clickCount 2;
        // outside the interval/distance the system exposes two independent 1s.
        click(controller, at: point, in: body, clicks: 1)
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 2)
        XCTAssertFalse(settings.taskBubbleClickThrough, "Two slow singles must not toggle")

        click(controller, at: point, in: body, clicks: 1)
        click(controller, at: point, in: body, clicks: 2)
        XCTAssertTrue(settings.taskBubbleClickThrough)
        wait(clickWindow + 0.2)
        click(controller, at: point, in: body, clicks: 1)
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 3)
        XCTAssertTrue(settings.taskBubbleClickThrough)
        click(controller, at: point, in: body, clicks: 1)
        click(controller, at: point, in: body, clicks: 2)
        XCTAssertFalse(settings.taskBubbleClickThrough)
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 3, "Alternating gestures leave no delayed single")
    }

    func testSecondPressDragAndFirstPressDragCancelPendingSingles() throws {
        let saved = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = false
        let (controller, body, model, point) = try makeController()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = saved
        }
        click(controller, at: point, in: body, clicks: 1)
        drag(controller, from: point, in: body, clicks: 2)
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 0, "A second press that drags is not a double-click")
        XCTAssertFalse(settings.taskBubbleClickThrough)

        drag(controller, from: point, in: body, clicks: 1)
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 0, "A first press that drags is not a single click")
    }

    func testSlowFollowDragWithFixedWindowPointDoesNotPetOrToggle() throws {
        let saved = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = false
        let (controller, body, model, point) = try makeController()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = saved
        }
        // Ordinary drag: the window follows in 3pt steps while the cursor's
        // window-relative point stays fixed.
        followDrag(controller, from: point, in: body, clicks: 1,
                   steps: [(3, 0), (6, 0), (9, 0), (12, 0)])
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 0, "A slow follow-drag is not a click")
        XCTAssertFalse(settings.taskBubbleClickThrough)
        XCTAssertTrue(model.petReactionLine.isEmpty)

        // First click, then a second press that follows the same slow drag:
        // the pending single and the would-be double must both be cancelled.
        click(controller, at: point, in: body, clicks: 1)
        followDrag(controller, from: point, in: body, clicks: 2,
                   steps: [(3, 0), (6, 0), (9, 0), (12, 0)])
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 0, "A second press that drags is not a double-click")
        XCTAssertFalse(settings.taskBubbleClickThrough, "A slow drag must not flip the preference")
        XCTAssertTrue(model.petReactionLine.isEmpty)
    }

    func testDragThresholdUsesSwiftUIAxisBoundary() throws {
        let saved = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = false
        let (controller, body, model, point) = try makeController()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = saved
        }
        // 4.9/4.9 does not start the SwiftUI drag, so it settles as one click.
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: body, clicks: 1))
        controller.handlePetClickEvent(event(.leftMouseUp,
                                             at: NSPoint(x: point.x + 4.9, y: point.y + 4.9),
                                             in: body, clicks: 1))
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 1, "Both axes below 5pt remain a click")

        // 5/0 starts the SwiftUI drag; no pet business may follow.
        let origin = body.frame.origin
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: body, clicks: 1))
        body.setFrameOrigin(NSPoint(x: origin.x + 5, y: origin.y))
        controller.handlePetClickEvent(event(.leftMouseUp, at: point, in: body, clicks: 1))
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 1, "Either axis reaching 5pt cancels the click")
    }

    func testRightClickAndTeardownCancelPendingSingle() throws {
        let saved = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = false
        let (controller, body, model, point) = try makeController()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = saved
        }
        click(controller, at: point, in: body, clicks: 1)
        let right = event(.rightMouseDown, at: point, in: body, clicks: 1)
        XCTAssertTrue(controller.handlePetRightClickEvent(right))
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 0, "Right-click cancels the pending left single")
        XCTAssertTrue(model.petReactionLine.isEmpty)

        click(controller, at: point, in: body, clicks: 1)
        controller.stop()
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 0, "Teardown cancels an already-scheduled single")
        XCTAssertTrue(model.petReactionLine.isEmpty)
    }

    func testInstalledLocalMonitorReceivesSingleClick() throws {
        let saved = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = false
        _ = NSApplication.shared
        let controller = PetWindowController()
        let before = Set(NSApp.windows.map(\.windowNumber))
        controller.start()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = saved
        }
        let specs = PetWindowPlanner.plan(sessions: [], split: false, mappings: [],
                                          defaultPetID: "monitor-preview")
        controller.sync(specs: specs) { _ in
            .init(petID: "monitor-preview", mood: .idle, sessions: [], count: 0, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let body = try XCTUnwrap(NSApp.windows.first {
            !before.contains($0.windowNumber) && $0.title == "AgentPet Lite Body" && $0.isVisible
        })
        let model = try XCTUnwrap((body.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model)
        let petBody = try XCTUnwrap(model.petBodyView)
        let point = petBody.convert(NSPoint(x: petBody.bounds.midX, y: petBody.bounds.midY), to: nil)
        NSApp.sendEvent(event(.leftMouseDown, at: point, in: body, clicks: 1))
        NSApp.sendEvent(event(.leftMouseUp, at: point, in: body, clicks: 1))
        wait(clickWindow + 0.2)
        XCTAssertEqual(model.petTapCount, 1, "The installed local monitor must receive this event path")
    }

    func testInstalledLocalMonitorReceivesDoubleClickWithoutSingleBusiness() throws {
        let saved = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = false
        _ = NSApplication.shared
        let controller = PetWindowController()
        let before = Set(NSApp.windows.map(\.windowNumber))
        controller.start()
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = saved
        }
        let specs = PetWindowPlanner.plan(sessions: [], split: false, mappings: [],
                                          defaultPetID: "monitor-double-preview")
        controller.sync(specs: specs) { _ in
            .init(petID: "monitor-double-preview", mood: .idle, sessions: [], count: 0, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let body = try XCTUnwrap(NSApp.windows.first {
            !before.contains($0.windowNumber) && $0.title == "AgentPet Lite Body" && $0.isVisible
        })
        let model = try XCTUnwrap((body.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model)
        let petBody = try XCTUnwrap(model.petBodyView)
        let point = petBody.convert(NSPoint(x: petBody.bounds.midX, y: petBody.bounds.midY), to: nil)
        NSApp.sendEvent(event(.leftMouseDown, at: point, in: body, clicks: 1))
        NSApp.sendEvent(event(.leftMouseUp, at: point, in: body, clicks: 1))
        NSApp.sendEvent(event(.leftMouseDown, at: point, in: body, clicks: 2))
        NSApp.sendEvent(event(.leftMouseUp, at: point, in: body, clicks: 2))
        wait(clickWindow + 0.2)
        XCTAssertTrue(settings.taskBubbleClickThrough)
        XCTAssertEqual(model.petTapCount, 0, "The installed monitor routes a double-click without a first-click pet")
    }

    func testTwoPetWindowsDoNotCrossToggle() throws {
        let saved = settings.taskBubbleClickThrough
        settings.taskBubbleClickThrough = false
        _ = NSApplication.shared
        let controller = PetWindowController()
        let before = Set(NSApp.windows.map(\.windowNumber))
        defer {
            controller.stop()
            settings.taskBubbleClickThrough = saved
        }
        func agent(_ id: String) -> AgentSession {
            var value = AgentSession(id: id, agentKind: .codex, state: .working,
                                     source: .hook, updatedAt: at)
            value.title = id
            return value
        }
        let first = agent("multi-pet-a")
        let second = agent("multi-pet-b")
        let specs = [
            PetWindowSpec(key: "default", projectName: nil, petID: "pet-a",
                          sessionIDs: [first.id], mood: .working, count: 1),
            PetWindowSpec(key: "/multi-pet", projectName: "multi", petID: "pet-b",
                          sessionIDs: [second.id], mood: .working, count: 1)
        ]
        controller.sync(specs: specs) { spec in
            let sessions = spec.key == "default" ? [first] : [second]
            return .init(petID: spec.petID, mood: .working, sessions: sessions,
                         count: 1, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bodies = NSApp.windows.filter {
            $0.title == "AgentPet Lite Body" && !before.contains($0.windowNumber)
        }
        var models: [String: (NSWindow, PetWindowModel, NSPoint)] = [:]
        for body in bodies {
            guard let model = (body.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model,
                  let petBody = model.petBodyView else { continue }
            models[model.key] = (body, model,
                                 petBody.convert(NSPoint(x: petBody.bounds.midX, y: petBody.bounds.midY), to: nil))
        }
        let a = try XCTUnwrap(models["default"])
        let b = try XCTUnwrap(models["/multi-pet"])
        click(controller, at: a.2, in: a.0, clicks: 1)
        // A second click in another pet window cannot complete a local double.
        click(controller, at: b.2, in: b.0, clicks: 2)
        wait(clickWindow + 0.2)
        XCTAssertEqual(a.1.petTapCount, 1)
        XCTAssertEqual(b.1.petTapCount, 1)
        XCTAssertFalse(settings.taskBubbleClickThrough, "No cross-window toggle")
    }
}
