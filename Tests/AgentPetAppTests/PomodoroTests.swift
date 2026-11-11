import AppKit
import SwiftUI
import XCTest
@testable import agentpet

final class PomodoroClockTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1000)
    func testPauseResumePreservesRemainingAndDoesNotCountPausedTime() {
        var clock = PomodoroClock(); clock.startNext(focus: 1500, rest: 300, now: at)
        clock.pause(now: at.addingTimeInterval(20))
        XCTAssertEqual(clock.remaining(at: at.addingTimeInterval(100)), 1480)
        clock.resume(now: at.addingTimeInterval(100))
        XCTAssertFalse(clock.advance(now: at.addingTimeInterval(1579.999)))
        XCTAssertTrue(clock.advance(now: at.addingTimeInterval(1580)))
    }
    func testManualPhaseTransitionAndCompletionAreExactlyOnce() {
        var clock = PomodoroClock(); clock.startNext(focus: 1500, rest: 300, now: at)
        clock.startNext(focus: 5, rest: 5, now: at)
        XCTAssertEqual(clock.remaining(at: at), 1500)
        XCTAssertTrue(clock.advance(now: at.addingTimeInterval(1500)))
        XCTAssertFalse(clock.advance(now: at.addingTimeInterval(1501)))
        XCTAssertEqual(clock.status, .finished); XCTAssertEqual(clock.phase, .focus)
        clock.startNext(focus: 1500, rest: 300, now: at.addingTimeInterval(1600))
        XCTAssertEqual(clock.phase, .rest); XCTAssertEqual(clock.remaining(at: at.addingTimeInterval(1600)), 300)
        XCTAssertTrue(clock.advance(now: at.addingTimeInterval(1900)))
        clock.startNext(focus: 1500, rest: 300, now: at.addingTimeInterval(2000))
        XCTAssertEqual(clock.phase, .focus)
    }
    func testRestartRestoresPausedSnapshotWithoutElapsedDowntime() throws {
        var clock = PomodoroClock(); clock.startNext(focus: 1500, rest: 300, now: at)
        let encoded = try JSONEncoder().encode(clock.snapshot(now: at.addingTimeInterval(80)))
        let restored = PomodoroClock.restored(encoded)
        XCTAssertEqual(restored.status, .paused)
        XCTAssertNil(restored.deadline)
        XCTAssertEqual(restored.remaining(at: at.addingTimeInterval(100_000)), 1420)
    }
    func testPauseAtDeadlineFinishesOnceAndEndResets() {
        var clock = PomodoroClock(); clock.startNext(focus: 1, rest: 1, now: at)
        XCTAssertTrue(clock.pause(now: at.addingTimeInterval(1)))
        XCTAssertFalse(clock.pause(now: at.addingTimeInterval(2)))
        clock.end(); XCTAssertEqual(clock.status, .idle); XCTAssertEqual(clock.phase, .focus)
        clock.resume(now: at); XCTAssertEqual(clock.status, .idle)
    }
    func testInvalidDurationAndCorruptSnapshotDoNotStart() {
        for duration in [0.0, -1, .infinity, .nan, 100_000] {
            var clock = PomodoroClock(); clock.startNext(focus: duration, rest: 1, now: at)
            XCTAssertEqual(clock.status, .idle)
        }
        XCTAssertEqual(PomodoroClock.restored(Data("bad".utf8)).status, .idle)
        XCTAssertEqual(PomodoroClock.restored(Data(repeating: 1, count: 3000)).status, .idle)
    }
}

