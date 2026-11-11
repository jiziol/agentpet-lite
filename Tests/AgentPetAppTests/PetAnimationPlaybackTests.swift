import XCTest
@testable import agentpet
import AgentPetCore

final class PetAnimationPlaybackTests: XCTestCase {
    private var settings: PetAnimationBindings {
        .init(byKey: [
            "idle": .init(mode: .rotate, clipIDs: ["idle-a", "idle-b"]),
            "working": .init(mode: .rotate, clipIDs: ["work-a", "work-b"]),
            "waiting": .init(clipIDs: ["wait"]),
            "done": .init(clipIDs: ["success"]),
            "celebrate": .init(clipIDs: ["success"]),
            "sleepy": .init(clipIDs: ["sleep"]),
            "levelup": .init(clipIDs: ["level"]),
            "tap": .init(clipIDs: ["click"]),
            "drag": .init(clipIDs: ["drag"]),
        ])
    }
    private var ids: Set<String> { Set(settings.byKey.values.flatMap(\.clipIDs)) }
    private func update(_ p: inout PetAnimationPlayback, _ mood: PetMood,
                        drag: Bool = false, tap: Int = 0) {
        p.update(mood: mood, dragging: drag, tapRevision: tap, bindings: settings,
                 available: ids, random: { _ in 0 })
    }

    func testMultipleSelectionDrawsOncePerTriggerAndLoopsTheChosenClip() {
        var p = PetAnimationPlayback()
        update(&p, .working)
        let chosen = p.selection!
        XCTAssertEqual(chosen.clipID, "work-a")
        XCTAssertTrue(chosen.loop)
        p.finished(token: chosen.token, random: { _ in 1 })
        XCTAssertEqual(p.selection, chosen)
        update(&p, .waiting)
        XCTAssertEqual(p.selection?.clipID, "wait")
        XCTAssertTrue(p.selection!.loop)
    }

    func testControllerFlashSettlesWithoutCuttingMovieOrPlayingDoneTwice() {
        var p = PetAnimationPlayback()
        update(&p, .working)
        update(&p, .celebrate)
        let flash = p.selection!
        update(&p, .done)
        XCTAssertEqual(p.selection, flash)
        p.finished(token: flash.token, random: { _ in 0 })
        XCTAssertEqual(p.selection?.key, "idle")
        let idle = p.selection
        update(&p, .done)
        XCTAssertEqual(p.selection, idle)
    }

    func testShortCelebrationFinishesBeforeFlashAndDoneStillDoesNotReplay() {
        var p = PetAnimationPlayback()
        update(&p, .celebrate)
        p.finished(token: p.selection!.token, random: { _ in 0 })
        XCTAssertEqual(p.selection?.key, "idle")
        update(&p, .done)
        XCTAssertEqual(p.selection?.key, "idle")
        update(&p, .working)
        update(&p, .celebrate)
        XCTAssertEqual(p.selection?.key, "celebrate")
    }

    func testNewWorkInterruptsCompletionAndOldCallbackCannotReplaceIt() {
        var p = PetAnimationPlayback()
        update(&p, .celebrate)
        let old = p.selection!.token
        update(&p, .working)
        let work = p.selection
        p.finished(token: old)
        XCTAssertEqual(p.selection, work)
        XCTAssertEqual(p.selection?.key, "working")
    }

    func testLevelupFinishesOnceAndReturnsToLatestBaseMood() {
        var p = PetAnimationPlayback()
        update(&p, .working)
        update(&p, .levelup)
        let flash = p.selection!
        update(&p, .working)
        XCTAssertEqual(p.selection, flash)
        p.finished(token: flash.token, random: { _ in 0 })
        XCTAssertEqual(p.selection?.key, "working")
    }

