import AppKit
import XCTest
@testable import AgentPetCore
@testable import agentpet

@MainActor
final class PetEdgePeekControllerTests: XCTestCase {
    private var key = ""
    private var savedSize = 120.0
    private var savedAnimations = true
    private var didSavePreferences = false
    private var controller: PetWindowController?
    private var asset: EdgePeekAsset?

    override nonisolated func setUpWithError() throws {
        try TestIsolation.require()
    }

    private func prepare() throws -> PetWindowController {
        _ = NSApplication.shared
        key = "/r2-peek-\(UUID().uuidString)"
        savedSize = PetController.shared.petPoint
        savedAnimations = PetController.shared.animationsEnabled
        didSavePreferences = true
        PetController.shared.petPoint = 70
        PetController.shared.animationsEnabled = true
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        asset = try XCTUnwrap(EdgePeekAsset.load(directory: directory))
        let controller = PetWindowController()
        self.controller = controller
        let spec = PetWindowSpec(key: key, projectName: "r2", petID: "deepseek",
                                 sessionIDs: [], mood: .idle, count: 0)
        controller.sync(specs: [spec]) { _ in
            .init(petID: "deepseek", mood: .idle, sessions: [], count: 0, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.peekAssetOverride = { [asset] _ in asset }
        return controller
    }

    override func tearDown() {
        controller?.stop()
        controller = nil
        if !key.isEmpty { PetEdgeStateStore().clear(forKey: key) }
        if didSavePreferences {
            PetController.shared.petPoint = savedSize
            PetController.shared.animationsEnabled = savedAnimations
        }
        super.tearDown()
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
                       clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 1, clickCount: clicks, pressure: 1)!
    }

    private func bodyWindow(visibleOnly: Bool = false) -> NSWindow? {
        NSApp.windows.first {
            $0.title == "AgentPet Lite Body" && (!visibleOnly || $0.isVisible)
                && (($0.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model.key == key)
        }
    }

    private func petModel() -> PetWindowModel? {
        (bodyWindow()?.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model
    }




    private func loadDefaultPack() throws {
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let pets = URL(fileURLWithPath: AgentPetPaths.baseDir).appendingPathComponent("pets")
        try FileManager.default.createDirectory(at: pets, withIntermediateDirectories: true)
        let installed = pets.appendingPathComponent("deepseek")
        if !FileManager.default.fileExists(atPath: installed.path) {
            try FileManager.default.copyItem(at: directory, to: installed)
        }
        ImagePetStore.shared.reload()
    }

    /// Uses the installed local monitor and real NSWindow events. No helper
    /// manually moves the body or delivers a SwiftUI drag move for this test.
    private func sendMouse(_ type: NSEvent.EventType, screen point: NSPoint, window: NSWindow,
                           clicks: Int = 1) {
        NSApp.sendEvent(event(type, at: window.convertPoint(fromScreen: point), in: window, clicks: clicks))
    }

    private func checkImmediateBodyDragAfterPeek(side: PetEdgeSide, releaseDelay: TimeInterval) throws {
        try loadDefaultPack()
        let controller = try prepare()
        controller.start()
        let initialBody = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        let initialMarker = try XCTUnwrap(petModel()?.petBodyView)
        let screens = NSScreen.screens.map { PetEdgeScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let index = try XCTUnwrap(screens.indices.first { index in
            let f = screens[index].visibleFrame
            return PetEdgeGeometry.isOuterEdge(side, screenIndex: index,
                verticalBand: CGRect(x: f.midX, y: f.midY - 35, width: 70, height: 70), screens: screens)
        })
        let visible = screens[index].visibleFrame
        initialBody.setFrameOrigin(NSPoint(x: visible.midX - initialBody.frame.width / 2,
                                           y: visible.midY - initialBody.frame.height / 2))
        let initialFrame = initialBody.convertToScreen(initialMarker.convert(initialMarker.bounds, to: nil))
        let initialPoint = NSPoint(x: initialFrame.midX, y: initialFrame.midY)
        let targetX = side == .right ? visible.maxX - initialFrame.width + 35 : visible.minX - 35
        let releasePoint = NSPoint(x: initialPoint.x + targetX - initialFrame.minX, y: initialPoint.y)
        sendMouse(.leftMouseDown, screen: initialPoint, window: initialBody)
        sendMouse(.leftMouseDragged, screen: releasePoint, window: initialBody)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        sendMouse(.leftMouseUp, screen: releasePoint, window: initialBody)
        XCTAssertTrue(controller.isEdgePeekedForTesting(key: key), "Start with a real body mouse drag and tuck")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let peek = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        let down = NSPoint(x: peek.frame.midX, y: peek.frame.midY)
        let direction: CGFloat = side == .right ? -1 : 1
        sendMouse(.leftMouseDown, screen: down, window: peek)
        let threshold = NSPoint(x: down.x + direction * 8, y: down.y)
        sendMouse(.leftMouseDragged, screen: threshold, window: peek)
        let model = try XCTUnwrap(petModel())
        XCTAssertTrue(model.isAnimationDragging)
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        let interior = NSPoint(x: down.x + direction * 220, y: down.y)
        sendMouse(.leftMouseDragged, screen: interior, window: peek)
        if releaseDelay > 0 { RunLoop.main.run(until: Date().addingTimeInterval(releaseDelay)) }
        sendMouse(.leftMouseUp, screen: interior, window: body)
        XCTAssertFalse(controller.isEdgePeekedForTesting(key: key))
        XCTAssertFalse(model.isAnimationDragging)
        let afterPeek = model.animationDragSession
        // Let the latest body marker mount, then issue repeated complete mouse
        // sequences without long holds. Every new drag must start AND move.
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        for round in 0..<3 {
            let marker = try XCTUnwrap(model.petBodyView)
            let local = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
            let start = body.convertPoint(toScreen: local)
            let origin = body.frame.origin
            let session = model.animationDragSession
            sendMouse(.leftMouseDown, screen: start, window: body, clicks: round == 0 ? 2 : 1)
            sendMouse(.leftMouseDragged, screen: NSPoint(x: start.x + direction * 3, y: start.y), window: body)
            XCTAssertFalse(model.isAnimationDragging, "A subthreshold press must not start drag \(round)")
            XCTAssertEqual(body.frame.minX, origin.x, accuracy: 0.1)
            sendMouse(.leftMouseDragged, screen: NSPoint(x: start.x + direction * 9, y: start.y), window: body)
            XCTAssertTrue(model.isAnimationDragging, "Repeated normal drag must start without an extra release/hold")
            XCTAssertEqual(model.animationDragSession, session + 1)
            XCTAssertEqual(body.frame.minX, origin.x + direction * 9, accuracy: 1)
            // A model/render update inside the same held sequence must not
            // replace the event owner or reset its movement anchor.
            model.chatLine = "test-render-update-\(round)"
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            sendMouse(.leftMouseDragged, screen: NSPoint(x: start.x + direction * 28, y: start.y + 4), window: body)
            XCTAssertEqual(body.frame.minX, origin.x + direction * 28, accuracy: 1)
            sendMouse(.leftMouseUp, screen: NSPoint(x: start.x + direction * 34, y: start.y + 4), window: body)
            XCTAssertEqual(body.frame.minX, origin.x + direction * 34, accuracy: 1,
                           "Consume the final mouse-up coordinate once")
            XCTAssertFalse(model.isAnimationDragging)
            XCTAssertEqual(model.animationDragSession, session + 1)
            XCTAssertNil(controller.expandOverlayPanelForTesting(key: key))
            XCTAssertEqual(body.contentView?.layer?.opacity, 1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        print("REPEATED_BODY_DRAG side=\(side) delay=\(releaseDelay) sessionAfterPeek=\(afterPeek) finalSession=\(model.animationDragSession)")
        RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.1))
        XCTAssertEqual(model.petTapCount, 0, "Repeated drags must not leak ordinary clicks")
    }

    func testRightPeekDragOutThenImmediateBodyDragsMoveOnEverySequence() throws {
        try checkImmediateBodyDragAfterPeek(side: .right, releaseDelay: 0)
    }

    func testLeftPeekDragOutThenImmediateBodyDragsMoveOnEverySequence() throws {
        try checkImmediateBodyDragAfterPeek(side: .left, releaseDelay: 0.4)
    }

    func testAnimationStartedWithoutSwiftUIMoveStillFollowsTheCurrentMouseSequence() throws {
        try loadDefaultPack()
        let controller = try prepare()
        controller.start()
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        let model = try XCTUnwrap(petModel())
        let marker = try XCTUnwrap(model.petBodyView)
        let host = try XCTUnwrap(body.contentView as? ClickThroughHostingView<FloatingPetView>)
        let start = body.convertPoint(toScreen: marker.convert(
            NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil))
        let origin = body.frame.origin
        sendMouse(.leftMouseDown, screen: start, window: body)
        // Reproduce the split lifecycle: playback has started but a view/gesture
        // replacement does not deliver its move callback. The event owner must
        // still move from this press, rather than demand another press.
        host.rootView.windowInteraction.dragBegan()
        XCTAssertTrue(model.isAnimationDragging)
        sendMouse(.leftMouseDragged, screen: NSPoint(x: start.x - 25, y: start.y), window: body)
        XCTAssertEqual(body.frame.minX, origin.x - 25, accuracy: 1)
        sendMouse(.leftMouseUp, screen: NSPoint(x: start.x - 30, y: start.y), window: body)
        XCTAssertFalse(model.isAnimationDragging)
        XCTAssertEqual(body.frame.minX, origin.x - 30, accuracy: 1)
    }

    func testPeekExpansionAndFirstSampleWaitForTheConfiguredDragSession() throws {
        try loadDefaultPack()
        let controller = try prepare()
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        let peek = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        let point = NSPoint(x: peek.frame.width / 2, y: peek.frame.height / 2)
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: peek))
        controller.handlePetClickEvent(event(.leftMouseDragged,
            at: NSPoint(x: point.x - 8, y: point.y), in: peek))
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        let model = try XCTUnwrap(petModel())
        XCTAssertTrue(model.isAnimationDragging)
        XCTAssertEqual(body.contentView?.layer?.opacity, 0,
                       "The live body must not appear full-size outside the held peek mesh")
        XCTAssertNotNil(controller.expandOverlayPanelForTesting(key: key))
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let source = try XCTUnwrap(controller.preparedSnapshotForTesting(key: key)?.videoSource)
        XCTAssertEqual(source.identity.selectionKey, "drag")
        XCTAssertEqual(source.identity.dragSession, model.animationDragSession)
        let expansion = try XCTUnwrap(controller.lastExpansionIdentityForTesting)
        XCTAssertEqual(expansion.selectionKey, "drag", "Never use the pre-drag idle target")
        XCTAssertEqual(expansion.dragSession, model.animationDragSession)
        XCTAssertEqual(expansion.url, source.identity.url)
        XCTAssertEqual(body.contentView?.layer?.opacity, 1)
        XCTAssertNil(controller.expandOverlayPanelForTesting(key: key))
    }

    func testReleaseUsesLatestTaskContextAndTheNextDragStartsANewSession() throws {
        try loadDefaultPack()
        let controller = try prepare()
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        let host = try XCTUnwrap(body.contentView as? ClickThroughHostingView<FloatingPetView>)
        let model = host.rootView.model
        // Release in the middle so the latest task state is actually displayed.
        let screen = try XCTUnwrap(body.screen?.visibleFrame)
        body.setFrameOrigin(NSPoint(x: screen.midX, y: screen.midY))
        host.rootView.windowInteraction.dragBegan()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let old = try XCTUnwrap(controller.preparedSnapshotForTesting(key: key))
        let firstSession = model.animationDragSession
        model.mood = .working
        var latest = model.animationContext
        latest.baseKey = "working"
        latest.baseTrigger = "working:new-task-during-drag"
        model.animationContext = latest
        host.rootView.windowInteraction.dragEnded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(controller.isEdgePeekedForTesting(key: key))
        XCTAssertEqual(PetEdgeSnapshotter.videoView(model: model)?.frameIdentity?.selectionKey, "working")
        host.rootView.windowInteraction.dragBegan()
        XCTAssertGreaterThan(model.animationDragSession, firstSession)
        XCTAssertNil(PetEdgeSnapshotter.rebased(old, model: model,
            dragSession: model.animationDragSession))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let payload = try XCTUnwrap(PetEdgeSnapshotter.videoView(model: model)?.currentSamplingPayload())
        XCTAssertEqual(payload.identity.selectionKey, "drag")
        XCTAssertEqual(payload.identity.dragSession, model.animationDragSession)
        XCTAssertLessThan(payload.time.seconds, 0.5, "Each real drag restarts the movie at zero")
    }

    func testImmediateReleaseDuringExpansionCollapsesTheVisiblePeekAndRestoresBodyPixels() throws {
        try loadDefaultPack()
        let controller = try prepare()
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        let peek = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        let expected = peek.frame
        let point = NSPoint(x: expected.width / 2, y: expected.height / 2)
        let dragPoint = NSPoint(x: point.x - 8, y: point.y)
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: peek))
        controller.handlePetClickEvent(event(.leftMouseDragged, at: dragPoint, in: peek))
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        XCTAssertEqual(body.contentView?.layer?.opacity, 0)
        controller.handlePetClickEvent(event(.leftMouseUp, at: dragPoint, in: peek))
        XCTAssertTrue(controller.isEdgePeekedForTesting(key: key))
        let source = try XCTUnwrap(controller.lastCollapseSourceFrameForTesting)
        XCTAssertEqual(source.midX, expected.midX, accuracy: 1)
        XCTAssertEqual(source.midY, expected.midY, accuracy: 1)
        XCTAssertEqual(source.height, expected.height, accuracy: 1)
        XCTAssertEqual(body.contentView?.layer?.opacity, 1,
                       "Cancellation must not leave the next drag's live body invisible")
        XCTAssertNil(controller.expandOverlayPanelForTesting(key: key))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(peek.isVisible)
        XCTAssertNil(controller.edgeTransitionPanelForTesting(key: key))
    }

