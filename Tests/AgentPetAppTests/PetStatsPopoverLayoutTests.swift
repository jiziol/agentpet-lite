import AppKit
import QuartzCore
import SwiftUI
import XCTest
import AgentPetCore
@testable import agentpet

@MainActor
final class PetStatsPopoverLayoutTests: XCTestCase {
    func testApplicationDeactivationResetsHiddenStatusAndAllowsImmediateReopen() throws {
        try TestIsolation.require()
        _ = NSApplication.shared
        let controller = PetStatsPanelController()
        defer { controller.dismissImmediately() }
        let frame = NSRect(x: 100, y: 200, width: 300, height: 100)
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        var closed = 0, messagesHidden = false
        controller.show(content: content, frame: frame, petBody: { nil }, animated: false,
            hideMessages: { messagesHidden = true }, onClose: { messagesHidden = false; closed += 1 })
        let window = try XCTUnwrap(content.window)
        // AppKit hides the panel without generating an outside mouse click.
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(messagesHidden)
        XCTAssertEqual(closed, 1)
        controller.show(content: NSView(), frame: frame, petBody: { nil }, animated: false)
        XCTAssertEqual(controller.phase, .shown)
        XCTAssertTrue(controller.isShown, "One subsequent open must work without a blank-space click")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        XCTAssertTrue(controller.isShown)
        XCTAssertEqual(closed, 1)
    }

