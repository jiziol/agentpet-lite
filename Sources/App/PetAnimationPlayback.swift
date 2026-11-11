import Foundation
import AgentPetCore

struct PetAnimationSelection: Equatable {
    let clipID: String
    let key: String
    let loop: Bool
    let token: UInt64
}

/// Visual state only. It never completes an agent task or changes an unread lamp.
struct PetAnimationPlayback {
    private(set) var selection: PetAnimationSelection?
    private var mood: PetMood = .idle
    private var initialized = false
    private var dragging = false
    private var tapRevision = 0
    private var bindings = PetAnimationBindings(byKey: [:])
    private var available = Set<String>()
    private var generation: UInt64 = 0
    private var terminalConsumed = false
    private var context: PetAnimationContext?
    private var seenResults: [String] = []
    private var resultChoices: [String: String] = [:]
    private var selectedResult: String?
    private var resultRepeats = false
    private var transient = false
    private var seenCue: String?
    private var pendingCue: PetAnimationCue?
    private var lastBaseTrigger = ""
    private var baseChoice: String?

    mutating func update(mood newMood: PetMood, dragging newDragging: Bool = false,
                         tapRevision newTap: Int = 0, bindings newBindings: PetAnimationBindings,
                         available newAvailable: Set<String>, context newContext: PetAnimationContext? = nil,
                         random: (Int) -> Int = { Int.random(in: 0..<$0) }) {
        if let newContext {
            updateContext(newContext, mood: newMood, dragging: newDragging, tap: newTap,
                          bindings: newBindings, available: newAvailable, random: random)
            return
        }
        let previousMood = mood
        let moodChanged = !initialized || mood != newMood
        let changed = !initialized || bindings != newBindings || available != newAvailable
        let dragChanged = dragging != newDragging
        let tapped = initialized && newTap > tapRevision
        mood = newMood
        bindings = newBindings
        available = newAvailable
        dragging = newDragging
        tapRevision = newTap
        initialized = true

        if newDragging, !ids(for: "drag").isEmpty {
            if dragChanged || changed { choose("drag", random: random) }
            return
        }
        if dragChanged { choose(baseKey, random: random); return }
        if tapped, !ids(for: "tap").isEmpty { choose("tap", random: random); return }
        if changed { choose(selection?.key ?? baseKey, random: random); return }
        guard moodChanged else { return }

        // The controller's existing 3-second flash can settle before a movie ends.
        // Finish that visual once without replaying a second completion animation.
        if previousMood == .celebrate && newMood == .done {
            if selection?.key == "celebrate" || terminalConsumed { return }
        }
        if previousMood == .levelup && selection?.key == "levelup" { return }
        if newMood != .done && newMood != .celebrate { terminalConsumed = false }
        if newMood == .celebrate { terminalConsumed = false }
        choose(baseKey, random: random)
    }

    mutating func finished(token: UInt64, random: (Int) -> Int = { Int.random(in: 0..<$0) }) {
        guard let selected = selection, selected.token == token, !selected.loop else { return }
        // A 10s drag movie is single-shot: once it ends while the pointer is
        // still down, the last frame stays on screen. It must not restart just
        // because the drag is still active.
        if dragging, selected.key == "drag" { return }
        if let context {
            transient = false
            if playPendingCue(random: random) { return }
            if context.baseKey == "idle", let unread = context.latestUnread {
                chooseResult(unread, repeating: true, random: random)
            } else { selectedResult = nil; resultRepeats = false; chooseContextBase(random: random) }
            return
        }
        if ["done", "celebrate", "levelup"].contains(selected.key) {
            terminalConsumed = true
            choose(fallbackKey, random: random)
        } else if selected.key == "tap" {
            choose(baseKey, random: random)
        } else {
            choose(selected.key, avoiding: selected.clipID, random: random)
        }
    }

    private var baseKey: String {
        terminalConsumed && [.done, .celebrate, .levelup].contains(mood) ? "idle" : mood.rawValue
    }
    private var fallbackKey: String {
        if let context { return context.baseKey }
        return [.done, .celebrate, .levelup].contains(mood) ? "idle" : mood.rawValue
    }
    private func ids(for key: String) -> [String] {
        bindings.byKey[key]?.validIDs(in: available) ?? []
    }
    private mutating func choose(_ requestedKey: String, avoiding previous: String? = nil,
                                 random: (Int) -> Int) {
        var key = requestedKey
        var candidates = ids(for: key)
        if candidates.isEmpty { key = fallbackKey; candidates = ids(for: key) }
        if candidates.isEmpty { key = "idle"; candidates = ids(for: key) }
        if candidates.isEmpty {
            let safe = available.filter { $0.hasPrefix("sheet:") }.sorted().first ?? available.sorted().first
            candidates = safe.map { [$0] } ?? []
        }
        guard !candidates.isEmpty else { selection = nil; return }
        if candidates.count > 1, let previous { candidates.removeAll { $0 == previous } }
        let index = min(max(random(candidates.count), 0), candidates.count - 1)
        generation &+= 1
        let continuous = ["idle", "working", "waiting", "sleepy"].contains(key)
        selection = .init(clipID: candidates[index], key: key, loop: continuous, token: generation)
    }