    func testPreparedFrameIsRejectedAfterTokenOrSessionChanges() throws {
        try loadDefaultPack()
        let controller = try prepare()
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        let host = try XCTUnwrap(body.contentView as? ClickThroughHostingView<FloatingPetView>)
        let model = host.rootView.model
        host.rootView.windowInteraction.dragBegan()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let sample = try XCTUnwrap(controller.preparedSnapshotForTesting(key: key))
        let video = try XCTUnwrap(PetEdgeSnapshotter.videoView(model: model))
        let id = try XCTUnwrap(video.frameIdentity)
        let pack = try XCTUnwrap(ImagePetStore.shared.pack(id: "deepseek"))
        let clip = try XCTUnwrap(pack.videoClips.first { $0.url == id.url })
        video.configure(clip: clip, loop: false, token: id.token + 1, animate: true,
                        onFinished: nil, onFailure: nil, selectionKey: "drag",
                        dragSession: model.animationDragSession)
        XCTAssertNil(PetEdgeSnapshotter.rebased(sample, model: model,
            dragSession: model.animationDragSession), "An old playback token must not leak into a collapse")
        video.configure(clip: clip, loop: false, token: id.token + 2, animate: true,
                        onFinished: nil, onFailure: nil, selectionKey: "idle",
                        dragSession: model.animationDragSession - 1)
        var called = false
        XCTAssertNil(PetEdgeSnapshotter.sampleAsync(model: model,
            dragSession: model.animationDragSession) { value in
                XCTAssertNil(value)
                called = true
            }, "Do not even enqueue a decode before the requested drag selection is applied")
        XCTAssertTrue(called)
    }

