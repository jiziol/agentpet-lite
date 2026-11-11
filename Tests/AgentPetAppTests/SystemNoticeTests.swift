import AppKit
import SwiftUI
import XCTest
import AgentPetCore
@testable import agentpet

final class SystemNoticeClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100)
    private func notice(_ id: String, _ kind: SystemNotice.Kind = .pomodoro) -> SystemNotice {
        .init(id: id, kind: kind, title: "", body: id, legacyText: id)
    }
    func testOnlyVisibleTimeCountsAndChangingSurfaceDoesNotRestart() {
        var clock = SystemNoticeClock()
        clock.post(notice("a"), now: start)
        clock.advance(now: start.addingTimeInterval(10), visible: true)
        XCTAssertEqual(clock.current?.remaining, 8)
        clock.advance(now: start.addingTimeInterval(13), visible: false)
        XCTAssertEqual(clock.current?.remaining, 5)
        clock.advance(now: start.addingTimeInterval(30), visible: true)
        XCTAssertEqual(clock.current?.remaining, 5)
        clock.advance(now: start.addingTimeInterval(35), visible: true)
        XCTAssertEqual(clock.current?.remaining, 0)
        XCTAssertEqual(clock.current?.notice.id, "a")
        clock.dismissPomodoro(id: "a")
        XCTAssertNil(clock.current)
    }
    func testQuotaPreemptsTimerThenResumesItsRemainingTime() {
        var clock = SystemNoticeClock()
        clock.post(notice("timer"), now: start)
        clock.advance(now: start, visible: true)
        clock.advance(now: start.addingTimeInterval(3), visible: true)
        clock.post(notice("low", .lowQuota), now: start.addingTimeInterval(3))
        XCTAssertEqual(clock.pending?.remaining, 5)
        clock.advance(now: start.addingTimeInterval(3), visible: true)
        clock.advance(now: start.addingTimeInterval(11), visible: true)
        XCTAssertEqual(clock.current?.notice.id, "timer")
        XCTAssertEqual(clock.current?.remaining, 5)
        clock.advance(now: start.addingTimeInterval(11), visible: true)
        clock.advance(now: start.addingTimeInterval(16), visible: true)
        XCTAssertEqual(clock.current?.notice.id, "timer")
        XCTAssertEqual(clock.current?.remaining, 0)
        clock.dismissPomodoro()
        XCTAssertNil(clock.current)
    }
    func testAcknowledgmentRemovesPendingTimerWithoutClearingQuotaAndIgnoresStaleIDs() {
        var clock = SystemNoticeClock()
        clock.post(notice("low", .lowQuota), now: start)
        clock.post(notice("old"), now: start)
        clock.post(notice("new"), now: start)
        clock.dismissPomodoro(id: "old")
        XCTAssertEqual(clock.pending?.notice.id, "new")
        clock.dismissPomodoro()
        XCTAssertNil(clock.pending)
        XCTAssertEqual(clock.current?.notice.id, "low")
        clock.advance(now: start, visible: true)
        clock.advance(now: start.addingTimeInterval(8), visible: true)
        XCTAssertNil(clock.current)
    }
    func testAcknowledgedTimerDoesNotReappearAfterQuotaPreemption() {
        var clock = SystemNoticeClock()
        clock.post(notice("timer"), now: start)
        clock.advance(now: start, visible: true)
        clock.advance(now: start.addingTimeInterval(20), visible: true)
        clock.post(notice("quota", .quotaRecovered), now: start.addingTimeInterval(20))
        XCTAssertEqual(clock.pending?.remaining, 0)
        clock.dismissPomodoro(id: "timer")
        clock.advance(now: start.addingTimeInterval(20), visible: true)
        clock.advance(now: start.addingTimeInterval(28), visible: true)
        XCTAssertNil(clock.current)
    }
    func testLatestPendingTimerAndRecoveryReplacesObsoleteLow() {
        var clock = SystemNoticeClock()
        clock.post(notice("low", .lowQuota), now: start)
        clock.post(notice("old-timer"), now: start)
        clock.post(notice("new-timer"), now: start)
        clock.post(notice("recovery", .quotaRecovered), now: start)
        XCTAssertEqual(clock.current?.notice.id, "recovery")
        XCTAssertEqual(clock.pending?.notice.id, "new-timer")
        clock.advance(now: start, visible: true)
        clock.advance(now: start.addingTimeInterval(3), visible: true)
        clock.post(notice("recovery", .quotaRecovered), now: start.addingTimeInterval(3))
        XCTAssertEqual(clock.current?.remaining, 5, "A duplicate must not extend the budget")
        clock.clear(); XCTAssertNil(clock.current); XCTAssertNil(clock.pending)
    }
}