    func testApplicationDeactivationCancelsOpeningGenies() throws {
        try TestIsolation.require()
        _ = NSApplication.shared
        for hidingMessages in [false, true] {
            let controller = PetStatsPanelController(statusDuration: 0.2, messageDuration: 0.2)
            defer { controller.dismissImmediately() }
            let frame = NSRect(x: 100, y: 200, width: 300, height: 100)
            var closed = 0
            controller.show(content: NSView(frame: NSRect(origin: .zero, size: frame.size)),
                frame: frame, petBody: { nil },
                messages: hidingMessages ? try solidSnapshot(frame: frame) : nil, onClose: { closed += 1 })
            XCTAssertEqual(controller.phase, hidingMessages ? .hidingMessages : .openingStatus)
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
            XCTAssertEqual(controller.phase, .hidden, "Switching apps during opening must release the status latch")
            XCTAssertEqual(closed, 1)
            controller.show(content: NSView(), frame: frame, petBody: { nil }, animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            XCTAssertEqual(controller.phase, .shown)
            XCTAssertTrue(controller.isShown, "An old animation callback must not affect the reopened status")
            XCTAssertEqual(closed, 1)
        }
    }

    func testOutsideCloseThenDeactivationFinishesBothGeniesAndAllowsReopen() throws {
        try TestIsolation.require()
        _ = NSApplication.shared
        let controller = PetStatsPanelController(statusDuration: 0.2, messageDuration: 0.2)
        defer { controller.dismissImmediately() }
        let frame = NSRect(x: 100, y: 200, width: 300, height: 100)
        let messages = try solidSnapshot(frame: frame)
        var closed = 0, restored = 0, showingStats = true
        var restore: ((PetBubbleSnapshot?) -> Void)?
        controller.show(content: NSView(frame: NSRect(origin: .zero, size: frame.size)),
            frame: frame, petBody: { nil }, restoreMessages: { completion in
                restored += 1
                restore = completion
            }, onClose: { closed += 1; showingStats = false })
        XCTAssertTrue(NativeTestWait.until { controller.phase == .shown })
        XCTAssertEqual(controller.phase, .shown)
        // An external mouse-down starts close(), then the application deactivates.
        controller.close()
        XCTAssertEqual(controller.phase, .closingStatus)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        XCTAssertEqual(controller.phase, .closingStatus, "Deactivation must preserve the user-started shrink")
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(showingStats)
        XCTAssertTrue(NativeTestWait.until { restore != nil })
        XCTAssertEqual(controller.phase, .openingMessages)
        XCTAssertEqual(restored, 1)
        // Start the real second animation only after inspecting the preceding
        // phase; a slow runner must not skip the deactivation test point.
        try XCTUnwrap(restore)(messages)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        XCTAssertEqual(controller.phase, .openingMessages, "The message restoration must also finish")
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(NativeTestWait.until { controller.phase == .hidden })
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(showingStats)
        XCTAssertEqual(closed, 1)
        controller.close()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        XCTAssertEqual(closed, 1, "Completion and later deactivation must not close twice")
        controller.show(content: NSView(), frame: frame, petBody: { nil }, animated: false)
        XCTAssertEqual(controller.phase, .shown)
        XCTAssertTrue(controller.isShown)
    }

    func testPetStatsEntryReopensAfterAppSwitchWithoutOutsideClick() throws {
        try TestIsolation.require()
        _ = NSApplication.shared
        let coordinator = PetWindowController(refreshStatsUsage: {})
        let model = PetWindowModel(key: "deactivation-regression")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let pet = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        pet.isReleasedWhenClosed = false; pet.contentView = view
        defer { coordinator.stop(); pet.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 50, y: 50),
            modifierFlags: [], timestamp: 0, windowNumber: pet.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        coordinator.showStatsPopover(of: view, model: model, openingEvent: event)
        XCTAssertTrue(model.isShowingStats)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        XCTAssertFalse(model.isShowingStats, "Switching apps must release the model's status latch")
        coordinator.showStatsPopover(of: view, model: model, openingEvent: event)
        XCTAssertTrue(model.isShowingStats)
    }

    func testFullnessLightKeepsItsAnimationAndStopsWhenReducedOrDetached() throws {
        try TestIsolation.require()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let light = PetFullnessLightNSView(frame: NSRect(x: 10, y: 10, width: 12, height: 12))
        light.configure(color: .systemGreen, animated: true)
        let glow = try XCTUnwrap(light.layer?.sublayers?.first)
        XCTAssertNil(glow.animation(forKey: "breathing"), "Detached lights must not keep animating")
        window.contentView?.addSubview(light)
        let initial = try XCTUnwrap(glow.animation(forKey: "breathing"))
        light.configure(color: .systemGreen, animated: true)
        XCTAssertEqual(glow.animation(forKey: "breathing")?.beginTime, initial.beginTime,
                       "Unrelated state updates must not restart the pulse")
        light.configure(color: .systemGreen, animated: false)
        XCTAssertNil(glow.animation(forKey: "breathing"), "Reduce Motion keeps a static indicator")
        light.configure(color: .systemOrange, animated: true)
        XCTAssertNotNil(glow.animation(forKey: "breathing"))
        light.removeFromSuperview()
        XCTAssertNil(glow.animation(forKey: "breathing"))
    }

    func testClickInsideInformationPopoverReachesGearWithoutDismissingStatus() throws {
        try TestIsolation.require()
        _ = NSApplication.shared
        let controller = PetStatsPanelController()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        controller.show(content: content, frame: NSRect(x: 400, y: 300, width: 300, height: 200),
                        petBody: { nil }, animated: false)
        let popover = NSPopover()
        var openedSettings = 0
        let host = NSHostingView(rootView: DailyTokenUsageView(snapshot: .init(),
            openSettings: { openedSettings += 1 }).information)
        host.setFrameSize(host.fittingSize)
        let vc = NSViewController(); vc.view = host
        popover.contentViewController = vc
        popover.behavior = .transient; popover.animates = false
        popover.show(relativeTo: NSRect(x: 10, y: 170, width: 20, height: 20), of: content, preferredEdge: .minX)
        defer { popover.close(); controller.dismissImmediately() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let infoWindow = try XCTUnwrap(host.window)
        let gear = host.convert(NSPoint(x: host.bounds.maxX - 28,
            y: host.isFlipped ? 26 : host.bounds.maxY - 26), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: gear,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: infoWindow.windowNumber, context: nil, eventNumber: 100,
                clickCount: 1, pressure: 1))
            NSApp.postEvent(event, atStart: true)
            if let delivered = NSApp.nextEvent(matching: type == .leftMouseDown ? .leftMouseDown : .leftMouseUp,
                until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) {
                NSApp.sendEvent(delivered)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(controller.isShown, "A click in the status card's own popover is not an outside click")
        XCTAssertEqual(openedSettings, 1, "The actual information gear must receive the mouse click exactly once")

        let other = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 100, height: 100),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.orderFront(nil)
        defer { other.close() }
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: other.windowNumber, context: nil, eventNumber: 101, clickCount: 1, pressure: 1))
        NSApp.postEvent(outside, atStart: true)
        if let delivered = NSApp.nextEvent(matching: .leftMouseDown, until: Date().addingTimeInterval(0.1),
                                           inMode: .default, dequeue: true) { NSApp.sendEvent(delivered) }
        XCTAssertFalse(controller.isShown, "A different application window must still dismiss status")
    }

    func testCardStaysFixedWhenSourceWindowMovesAndShrinks() throws {
        _ = NSApplication.shared
        let source = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 480, height: 350),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let controller = PetStatsPanelController()
        defer { controller.close(); source.close() }
        let frame = NSRect(x: 200, y: 220, width: 300, height: 480)
        controller.show(content: NSView(frame: NSRect(origin: .zero, size: frame.size)),
                        frame: frame, petBody: { source.contentView }, animated: false)
        XCTAssertTrue(controller.isShown)
        source.setFrame(NSRect(x: 600, y: 10, width: 124, height: 124), display: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(controller.currentFrame, frame,
                       "Even a source-window move must not move an already opened status card")
        controller.close()
        XCTAssertFalse(controller.isShown)
        XCTAssertNil(controller.currentFrame)
    }

    func testClosingRestoresMessagesExactlyOnce() {
        _ = NSApplication.shared
        let model = PetWindowModel(key: "stats-restore-test")
        let controller = PetStatsPanelController()
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        var closures = 0
        model.isShowingStats = true
        controller.show(content: NSView(), frame: NSRect(x: 0, y: 0, width: 300, height: 100), petBody: { body }, animated: false, onClose: {
            model.isShowingStats = false
            closures += 1
        })
        XCTAssertTrue(model.isShowingStats)
        controller.close()
        XCTAssertFalse(model.isShowingStats)
        controller.close()
        XCTAssertEqual(closures, 1)
    }

    func testBothMouseButtonsPreserveStatusOnlyInsidePetBody() throws {
        _ = NSApplication.shared
        let source = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        defer { source.close() }
        let body = NSView(frame: NSRect(x: 180, y: 0, width: 120, height: 120))
        source.contentView!.addSubview(body)
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            for (point, expected) in [(NSPoint(x: 240, y: 60), true), (NSPoint(x: 240, y: 200), false)] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: source.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                XCTAssertEqual(PetStatsPanelController.isPetClick(event, petBody: body), expected)
            }
        }
    }

    func testOpeningFrameFitsEveryScreenEdgeAndNegativeDisplayCoordinates() {
        for visible in [NSRect(x: 0, y: 25, width: 1440, height: 875),
                        NSRect(x: -1280, y: -400, width: 1280, height: 720)] {
            for x in [visible.minX, visible.midX, visible.maxX - 120] {
                for y in [visible.minY, visible.midY, visible.maxY - 120] {
                    let anchor = NSRect(x: x, y: y, width: 120, height: 120)
                    let frame = PetStatsPanelController.frame(anchor: anchor,
                                                             contentSize: NSSize(width: 300, height: 540), visible: visible)
                    XCTAssertTrue(visible.contains(frame), "\(visible) / \(anchor) / \(frame)")
                }
            }
        }
    }

    func testGenieTransitionFinishesWithoutChangingLiveCardPosition() throws {
        _ = NSApplication.shared
        let controller = PetStatsPanelController()
        let content = NSView()
        let frame = NSRect(x: 80, y: 80, width: 300, height: 100)
        controller.show(content: content, frame: frame, petBody: { nil })
        let window = try XCTUnwrap(content.window)
        defer { controller.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(window.frame, frame)
        controller.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame, frame)
    }

    func testGenieBendsNearEdgeBeforePullingFarEdgeAndEndsAtPet() throws {
        let card = NSRect(x: 900, y: 250, width: 300, height: 600)
        for pet in [NSRect(x: 1010, y: 80, width: 120, height: 120),
                    NSRect(x: 750, y: 1000, width: 120, height: 120)] {
            let initial = PetStatsPanelController.genieStrips(card: card, pet: pet, progress: 0)
            let halfway = PetStatsPanelController.genieStrips(card: card, pet: pet, progress: 0.45)
            let final = PetStatsPanelController.genieStrips(card: card, pet: pet, progress: 1)
            XCTAssertEqual(initial.reduce(NSRect.null) { $0.union($1) }, card)
            let near = pet.midY > card.midY ? halfway.last! : halfway.first!
            let far = pet.midY > card.midY ? halfway.first! : halfway.last!
            XCTAssertLessThan(near.width, card.width * 0.04)
            XCTAssertGreaterThan(far.width, card.width * 0.99)
            XCTAssertEqual(pet.midY > card.midY ? far.minY : far.maxY,
                           pet.midY > card.midY ? card.minY : card.maxY, accuracy: 0.01)
            XCTAssertTrue(final.allSatisfy { abs($0.midX - pet.midX) < 0.01 && abs($0.midY - pet.midY) < 0.01 })
            XCTAssertTrue(final.allSatisfy { $0.width < 1 })
        }
    }

    func testImmediateReopenCancelsOldGenieWithoutHidingNewCard() throws {
        _ = NSApplication.shared
        let controller = PetStatsPanelController()
        defer { controller.close() }
        let frame = NSRect(x: 80, y: 80, width: 300, height: 100)
        controller.show(content: NSView(), frame: frame, petBody: { nil })
        controller.close()
        let newContent = NSView()
        controller.show(content: newContent, frame: frame, petBody: { nil })
        let window = try XCTUnwrap(newContent.window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(controller.isShown)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(window.frame, frame)
    }

    func testSnapshotMeshPreservesImageOrientationAndColors() throws {
        let width = 300, height = 600
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let source = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Deliberately asymmetric bands catch upside-down or reordered slices.
        for (index, color) in [NSColor.red, .green, .blue].enumerated() {
            source.setFillColor(color.cgColor)
            source.fill(CGRect(x: 0, y: index * 200, width: width, height: 200))
        }
        let image = try XCTUnwrap(source.makeImage())
        let card = NSRect(x: 0, y: 0, width: width, height: height)
        let root = CALayer()
        root.bounds = card
        let frames = PetStatsPanelController.genieStrips(card: card, pet: nil, progress: 0, count: 12)
        PetStatsPanelController.snapshotLayers(image: image, cardSize: card.size, frames: frames, origin: .zero)
            .forEach { root.addSublayer($0) }
        let output = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        root.render(in: output)
        let original = try XCTUnwrap(source.data).assumingMemoryBound(to: UInt8.self)
        let rendered = try XCTUnwrap(output.data).assumingMemoryBound(to: UInt8.self)
        for y in [25, 125, 225, 325, 425, 525] {
            for x in [25, 150, 275] {
                for channel in 0..<4 {
                    let offset = (y * width + x) * 4 + channel
                    XCTAssertEqual(rendered[offset], original[offset], accuracy: 2, "pixel \(x),\(y), channel \(channel)")
                }
            }
        }
        // Optional test-only preview; never captures a user's live status card.
        if let path = ProcessInfo.processInfo.environment["AGENTPET_GENIE_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, progress) in [CGFloat(0), 0.3, 0.6, 0.85].enumerated() {
                let previewCard = NSRect(x: 30, y: 160, width: width, height: height)
                let previewRoot = CALayer()
                previewRoot.bounds = NSRect(x: 0, y: 0, width: 400, height: 800)
                let mesh = PetStatsPanelController.genieStrips(card: previewCard,
                    pet: NSRect(x: 200, y: 10, width: 100, height: 100), progress: progress)
                PetStatsPanelController.snapshotLayers(image: image, cardSize: card.size, frames: mesh, origin: .zero)
                    .forEach { previewRoot.addSublayer($0) }
                let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 800,
                    bitsPerComponent: 8, bytesPerRow: 400 * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                previewRoot.render(in: context)
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("genie-\(index).png"))
            }
        }
    }

    func testOpeningApplicationMenuDismissesCardAndRestoresMessages() {
        _ = NSApplication.shared
        let controller = PetStatsPanelController()
        var messagesHidden = true
        controller.show(content: NSView(), frame: NSRect(x: 0, y: 0, width: 300, height: 100),
                        petBody: { nil }, animated: false, onClose: { messagesHidden = false })
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        XCTAssertFalse(controller.isShown)
        XCTAssertFalse(messagesHidden)
    }

    private func solidSnapshot(frame: NSRect) throws -> PetBubbleSnapshot {
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20,
            bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        return PetBubbleSnapshot(image: try XCTUnwrap(context.makeImage()), frame: frame)
    }

    func testMessagesAndStatusGeniesRunInOrderBothDirections() throws {
        _ = NSApplication.shared
        let controller = PetStatsPanelController(statusDuration: 0.5, messageDuration: 0.5)
        defer { controller.dismissImmediately() }
        var events: [String] = []
        let frame = NSRect(x: 100, y: 200, width: 300, height: 100)
        let messages = try solidSnapshot(frame: frame)
        controller.show(content: NSView(), frame: frame, petBody: { nil }, messages: messages,
            hideMessages: { events.append("hide messages") }, restoreMessages: { reply in
                events.append("prepare fresh messages")
                reply(messages)
            }, onClose: { events.append("reveal messages") })
        XCTAssertEqual(controller.phase, .hidingMessages)
        XCTAssertFalse(controller.isShown, "Status must not open before message Genie finishes")
        XCTAssertTrue(NativeTestWait.until { controller.phase == .openingStatus })
        XCTAssertEqual(controller.phase, .openingStatus)
        XCTAssertTrue(NativeTestWait.until { controller.phase == .shown })
        XCTAssertEqual(controller.phase, .shown)
        controller.close()
        XCTAssertEqual(controller.phase, .closingStatus)
        XCTAssertEqual(events, ["hide messages"], "Messages cannot expand while status is closing")
        XCTAssertTrue(NativeTestWait.until { controller.phase == .openingMessages })
        XCTAssertEqual(controller.phase, .openingMessages)
        XCTAssertEqual(events, ["hide messages", "prepare fresh messages"])
        XCTAssertTrue(NativeTestWait.until { controller.phase == .hidden })
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertEqual(events, ["hide messages", "prepare fresh messages", "reveal messages"])
    }

    func testClosingDuringMessageShrinkNeverOpensStaleStatus() throws {
        _ = NSApplication.shared
        let controller = PetStatsPanelController()
        defer { controller.dismissImmediately() }
        var closed = 0
        let frame = NSRect(x: 100, y: 200, width: 300, height: 100)
        controller.show(content: NSView(), frame: frame, petBody: { nil },
                        messages: try solidSnapshot(frame: frame), onClose: { closed += 1 })
        controller.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        XCTAssertEqual(controller.phase, .hidden)
        XCTAssertFalse(controller.isShown)
        XCTAssertEqual(closed, 1)
    }

    func testDelayedRestoreFromOldSwapCannotAffectNewStatus() throws {
        _ = NSApplication.shared
        let controller = PetStatsPanelController()
        defer { controller.dismissImmediately() }
        let frame = NSRect(x: 100, y: 200, width: 300, height: 100)
        var oldReply: ((PetBubbleSnapshot?) -> Void)?
        controller.show(content: NSView(), frame: frame, petBody: { nil }, animated: false,
                        restoreMessages: { oldReply = $0 })
        controller.close()
        XCTAssertEqual(controller.phase, .openingMessages)
        controller.show(content: NSView(), frame: frame, petBody: { nil }, animated: false)
        oldReply?(try solidSnapshot(frame: frame))
        XCTAssertEqual(controller.phase, .shown)
        XCTAssertTrue(controller.isShown)
    }

    func testIncomingSnapshotRendersCurrentMessageInsteadOfStoredOldImage() throws {
        let pet = PetController.shared
        let settings = BubbleSettings.shared
        let previousShow = pet.showChat
        let previousLayout = settings.customLayout
        let previousHidden = settings.hiddenKinds
        let previousFilter = settings.minStateFilter
        let previousDisplay = settings.displayMode
        pet.showChat = true
        settings.customLayout = .original
        settings.hiddenKinds = []
        settings.minStateFilter = .all
        settings.displayMode = .list
        defer {
            pet.showChat = previousShow
            settings.customLayout = previousLayout
            settings.hiddenKinds = previousHidden
            settings.minStateFilter = previousFilter
            settings.displayMode = previousDisplay
        }
        let now = Date()
        var session = AgentSession(id: "message-snapshot-session", agentKind: .opencode,
                                   state: .working, message: "First task", source: .hook, updatedAt: now)
        let model = PetWindowModel(key: "message-snapshot-test", petID: "test",
                                   sessions: [session], count: 1)
        let frame = NSRect(x: 50, y: 200, width: 500, height: 100)
        XCTAssertTrue(PetMessagesView.hasContent(model))
        let first = try XCTUnwrap(PetBubbleSnapshot.messages(model: model, frame: frame))
        // The status card can stay open while the underlying message changes.
        model.isShowingStats = true
        model.messagesTransitionHidden = true
        session.message = "A new result with different text"
        model.sessions = [session]
        XCTAssertTrue(PetMessagesView.hasContent(model))
        let next = try XCTUnwrap(PetBubbleSnapshot.messages(model: model, frame: frame))
        XCTAssertEqual(next.frame, frame)
        XCTAssertNotEqual(first.image.dataProvider?.data as Data?, next.image.dataProvider?.data as Data?)
        XCTAssertTrue(model.isShowingStats)
        XCTAssertTrue(model.messagesTransitionHidden, "Offscreen rendering must not reveal the live messages")
    }

    func testOpeningMouseEventCannotBeConfusedWithLaterOutsideClick() throws {
        let first = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 10, windowNumber: 0, context: nil, eventNumber: 42, clickCount: 1, pressure: 1))
        let later = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 11, windowNumber: 0, context: nil, eventNumber: 43, clickCount: 1, pressure: 1))
        XCTAssertTrue(PetStatsPanelController.isSameMouseEvent(first, first))
        XCTAssertFalse(PetStatsPanelController.isSameMouseEvent(first, later))
    }

    func testOversizedStatusUsesScreenLimitedHeightForScrolling() {
        let visible = NSRect(x: 0, y: 25, width: 800, height: 500)
        let frame = PetStatsPanelController.frame(anchor: NSRect(x: 650, y: 30, width: 120, height: 120),
                                                 contentSize: NSSize(width: 300, height: 1000), visible: visible)
        XCTAssertEqual(frame.height, 484)
        XCTAssertTrue(visible.contains(frame))
    }
}