    func testSampleThenMoveBeforeReleaseRebasesCollapseToTheCurrentPosition() throws {
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let pets = URL(fileURLWithPath: AgentPetPaths.baseDir).appendingPathComponent("pets")
        try FileManager.default.createDirectory(at: pets, withIntermediateDirectories: true)
        let installed = pets.appendingPathComponent("deepseek")
        if !FileManager.default.fileExists(atPath: installed.path) {
            try FileManager.default.copyItem(at: directory, to: installed)
        }
        ImagePetStore.shared.reload()
        let controller = try prepare()
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        let host = try XCTUnwrap(body.contentView as? ClickThroughHostingView<FloatingPetView>)
        let visible = try XCTUnwrap(body.screen?.visibleFrame)
        body.setFrameOrigin(NSPoint(x: visible.maxX - body.frame.width - 70,
                                    y: visible.minY + 120))
        host.rootView.windowInteraction.dragBegan()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let prepared = try XCTUnwrap(controller.preparedSnapshotForTesting(key: key))
        let before = body.frame.origin
        let moveX = visible.maxX - prepared.frame.maxX - 8
        body.setFrameOrigin(NSPoint(x: before.x + moveX, y: before.y + 7))
        let delta = NSPoint(x: body.frame.minX - before.x, y: body.frame.minY - before.y)
        // No run-loop turn: release must rebase the already-prepared sample,
        // rather than rely on the next timer firing at the new position.
        host.rootView.windowInteraction.dragEnded()
        let source = try XCTUnwrap(controller.lastCollapseSourceFrameForTesting)
        XCTAssertEqual(source.minX, prepared.frame.minX + delta.x, accuracy: 1)
        XCTAssertEqual(source.minY, prepared.frame.minY + delta.y, accuracy: 1)
    }