@MainActor
final class SystemNoticeConfirmationTests: XCTestCase {
    private func notice(_ id: String, kind: SystemNotice.Kind = .pomodoro) -> SystemNotice {
        .init(id: id, kind: kind, title: "", body: id, legacyText: id)
    }
    func testConfirmationRunsOnceAndOldOrDismissedNoticesCannotStartAnything() {
        let source = SystemNoticeCenter(visible: { _ in false }, changed: {})
        defer { source.clear() }
        var count = 0
        source.post(notice("old"), onConfirmed: { count += 100 })
        source.post(notice("new"), onConfirmed: { count += 1 })
        source.confirmPomodoro(id: "old")
        XCTAssertEqual(count, 0)
        source.post(notice("new"), onConfirmed: { count += 1000 })
        source.confirmPomodoro(id: "new")
        source.confirmPomodoro(id: "new")
        XCTAssertEqual(count, 1)
        XCTAssertNil(source.current)
        source.post(notice("ended"), onConfirmed: { count += 100 })
        source.dismissPomodoro()
        source.confirmPomodoro(id: "ended")
        XCTAssertEqual(count, 1)
    }
    func testQuotaPreemptionPreservesActionWithoutAllowingHiddenConfirmation() {
        let source = SystemNoticeCenter(visible: { _ in true }, changed: {})
        defer { source.clear() }
        var count = 0
        source.post(notice("timer"), onConfirmed: { count += 1 })
        source.post(notice("quota", kind: .lowQuota))
        source.confirmPomodoro(id: "timer")
        XCTAssertEqual(count, 0)
        XCTAssertEqual(source.current?.kind, .lowQuota)
        source.tick()
        source.tick(now: Date().addingTimeInterval(9))
        XCTAssertEqual(source.current?.id, "timer")
        source.confirmPomodoro(id: "timer")
        XCTAssertEqual(count, 1)
        XCTAssertNil(source.current)
    }
}