@MainActor
final class PomodoroControllerTests: XCTestCase {
    func testSuperchatConfirmationStartsBothNextPhasesAndRejectsOldCycleAction() {
        let name = "pomodoro-confirm-next-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(15, forKey: PomodoroController.focusKey)
        defaults.set(1, forKey: PomodoroController.restKey)
        let source = SystemNoticeCenter(visible: { _ in false }, changed: {})
        weak var weakTimer: PomodoroController?
        let timer = PomodoroController(defaults: defaults, clearNotice: { source.dismissPomodoro() }) { phase in
            source.post(.init(id: UUID().uuidString, kind: .pomodoro, title: "", body: phase.rawValue,
                              legacyText: phase.rawValue), onConfirmed: weakTimer?.nextPhaseAction())
        }
        weakTimer = timer
        defer { timer.end(); timer.prepareForTermination(); source.clear(); defaults.removePersistentDomain(forName: name) }
        timer.startNext(); timer.tick(at: timer.clock.deadline!)
        XCTAssertEqual(timer.clock.status, .finished)
        let oldAction = timer.nextPhaseAction()
        let focusNotice = source.current!.id
        source.confirmPomodoro(id: focusNotice)
        XCTAssertEqual(timer.clock.status, .running)
        XCTAssertEqual(timer.clock.phase, .rest)
        XCTAssertEqual(timer.clock.remaining(at: timer.now), 60, accuracy: 0.01)
        let restDeadline = timer.clock.deadline
        source.confirmPomodoro(id: focusNotice)
        XCTAssertEqual(timer.clock.deadline, restDeadline)
        timer.tick(at: timer.clock.deadline!)
        XCTAssertEqual(timer.clock.status, .finished)
        source.confirmPomodoro(id: source.current!.id)
        XCTAssertEqual(timer.clock.status, .running)
        XCTAssertEqual(timer.clock.phase, .focus)
        XCTAssertEqual(timer.clock.remaining(at: timer.now), 900, accuracy: 0.01)
        timer.tick(at: timer.clock.deadline!)
        oldAction()
        XCTAssertEqual(timer.clock.status, .finished, "An old focus reminder cannot advance a later focus cycle")
    }
    func testStartingNextPhaseAndEndingClearTimerNoticeOnlyAfterValidAction() {
        let name = "pomodoro-clear-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var clearCount = 0
        let timer = PomodoroController(defaults: defaults, clearNotice: { clearCount += 1 }) { _ in }
        defer { timer.prepareForTermination() }
        timer.startNext()
        XCTAssertEqual(clearCount, 1)
        timer.startNext()
        XCTAssertEqual(clearCount, 1, "A redundant start must not acknowledge a notice")
        timer.tick(at: timer.clock.deadline!)
        timer.startNext()
        XCTAssertEqual(clearCount, 2)
        XCTAssertEqual(timer.clock.phase, .rest)
        timer.end()
        XCTAssertEqual(clearCount, 3)
    }
    func testDefaultDurationsRememberCustomChoiceAndClampInput() {
        let name = "pomodoro-defaults-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let timer = PomodoroController(defaults: defaults) { _ in }
        XCTAssertEqual(timer.focusMinutes, 25); XCTAssertEqual(timer.restMinutes, 5)
        timer.focusMinutes = 45; timer.restMinutes = 10
        let restored = PomodoroController(defaults: defaults) { _ in }
        XCTAssertEqual(restored.focusMinutes, 45); XCTAssertEqual(restored.restMinutes, 10)
        timer.focusMinutes = -5; timer.restMinutes = 999
        let bounded = PomodoroController(defaults: defaults) { _ in }
        XCTAssertEqual(bounded.focusMinutes, 1); XCTAssertEqual(bounded.restMinutes, 120)
    }
    func testOneNoticeAndNoAutoAdvanceThenManualBreak() {
        let name = "pomodoro-notice-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var notices: [PomodoroClock.Phase] = []
        let timer = PomodoroController(defaults: defaults) { notices.append($0) }
        defer { timer.prepareForTermination() }
        timer.startNext(); let end = timer.clock.deadline!
        timer.tick(at: end); timer.tick(at: end.addingTimeInterval(5))
        XCTAssertEqual(notices, [.focus]); XCTAssertEqual(timer.clock.status, .finished)
        timer.startNext(); XCTAssertEqual(timer.clock.phase, .rest)
        timer.tick(at: timer.clock.deadline!)
        XCTAssertEqual(notices, [.focus,.rest]); XCTAssertEqual(timer.clock.status, .finished)
    }
    func testSyntheticSleepAndTerminationRestorePausedWithoutAutoResume() {
        let name = "pomodoro-sleep-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let timer = PomodoroController(defaults: defaults) { _ in }
        timer.activate(); timer.startNext()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(timer.clock.status, .paused)
        timer.resume(); XCTAssertEqual(timer.clock.status, .running)
        timer.prepareForTermination()
        let restored = PomodoroController(defaults: defaults) { _ in }
        XCTAssertEqual(restored.clock.status, .paused)
        XCTAssertTrue(restored.remainingText.hasPrefix("24:") || restored.remainingText == "25:00")
    }
    func testCompletionUsesNativePetPanelAndDefersToQuotaThenExpires() throws {
        _ = NSApplication.shared
        let name = "pomodoro-panel-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let settings = BubbleSettings.shared
        let enabled = settings.superchatEnabled
        settings.superchatEnabled = true
        let pet = PetController()
        let split = pet.splitPet, show = pet.showChat, idle = pet.showIdleMessage
        pet.splitPet = false; pet.showChat = true; pet.showIdleMessage = false
        var confirmations = 0
        let timer = PomodoroController(defaults: defaults) { phase in
            pet.showPomodoroFinished(phase: phase, focusMinutes: 25, restMinutes: 5,
                                     onConfirmed: { confirmations += 1 })
        }
        defer {
            timer.end(); timer.prepareForTermination(); defaults.removePersistentDomain(forName: name)
            pet.clearLowQuota(); PetWindowController.shared.stop()
            pet.splitPet = split; pet.showChat = show; pet.showIdleMessage = idle
            settings.superchatEnabled = enabled
        }
        pet.showLowQuota(.init(id: "isolated-pomodoro-quota", text: "额度优先测试"))
        timer.startNext(); timer.tick(at: timer.clock.deadline!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "AgentPet Lite Pet Messages" && $0.isVisible })
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<PetSpeechView>)
        let model = host.rootView.model
        XCTAssertEqual(model.quotaText, "额度优先测试")
        RunLoop.main.run(until: Date().addingTimeInterval(8.25))
        XCTAssertEqual(pet.systemNotices.current?.kind, .pomodoro)
        XCTAssertEqual(pet.systemNotices.current?.confirmationLabel, "Start break")
        XCTAssertFalse(model.quotaText.isEmpty)
        XCTAssertFalse(panel.ignoresMouseEvents, "The confirmation must receive a first click")
        RunLoop.main.run(until: Date().addingTimeInterval(8.25))
        XCTAssertEqual(pet.systemNotices.current?.kind, .pomodoro)
        XCTAssertTrue(panel.isVisible)
        pet.systemNotices.confirmPomodoro(id: try XCTUnwrap(pet.systemNotices.current?.id))
        XCTAssertEqual(confirmations, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(model.quotaText.isEmpty); XCTAssertFalse(panel.isVisible)
    }
}