    private func releaseNormallyDraggedBody(side: PetEdgeSide, outward: CGFloat,
                                            missingAsset: Bool = false,
                                            missingSnapshot: Bool = false,
                                            fullyOutsideY: Bool = false,
                                            remainingVisible: CGFloat? = nil,
                                            canvasDistance: Bool = false) throws {
        try loadDefaultPack()
        let controller = try prepare()
        defer {
            controller.stop()
            PetEdgeStateStore().clear(forKey: key)
            PetController.shared.petPoint = savedSize
            PetController.shared.animationsEnabled = savedAnimations
        }
        if missingAsset { controller.peekAssetOverride = { _ in nil } }
        controller.forceStaticSnapshotFailureForTesting = missingSnapshot
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        let model = try XCTUnwrap(petModel())
        let marker = try XCTUnwrap(model.petBodyView)
        let host = try XCTUnwrap(body.contentView as? ClickThroughHostingView<FloatingPetView>)
        let screens = NSScreen.screens.map { PetEdgeScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let index = try XCTUnwrap(screens.indices.first { index in
            let f = screens[index].visibleFrame
            return PetEdgeGeometry.isOuterEdge(side, screenIndex: index,
                verticalBand: CGRect(x: f.midX, y: f.midY - 35, width: 70, height: 70), screens: screens)
        })
        let visible = screens[index].visibleFrame
        // Begin in the interior and let the real drag selection and prepared
        // sample land before the final movement. Release itself uses the local
        // mouse-event route, not enterEdgePeekForTesting or Geometry.snap.
        body.setFrameOrigin(NSPoint(x: visible.midX - body.frame.width / 2,
                                    y: visible.midY - body.frame.height / 2))
        host.rootView.windowInteraction.dragBegan()
        if !missingSnapshot && !missingAsset {
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            XCTAssertNotNil(controller.preparedSnapshotForTesting(key: key))
        }
        let canvas = body.convertToScreen(marker.convert(marker.bounds, to: nil))
        let content = PetEdgeSnapshotter.rebased(controller.preparedSnapshotForTesting(key: key),
            model: model, dragSession: model.animationDragSession)?.frame
            ?? PetEdgeSnapshotter.captureStatic(model: model)?.frame ?? canvas
        let current = canvasDistance ? canvas : content
        let displacement = remainingVisible.map { current.width - $0 } ?? outward
        let x = side == .right ? visible.maxX - current.width + displacement : visible.minX - displacement
        // NSWindow constrains moves above the menu bar; use the lower side
        // for a genuinely out-of-range native window, and cover both vertical
        // directions with synthetic screens in PetEdgeGeometryTests.
        let y = fullyOutsideY ? visible.minY - current.height - 20 : visible.midY - current.height / 2
        body.setFrameOrigin(NSPoint(x: body.frame.minX + x - current.minX,
                                    y: body.frame.minY + y - current.minY))
        let release = body.convertToScreen(marker.convert(marker.bounds, to: nil))
        if fullyOutsideY { XCTAssertLessThan(release.maxY, visible.minY) }
        let visibleRelease = content.offsetBy(dx: release.minX - canvas.minX, dy: release.minY - canvas.minY)
        if remainingVisible != nil {
            let overlap = visibleRelease.intersection(visible)
            XCTAssertGreaterThan(overlap.width, 0)
            XCTAssertLessThan(overlap.width, 3, "Exercise the almost-invisible release, not a partly-visible proxy")
        }
        let point = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
        controller.handlePetClickEvent(event(.leftMouseUp, at: point, in: body))
        let visibleGap = side == .right ? visible.maxX - visibleRelease.maxX : visibleRelease.minX - visible.minX
        if canvasDistance { XCTAssertGreaterThan(visibleGap, 20, "Reproduce invisible movie margin reaching the edge first") }
        let shouldTuck = !missingAsset && !missingSnapshot && !fullyOutsideY && visibleGap <= 10
            && visibleRelease.intersects(visible)
        print("OUTWARD_MOUSE_UP side=\(side) outward=\(displacement) noAsset=\(missingAsset) noSnapshot=\(missingSnapshot) verticalOut=\(fullyOutsideY) release=\(release) visible=\(visible) tuck=\(controller.isEdgePeekedForTesting(key: key))")
        XCTAssertEqual(controller.isEdgePeekedForTesting(key: key), shouldTuck)
        XCTAssertFalse(model.isAnimationDragging)
        if shouldTuck {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let peek = try XCTUnwrap(controller.peekPanelForTesting(key: key))
            XCTAssertTrue(peek.isVisible)
            XCTAssertEqual(side == .right ? peek.frame.maxX : peek.frame.minX,
                           side == .right ? visible.maxX : visible.minX, accuracy: 0.5)
            XCTAssertNil(controller.edgeTransitionPanelForTesting(key: key))
        } else {
            XCTAssertTrue(body.isVisible)
            let recovered = body.convertToScreen(marker.convert(marker.bounds, to: nil))
            XCTAssertTrue(recovered.intersects(visible), "Declined tuck must keep the ordinary pet recoverable")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            XCTAssertFalse(controller.isEdgePeekedForTesting(key: key), "Deferred relayout must not reapply the transparent canvas threshold")
        }
    }

    func testTransparentMoviePaddingDoesNotTriggerAtEitherEdge() throws {
        for side in PetEdgeSide.allCases {
            try releaseNormallyDraggedBody(side: side, outward: -8, canvasDistance: true)
        }
    }

    func testRightMouseUpSnapsAtNearInsidePartiallyOutsideAndAlmostInvisiblePositions() throws {
        for outward: CGFloat in [-10.5, -10, -9.5, 25, 55] {
            try releaseNormallyDraggedBody(side: .right, outward: outward)
        }
        try releaseNormallyDraggedBody(side: .right, outward: 0, remainingVisible: 2)
    }

    func testLeftMouseUpSnapsAtNearInsidePartiallyOutsideAndAlmostInvisiblePositions() throws {
        for outward: CGFloat in [-10.5, -10, -9.5, 25, 55] {
            try releaseNormallyDraggedBody(side: .left, outward: outward)
        }
        try releaseNormallyDraggedBody(side: .left, outward: 0, remainingVisible: 2)
    }

    func testOutwardMouseUpStillRecoversWhenCompletelyOutsideOrMediaUnavailable() throws {
        for side in PetEdgeSide.allCases {
            try releaseNormallyDraggedBody(side: side, outward: 160)
            try releaseNormallyDraggedBody(side: side, outward: 55, missingAsset: true)
            try releaseNormallyDraggedBody(side: side, outward: 55, missingSnapshot: true)
            try releaseNormallyDraggedBody(side: side, outward: 55, fullyOutsideY: true)
        }
    }

    func testCollapseWithoutAnyVisibleSnapshotKeepsBodyAndDoesNotHideFirst() throws {
        let controller = try prepare()
        controller.forceStaticSnapshotFailureForTesting = true
        XCTAssertFalse(controller.enterEdgePeekForTesting(key: key, side: .right, animated: true))
        XCTAssertFalse(controller.isEdgePeekedForTesting(key: key))
        XCTAssertTrue(bodyWindow(visibleOnly: true) != nil,
                      "A failed snapshot must leave the ordinary body visible, not a blank gap")
        controller.forceStaticSnapshotFailureForTesting = false
    }

    func testProductionCollapseUsesFunnelAndCrossfadesIntoPeek() throws {
        try loadDefaultPack()
        let controller = try prepare()
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        let host = try XCTUnwrap(body.contentView as? ClickThroughHostingView<FloatingPetView>)
        let visible = try XCTUnwrap(body.screen?.visibleFrame)
        body.setFrameOrigin(NSPoint(x: visible.maxX - body.frame.width + 3,
                                    y: visible.minY + 120))
        host.rootView.windowInteraction.dragBegan()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let source = try XCTUnwrap(controller.preparedSnapshotForTesting(key: key))
        body.setFrameOrigin(NSPoint(x: body.frame.minX + visible.maxX - source.frame.maxX - 8,
                                    y: body.frame.minY))
        host.rootView.windowInteraction.dragEnded()
        XCTAssertTrue(controller.isEdgePeekedForTesting(key: key))
        XCTAssertNotNil(controller.edgeTransitionPanelForTesting(key: key),
                        "The production collapse must use the interactive funnel")
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        let peek = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        XCTAssertTrue(peek.isVisible)
        XCTAssertEqual(peek.alphaValue, 1, accuracy: 0.01)
        XCTAssertNil(controller.edgeTransitionPanelForTesting(key: key),
                     "The final mesh is removed only after the peek fade")
    }

    func testCollapseOverlayAcceptsDownDragAndCancelsIntoExpansion() throws {
        let controller = try prepare()
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        let overlay = try XCTUnwrap(controller.startEdgeTransitionForTesting(key: key, duration: 0.5),
                                    "The collapse funnel must expose an interactive hit panel")
        XCTAssertFalse(overlay.ignoresMouseEvents,
                       "The visible funnel must not pass clicks through to the desktop")
        let host = try XCTUnwrap(overlay.contentView)
        let point = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: overlay))
        XCTAssertTrue(controller.isEdgePeekedForTesting(key: key))
        XCTAssertFalse(controller.isExpandTransitioningForTesting(key: key),
                       "A mere press on the funnel must not start a drag")
        controller.handlePetClickEvent(event(.leftMouseDragged,
                                             at: NSPoint(x: point.x - 8, y: point.y), in: overlay))
        XCTAssertFalse(controller.isEdgePeekedForTesting(key: key))
        XCTAssertTrue(controller.isExpandTransitioningForTesting(key: key),
                      "The first actual drag immediately expands from the visible funnel")
        let body = try XCTUnwrap(bodyWindow(visibleOnly: true))
        let model = try XCTUnwrap((body.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model)
        XCTAssertTrue(model.isAnimationDragging)
        let origin = body.frame.origin
        controller.handlePetClickEvent(event(.leftMouseDragged,
                                             at: NSPoint(x: point.x - 18, y: point.y), in: overlay))
        XCTAssertGreaterThan(abs(body.frame.minX - origin.x) + abs(body.frame.minY - origin.y), 5,
                             "The same overlay-routed drag must keep moving the body")
        controller.handlePetClickEvent(event(.leftMouseUp,
                                             at: NSPoint(x: point.x - 10, y: point.y), in: overlay))
        XCTAssertFalse(model.isAnimationDragging)
    }