@MainActor
final class SystemNoticeViewTests: XCTestCase {
    func testNativeBannerDimensionsForEachTypeAndStatusWidth() throws {
        _ = NSApplication.shared
        let center = SystemNoticeCenter(visible: { _ in false }, changed: {})
        defer { center.clear() }
        let notices: [SystemNotice] = [
            .lowQuota(.init(id: "low", text: "legacy", percent: 8)),
            .recovered(.init(id: "reset", percent: 100)),
            .init(id: "timer", kind: .pomodoro, title: "番茄时钟：", body: "25分钟专注完成，可休息5分钟", legacyText: "legacy", shortBody: "专注完成，可休息5分钟")]
        for notice in notices {
            for width: CGFloat in [272, 380] {
                let host = NSHostingView(rootView: SystemNoticeView(source: center, notice: notice, width: width))
                let size = host.fittingSize
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertGreaterThan(size.width, 80)
                XCTAssertGreaterThanOrEqual(size.height, 53 - 0.5)
            }
        }
        let low = notices[0].title + notices[0].body
        XCTAssertEqual(low.components(separatedBy: "8%").count - 1, 1)
    }
    func testNativeReminderRenderingPreservesTextAtZeroBackgroundOpacity() throws {
        let center = SystemNoticeCenter(visible: { _ in false }, changed: {})
        let settings = BubbleSettings.shared
        let theme = settings.theme, opacity = settings.opacity
        defer { center.clear(); settings.theme = theme; settings.opacity = opacity }
        let notices: [SystemNotice] = [
            .lowQuota(.init(id: "low", text: "legacy", percent: 8)),
            .recovered(.init(id: "reset", percent: 100)),
            .init(id: "timer", kind: .pomodoro, title: "番茄时钟：", body: "25分钟专注完成，可休息5分钟", legacyText: "legacy", shortBody: "专注完成，可休息5分钟")]
        for notice in notices {
            for dark in [false, true] {
                settings.theme = dark ? .dark : .light
                for alpha in [1.0, 0.0] {
                    settings.opacity = alpha
                    let renderer = ImageRenderer(content: SystemNoticeView(source: center, notice: notice)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    renderer.scale = 2
                    let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                    XCTAssertLessThanOrEqual(bitmap.pixelsWide, 760)
                    XCTAssertGreaterThan(bitmap.pixelsWide, 160)
                    XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 106)
                    if alpha == 0 {
                        // Background disappears; actual glyphs remain opaque.
                        XCTAssertLessThan(bitmap.colorAt(x: bitmap.pixelsWide - 5, y: 5)!.alphaComponent, 0.05)
                        var opaqueGlyphs = 0
                        for y in 10..<(bitmap.pixelsHigh - 10) {
                            for x in 80..<(bitmap.pixelsWide - 20) where bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.9 { opaqueGlyphs += 1 }
                        }
                        XCTAssertGreaterThan(opaqueGlyphs, 100)
                    }
                    if let path = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"],
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("notice-\(notice.id)-\(dark ? "dark" : "light")-\(Int(alpha * 100)).png"))
                    }
                }
            }
        }
    }
    func testStatusReceivesNewNoticeAndClosingPreservesItsBudget() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let enabled = settings.superchatEnabled
        settings.superchatEnabled = true
        let controller = PetWindowController(refreshStatsUsage: {})
        let specs = PetWindowPlanner.plan(sessions: [], split: false, mappings: [], defaultPetID: "status-notice-native")
        var source: SystemNoticeCenter!
        func sync() {
            controller.sync(specs: specs, noticeSource: source) { _ in
                .init(petID: "status-notice-native", mood: .idle, sessions: [], count: 0, chatLine: "", quotaText: source.current?.legacyText ?? "")
            }
        }
        source = SystemNoticeCenter(visible: { controller.isSystemNoticeVisible(id: $0) }, changed: { sync() })
        defer { source.clear(); controller.stop(); settings.superchatEnabled = enabled }
        sync()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "AgentPet Lite Pet Messages" && ($0.contentView as? NSHostingView<PetSpeechView>)?.rootView.model.petID == "status-notice-native" })
        let model = try XCTUnwrap((panel.contentView as? NSHostingView<PetSpeechView>)?.rootView.model)
        let body = try XCTUnwrap(model.petBodyView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: body.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        controller.showStatsPopover(of: body, model: model, openingEvent: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertTrue(model.isShowingStats)
        source.post(.recovered(.init(id: "inside-status", percent: 100)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let marker = try XCTUnwrap(model.statusNoticeMarker)
        XCTAssertEqual(marker.noticeID, "inside-status")
        print("STATUS_NOTICE bounds=\(marker.bounds) visible=\(marker.visibleRect) frame=\(String(describing: marker.window?.frame)) alpha=\(String(describing: marker.window?.alphaValue)) shown=\(String(describing: marker.window?.isVisible)) remaining=\(source.fractionRemaining)")
        XCTAssertTrue(controller.isSystemNoticeVisible(id: "inside-status"))
        XCTAssertFalse(panel.isVisible)
        let remaining = source.fractionRemaining
        controller.closeStatsPopover()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(model.isShowingStats)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.isSystemNoticeVisible(id: "inside-status"))
        XCTAssertLessThanOrEqual(source.fractionRemaining, remaining)
        XCTAssertGreaterThan(source.fractionRemaining, remaining - 0.11, "Genie transition must not consume hidden time")
        let consumed = source.fractionRemaining
        source.clear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(panel.isVisible)
        XCTAssertLessThan(consumed, 1)
    }
    func testImportantGeometryFitsScreenEdgesAndSmallScreens() {
        for screen in [CGRect(x: 0, y: 25, width: 1440, height: 875), CGRect(x: -200, y: -100, width: 320, height: 300)] {
            for x in [screen.minX, screen.midX, screen.maxX - 120] {
                for y in [screen.minY, screen.midY, screen.maxY - 120] {
                    let frame = PetSpeechPanelGeometry.frame(anchor: CGPoint(x: x, y: y), petSize: 120, content: CGSize(width: 392, height: 65), visible: screen, important: true)
                    XCTAssertTrue(screen.contains(frame), "\(screen) / \(frame)")
                }
            }
        }
    }
    func testCenterReachesNativeSpeechPanelAndHonorsVisibility() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let enabled = settings.superchatEnabled
        settings.superchatEnabled = true
        let controller = PetWindowController()
        let specs = PetWindowPlanner.plan(sessions: [], split: false, mappings: [], defaultPetID: "notice-native")
        var source: SystemNoticeCenter!
        func sync() {
            controller.sync(specs: specs, noticeSource: source) { _ in
                .init(petID: "notice-native", mood: .idle, sessions: [], count: 0, chatLine: "", quotaText: source.current?.legacyText ?? "")
            }
        }
        source = SystemNoticeCenter(visible: { controller.isSystemNoticeVisible(id: $0) }, changed: { sync() })
        defer { source.clear(); controller.stop(); settings.superchatEnabled = enabled }
        source.post(.recovered(.init(id: "native-recovery", percent: 100)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let panel = try XCTUnwrap(NSApp.windows.first { window in
            guard window.title == "AgentPet Lite Pet Messages", window.isVisible,
                  let host = window.contentView as? NSHostingView<PetSpeechView> else { return false }
            return host.rootView.model.noticeSource === source
        })
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<PetSpeechView>)
        XCTAssertTrue(host.rootView.model.noticeSource === source)
        XCTAssertTrue(controller.isSystemNoticeVisible(id: "native-recovery"))
        XCTAssertLessThanOrEqual(panel.frame.width, 392)
        XCTAssertEqual(panel.frame.width, host.fittingSize.width, accuracy: 1)
        XCTAssertGreaterThan(panel.frame.height, 60)
        let remaining = source.fractionRemaining
        controller.isVisible = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let hidden = source.fractionRemaining
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(source.fractionRemaining, hidden, accuracy: 0.001)
        XCTAssertLessThanOrEqual(hidden, remaining)
        controller.isVisible = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(controller.isSystemNoticeVisible(id: "native-recovery"))
        XCTAssertLessThan(source.fractionRemaining, hidden)
    }
}