    func testTapAndDragStayPerWindowAndReleaseUsesCurrentState() {
        var first = PetAnimationPlayback(), second = PetAnimationPlayback()
        update(&first, .working)
        update(&second, .working)
        let untouched = second.selection
        update(&first, .working, tap: 1)
        XCTAssertEqual(first.selection?.key, "tap")
        XCTAssertEqual(second.selection, untouched)
        first.finished(token: first.selection!.token, random: { _ in 0 })
        XCTAssertEqual(first.selection?.key, "working")
        update(&first, .working, drag: true, tap: 1)
        XCTAssertEqual(first.selection?.key, "drag")
        update(&first, .waiting, drag: true, tap: 1)
        XCTAssertEqual(first.selection?.key, "drag")
        update(&first, .waiting, tap: 1)
        XCTAssertEqual(first.selection?.key, "waiting")
    }

    func testInvalidDuplicateAndRemovedAssetsAreFiltered() {
        let b = PetAnimationBinding(mode: .rotate, clipIDs: ["work-a", "bad", "work-a", "work-b"])
        XCTAssertEqual(b.validIDs(in: ids), ["work-a", "work-b"])
        var p = PetAnimationPlayback()
        update(&p, .working)
        var changed = settings
        changed.byKey["working"] = b
        p.update(mood: .working, bindings: changed, available: ids.subtracting(["work-a"]), random: { _ in 0 })
        XCTAssertEqual(p.selection?.clipID, "work-b")
        XCTAssertTrue(p.selection!.loop)
    }

    func testUnchangedInputsNeverRestartPlaybackAndEmptyPackIsSafe() {
        var p = PetAnimationPlayback()
        update(&p, .working)
        let selected = p.selection
        for _ in 0..<100 { update(&p, .working) }
        XCTAssertEqual(p.selection, selected)
        p.update(mood: .idle, bindings: settings, available: [])
        XCTAssertNil(p.selection)
    }

    func testFailedVideoBindingsPreferOriginalSpriteFallback() {
        var p = PetAnimationPlayback()
        p.update(mood: .working, bindings: settings, available: ["dsh:unbound", "sheet:0"])
        XCTAssertEqual(p.selection?.clipID, "sheet:0")
        XCTAssertEqual(p.selection?.key, "idle")
    }
    func testDisabledQuotaCueDoesNotPlayAfterDragRelease() {
        var p = PetAnimationPlayback()
        var bindings = settings
        bindings.byKey["quota"] = .init(clipIDs: ["quota-clip"])
        let available = ids.union(["quota-clip"])
        let cue = PetAnimationCue(id: "quota-window", key: "quota")
        p.update(mood: .idle, dragging: true, bindings: bindings, available: available,
                 context: .init(cue: cue), random: { _ in 0 })
        XCTAssertEqual(p.selection?.key, "drag")
        p.update(mood: .idle, dragging: true, bindings: bindings, available: available,
                 context: .init(quotaReminderEnabled: false), random: { _ in 0 })
        p.update(mood: .idle, bindings: bindings, available: available,
                 context: .init(quotaReminderEnabled: false), random: { _ in 0 })
        XCTAssertEqual(p.selection?.key, "idle")
    }
}

extension PetAnimationPlaybackTests {
    func testDragIsSingleShotAndHoldsLastFrameWhileStillDragging() {
        var p = PetAnimationPlayback()
        update(&p, .working)
        update(&p, .working, drag: true)
        let drag = p.selection
        XCTAssertEqual(drag?.key, "drag")
        XCTAssertEqual(drag?.loop, false, "The 10s drag movie must not loop")
        guard let drag else { return }
        p.finished(token: drag.token)
        XCTAssertEqual(p.selection, drag, "Completing while still dragging keeps the last frame/token")
        update(&p, .working, drag: true)
        XCTAssertEqual(p.selection, drag, "Repeated drag updates must not restart the movie")
        update(&p, .working)
        XCTAssertEqual(p.selection?.key, "working")
        XCTAssertNotEqual(p.selection?.token, drag.token)
    }

    func testStaleDragCompletionCannotReplaceARecoveredTaskState() {
        var p = PetAnimationPlayback()
        update(&p, .working, drag: true)
        let drag = p.selection!
        update(&p, .waiting)
        let waiting = p.selection
        p.finished(token: drag.token)
        XCTAssertEqual(p.selection, waiting)
        XCTAssertEqual(p.selection?.key, "waiting")
    }
}