    func testCollapseOverlayPressReleaseDoesNotStartADrag() throws {
        let controller = try prepare()
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        let overlay = try XCTUnwrap(controller.startEdgeTransitionForTesting(key: key, duration: 0.2))
        let point = NSPoint(x: overlay.frame.width / 2, y: overlay.frame.height / 2)
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: overlay))
        XCTAssertFalse(try XCTUnwrap(petModel()).isAnimationDragging)
        controller.handlePetClickEvent(event(.leftMouseUp, at: point, in: overlay))
        RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.3))
        XCTAssertFalse(try XCTUnwrap(petModel()).isAnimationDragging)
        XCTAssertEqual(petModel()?.petTapCount, 1)
        XCTAssertTrue(controller.isEdgePeekedForTesting(key: key))
        XCTAssertNil(controller.expandOverlayPanelForTesting(key: key))
    }

    func testBodyRoutedDragAfterPeekOrderOutContinuesMoving() throws {
        let controller = try prepare()
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        let peek = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        let host = try XCTUnwrap(controller.peekHostForTesting(key: key))
        let point = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: peek))
        controller.handlePetClickEvent(event(.leftMouseDragged,
                                             at: NSPoint(x: point.x - 8, y: point.y), in: peek))
        let body = try XCTUnwrap(bodyWindow(visibleOnly: true))
        let before = body.frame.origin
        // The peek panel is ordered out at drag start; AppKit may deliver the
        // rest of the sequence to the now-visible body instead.
        controller.handlePetClickEvent(event(.leftMouseDragged,
                                             at: NSPoint(x: point.x - 18, y: point.y), in: body))
        XCTAssertGreaterThan(abs(body.frame.minX - before.x) + abs(body.frame.minY - before.y), 5,
                             "Body-routed drag must continue the peek drag lifecycle")
        controller.handlePetClickEvent(event(.leftMouseUp,
                                             at: NSPoint(x: point.x - 18, y: point.y), in: body))
        let model = try XCTUnwrap((body.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model)
        XCTAssertFalse(model.isAnimationDragging)
    }

    func testDragDuringPeekCrossfadeUsesTheVisibleCompositeAndCancelsOldCompletion() throws {
        let controller = try prepare()
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        let overlay = try XCTUnwrap(controller.startEdgeTransitionForTesting(key: key, duration: 0.01))
        // Advance the native display loop only until the actual crossfade starts.
        var reachedFade = false
        for _ in 0..<40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            reachedFade = overlay.contentView?.layer?.sublayers?.contains {
                $0.animation(forKey: "petEdgePeekIn") != nil
            } == true
            if reachedFade { break }
        }
        XCTAssertTrue(reachedFade)
        let peek = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        XCTAssertEqual(peek.alphaValue, 0, "The visible peek belongs to the overlay until handoff")
        let screenPoint = NSPoint(x: peek.frame.midX, y: peek.frame.midY)
        let point = overlay.convertPoint(fromScreen: screenPoint)
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: overlay))
        XCTAssertFalse(try XCTUnwrap(petModel()).isAnimationDragging)
        controller.handlePetClickEvent(event(.leftMouseDragged,
            at: NSPoint(x: point.x - 9, y: point.y), in: overlay))
        XCTAssertFalse(controller.isEdgePeekedForTesting(key: key))
        XCTAssertTrue(try XCTUnwrap(petModel()).isAnimationDragging)
        XCTAssertNotNil(controller.expandOverlayPanelForTesting(key: key))
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        let start = body.frame.minX
        controller.handlePetClickEvent(event(.leftMouseDragged,
            at: NSPoint(x: point.x - 90, y: point.y), in: overlay))
        XCTAssertLessThan(body.frame.minX, start - 60)
        controller.handlePetClickEvent(event(.leftMouseUp,
            at: NSPoint(x: point.x - 90, y: point.y), in: overlay))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(try XCTUnwrap(petModel()).isAnimationDragging)
        XCTAssertFalse(controller.isEdgePeekedForTesting(key: key), "Old fade completion cannot re-hide the pet")
        XCTAssertNil(controller.expandOverlayPanelForTesting(key: key))
        XCTAssertNil(controller.edgeTransitionPanelForTesting(key: key))
        XCTAssertEqual(body.contentView?.layer?.opacity, 1)
    }

    func testInteractiveCollapseCrossfadesIntoPeekWithoutHardRemoval() throws {
        let controller = try prepare()
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        _ = try XCTUnwrap(controller.startEdgeTransitionForTesting(key: key, duration: 0.06))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertTrue(controller.isEdgePeekedForTesting(key: key))
        let peek = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        XCTAssertTrue(peek.isVisible)
        XCTAssertEqual(peek.alphaValue, 1, accuracy: 0.01)
        XCTAssertNil(controller.edgeTransitionPanelForTesting(key: key))
    }

    func testPeekIsContentSizedAndMirrorsTheEdge() throws {
        let controller = try prepare()
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        let panel = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.height, 50, accuracy: 0.5)
        XCTAssertLessThanOrEqual(panel.frame.width, 44.001)
        let visible = try XCTUnwrap(panel.screen?.visibleFrame)
        if let asset {
            let expected = try XCTUnwrap(PetEdgeGeometry.peekLayout(
                anchor: NSPoint(x: visible.maxX, y: panel.frame.midY - 35),
                petSize: 70, contentSize: asset.contentSize, visible: visible, side: .right))
            XCTAssertEqual(panel.frame.width, expected.frame.width, accuracy: 0.6)
        }
        // The body panel is hidden while the independent peek is shown.
        XCTAssertNil(bodyWindow(visibleOnly: true), "The body panel stays hidden while the independent peek is shown")
        XCTAssertTrue(panel.isVisible)
    }

    func testNativeBackgroundDragIsIsolatedFromTheCustomGesture() throws {
        let controller = try prepare()
        let body = try XCTUnwrap(controller.bodyPanelForTesting(key: key))
        XCTAssertFalse(body.isMovableByWindowBackground,
                       "Native background dragging/snapping must not compete with the pet gesture")
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        let peek = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        XCTAssertFalse(peek.isMovableByWindowBackground)
    }

    func testPeekSingleDoubleAndRightClickKeepR1Semantics() throws {
        let controller = try prepare()
        let settings = BubbleSettings.shared
        let oldPreference = settings.taskBubbleClickThrough
        let oldSuperchat = settings.superchatEnabled
        settings.taskBubbleClickThrough = false
        settings.superchatEnabled = true
        defer {
            settings.taskBubbleClickThrough = oldPreference
            settings.superchatEnabled = oldSuperchat
            controller.closeStatsPopover()
        }
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        let panel = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        let host = try XCTUnwrap(controller.peekHostForTesting(key: key))
        let state = try XCTUnwrap((host as? ClickThroughHostingView<EdgePeekView>)?.rootView.state)
        let point = NSPoint(x: host.bounds.midX, y: host.bounds.midY)

        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: panel))
        controller.handlePetClickEvent(event(.leftMouseUp, at: point, in: panel))
        RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval * 0.4))
        XCTAssertEqual(state.side, .right)
        RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.2))
        XCTAssertEqual(petModel()?.petTapCount, 1, "A peek single click keeps the original pet reaction")
        XCTAssertFalse(settings.taskBubbleClickThrough, "A single peek click never toggles")

        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: panel, clicks: 1))
        controller.handlePetClickEvent(event(.leftMouseUp, at: point, in: panel, clicks: 1))
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: panel, clicks: 2))
        controller.handlePetClickEvent(event(.leftMouseUp, at: point, in: panel, clicks: 2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(settings.taskBubbleClickThrough, "A peek double-click toggles once")

        let right = event(.rightMouseDown, at: point, in: panel)
        XCTAssertTrue(controller.handlePetRightClickEvent(right))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(controller.isStatsPresentedForTesting, "Peek right-click opens Stats")
        let stats = try XCTUnwrap(controller.statsFrameForTesting)
        let available = try XCTUnwrap(panel.screen?.visibleFrame)
        XCTAssertGreaterThanOrEqual(stats.minX, available.minX)
        XCTAssertLessThanOrEqual(stats.maxX, available.maxX)
        XCTAssertGreaterThanOrEqual(stats.minY, available.minY)
        XCTAssertLessThanOrEqual(stats.maxY, available.maxY)
        XCTAssertEqual(stats.midX, panel.frame.midX, accuracy: 160,
                       "Stats must follow the visible peek anchor, not the hidden body")
    }

    func testPeekDragImmediatelyShowsFullPetAndStartsDragState() throws {
        let controller = try prepare()
        XCTAssertTrue(controller.enterEdgePeekForTesting(key: key, side: .right))
        let panel = try XCTUnwrap(controller.peekPanelForTesting(key: key))
        let host = try XCTUnwrap(controller.peekHostForTesting(key: key))
        let point = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        controller.handlePetClickEvent(event(.leftMouseDown, at: point, in: panel))
        let dragged = NSPoint(x: point.x - 8, y: point.y)
        controller.handlePetClickEvent(event(.leftMouseDragged, at: dragged, in: panel))
        XCTAssertFalse(controller.isEdgePeekedForTesting(key: key),
                       "A real drag exits the tuck immediately")
        let body = try XCTUnwrap(bodyWindow(visibleOnly: true))
        let model = try XCTUnwrap((body.contentView as? ClickThroughHostingView<FloatingPetView>)?.rootView.model)
        XCTAssertEqual(model.key, key)
        XCTAssertTrue(model.isAnimationDragging, "The drag movie starts from frame 0 at threshold")
        XCTAssertTrue(model.isOnScreen, "The hidden body's animation clock resumes for the drag")
        XCTAssertTrue(controller.isExpandTransitioningForTesting(key: key),
                      "Peek expansion uses the continuous edge funnel, not an overall scale")
        let overlay = try XCTUnwrap(controller.expandOverlayPanelForTesting(key: key))
        XCTAssertNotNil(overlay.parent, "The expand funnel is a child of the moving body")
        let overlayOrigin = overlay.frame.origin
        let bodyOrigin = body.frame.origin
        controller.handlePetClickEvent(event(.leftMouseDragged,
                                             at: NSPoint(x: point.x - 20, y: point.y), in: body))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bodyDelta = body.frame.minX - bodyOrigin.x
        XCTAssertGreaterThan(abs(bodyDelta), 5, "The live body follows the cursor 1:1")
        XCTAssertEqual(overlay.frame.minX - overlayOrigin.x, bodyDelta, accuracy: 1.0,
                       "The expand funnel is a child of the moving body, not a fixed screen snapshot")
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        XCTAssertFalse(controller.isExpandTransitioningForTesting(key: key))
        XCTAssertNil(controller.expandOverlayPanelForTesting(key: key))
        controller.handlePetClickEvent(event(.leftMouseUp, at: NSPoint(x: point.x - 12, y: point.y),
                                             in: panel))
        XCTAssertFalse(model.isAnimationDragging)
    }


    func testPersistedSideWithMissingPeekArtRestoresOrdinaryVisiblePetAndClearsSide() throws {
        let first = try prepare()
        XCTAssertTrue(first.enterEdgePeekForTesting(key: key, side: .right, persist: true))
        first.stop()
        self.controller = nil

        let restarted = PetWindowController()
        self.controller = restarted
        restarted.peekAssetOverride = { _ in nil }
        let spec = PetWindowSpec(key: key, projectName: "r2", petID: "deepseek",
                                 sessionIDs: [], mood: .idle, count: 0)
        restarted.sync(specs: [spec]) { _ in
            .init(petID: "deepseek", mood: .idle, sessions: [], count: 0, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(restarted.isEdgePeekedForTesting(key: key))
        XCTAssertTrue(bodyWindow(visibleOnly: true) != nil,
                      "A missing peek asset must leave the ordinary pet visible and interactive")
        XCTAssertNil(PetEdgeStateStore().side(forKey: key))
    }

    func testPersistedSideRestoresAfterRestartAndBadSideFallsBackVisible() throws {
        let first = try prepare()
        XCTAssertTrue(first.enterEdgePeekForTesting(key: key, side: .left, persist: true))
        XCTAssertTrue(first.isEdgePeekedForTesting(key: key))
        first.stop()
        self.controller = nil

        let restarted = PetWindowController()
        self.controller = restarted
        restarted.peekAssetOverride = { [asset] _ in asset }
        let spec = PetWindowSpec(key: key, projectName: "r2", petID: "deepseek",
                                 sessionIDs: [], mood: .idle, count: 0)
        restarted.sync(specs: [spec]) { _ in
            .init(petID: "deepseek", mood: .idle, sessions: [], count: 0, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(restarted.isEdgePeekedForTesting(key: key),
                      "A persisted side restores once the pack/peek asset is available")

        PetEdgeStateStore().clear(forKey: key)
        restarted.stop()
        self.controller = nil
    }

    func testExternalPetWithoutOwnStickerTucksAndRestoresUsingBundledFallback() throws {
        let source = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            source.appendingPathComponent("pet.json"))) as? [String: Any])
        let id = "r3-external-\(UUID().uuidString)"
        manifest["id"] = id
        let directory = URL(fileURLWithPath: AgentPetPaths.baseDir).appendingPathComponent("pets/\(id)")
        let sheet = try XCTUnwrap(manifest["spritesheetPath"] as? String)
        let destination = directory.appendingPathComponent(sheet)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.appendingPathComponent(sheet), to: destination)
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("pet.json"))
        defer {
            try? FileManager.default.removeItem(at: directory)
            ImagePetStore.shared.reload()
        }
        ImagePetStore.shared.reload()
        let pack = try XCTUnwrap(ImagePetStore.shared.pack(id: id))
        XCTAssertNil(pack.peekAsset)
        XCTAssertNotNil(pack.effectivePeekAsset)
        let first = try prepare()
        first.peekAssetOverride = nil
        let spec = PetWindowSpec(key: key, projectName: "external", petID: id,
                                 sessionIDs: [], mood: .idle, count: 0)
        first.sync(specs: [spec]) { _ in
            .init(petID: id, mood: .idle, sessions: [], count: 0, chatLine: "")
        }
        XCTAssertTrue(first.enterEdgePeekForTesting(key: key, side: .left, persist: true))
        XCTAssertEqual(petModel()?.petID, id, "Tucking must preserve the chosen external pet")
        first.stop()
        let restarted = PetWindowController()
        self.controller = restarted
        restarted.sync(specs: [spec]) { _ in
            .init(petID: id, mood: .idle, sessions: [], count: 0, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(restarted.isEdgePeekedForTesting(key: key), "Restart resolves the same bundled fallback without an override")
        XCTAssertEqual(petModel()?.petID, id)
        restarted.stop()
    }

}