    private mutating func updateContext(_ next: PetAnimationContext, mood nextMood: PetMood,
                                       dragging nextDrag: Bool, tap nextTap: Int,
                                       bindings nextBindings: PetAnimationBindings, available nextAvailable: Set<String>,
                                       random: (Int) -> Int) {
        let first = context == nil
        let oldMood = mood, oldDrag = dragging
        let changed = bindings != nextBindings || available != nextAvailable
        let tapped = initialized && nextTap > tapRevision
        context = next; mood = nextMood; dragging = nextDrag; tapRevision = nextTap
        if !next.quotaReminderEnabled, pendingCue?.key == "quota" { pendingCue = nil }
        if let cue = next.cue, cue.id != seenCue,
           cue.key != "quota" || next.quotaReminderEnabled { pendingCue = cue }
        bindings = nextBindings; available = nextAvailable; initialized = true
        let fresh = first ? nil : next.results.last(where: { !seenResults.contains($0.id) })
        for result in next.results where !seenResults.contains(result.id) { seenResults.append(result.id) }
        if seenResults.count > 256 { seenResults = Array(seenResults.suffix(256)) }
        resultChoices = resultChoices.filter { seenResults.contains($0.key) }

        if nextDrag, !ids(for: "drag").isEmpty {
            if !oldDrag || changed || selection == nil { selectedResult = nil; transient = false; chooseContext("drag", random: random) }
            return
        }
        if oldDrag {
            selectedResult = nil; transient = false
            if !playPendingCue(random: random) { settle(random: random) }
            return
        }
        if let fresh {
            transient = false
            if next.baseKey == "idle", fresh.unread, playPendingCue(random: random) { return }
            chooseResult(fresh, repeating: next.baseKey == "idle" && fresh.unread, random: random)
            return
        }
        if playPendingCue(random: random) { return }
        if tapped, !ids(for: "tap").isEmpty {
            selectedResult = nil; resultRepeats = false; transient = true
            chooseContext("tap", random: random); return
        }
        if nextMood != oldMood, [.levelup, .celebrate].contains(nextMood) {
            selectedResult = nil; resultRepeats = false; transient = true
            chooseContext(nextMood == .levelup ? "levelup" : "success", random: random); return
        }
        if changed {
            if let id = selectedResult, let result = next.results.first(where: { $0.id == id }) {
                chooseResult(result, repeating: resultRepeats && result.unread && next.baseKey == "idle" && next.latestUnread?.id == id, random: random)
            } else if transient { chooseContext(selection?.key ?? next.baseKey, random: random) }
            else { settle(random: random) }
            return
        }
        if selectedResult != nil {
            // A new active task/request interrupts a held result immediately.
            // Acknowledgement merely changes the next cycle's target.
            if resultRepeats && next.baseKey != "idle" {
                selectedResult = nil; resultRepeats = false; chooseContextBase(random: random)
            } else if resultRepeats && next.latestUnread?.id != selectedResult, let current = selection {
                // Same token/movie: disabling its native loop preserves the
                // current frame, then the normal end callback settles it.
                selection = .init(clipID: current.clipID, key: current.key, loop: false, token: current.token)
            }
            return
        }
        if transient { return }
        if first || selection == nil || lastBaseTrigger != next.baseTrigger ||
            (next.baseKey == "idle" && next.latestUnread != nil) { settle(random: random) }
    }

    private mutating func playPendingCue(random: (Int) -> Int) -> Bool {
        guard let cue = pendingCue, cue.id != seenCue else { return false }
        pendingCue = nil
        seenCue = cue.id; selectedResult = nil; resultRepeats = false; transient = true
        chooseContext(cue.key, random: random)
        return true
    }

    private mutating func settle(random: (Int) -> Int) {
        guard let context else { return }
        if context.baseKey == "idle", let unread = context.latestUnread {
            chooseResult(unread, repeating: true, random: random)
        } else { chooseContextBase(random: random) }
    }
    private mutating func chooseContextBase(random: (Int) -> Int) {
        guard let context else { return }
        let preferred = lastBaseTrigger == context.baseTrigger ? baseChoice : nil
        lastBaseTrigger = context.baseTrigger
        selectedResult = nil; resultRepeats = false
        chooseContext(context.baseKey, preferred: preferred, random: random)
        baseChoice = selection?.clipID
    }
    private mutating func chooseResult(_ result: PetAnimationContext.Result, repeating: Bool, random: (Int) -> Int) {
        selectedResult = result.id; resultRepeats = repeating
        chooseContext(result.key, preferred: resultChoices[result.id], random: random)
        if let current = selection {
            selection = .init(clipID: current.clipID, key: current.key, loop: repeating, token: current.token)
        }
        resultChoices[result.id] = selection?.clipID
    }
    private mutating func chooseContext(_ key: String, preferred: String? = nil, random: (Int) -> Int) {
        let candidates = ids(for: key)
        let continuous = ["idle", "working", "waiting", "sleepy"].contains(key)
        if let preferred, candidates.contains(preferred) {
            generation &+= 1
            selection = .init(clipID: preferred, key: key, loop: continuous, token: generation)
        } else {
            choose(key, random: random)
            if let selected = selection {
                selection = .init(clipID: selected.clipID, key: selected.key, loop: continuous, token: selected.token)
            }
        }
    }
}
