import Foundation

@main
struct ReadReceiptChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { fatalError("FAIL: " + name) }
            checks += 1; print("PASS: " + name)
        }
        func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        func event(_ kind: AgentKind, _ name: String, _ seconds: Double, id: String = "a") -> AgentEvent {
            AgentEvent(sessionId: id, agentKind: kind, eventName: name, timestamp: time(seconds))
        }
        check(TerminalInfo.concreteTTY("/dev/tty") == nil, "generic controlling-terminal alias is not a tab identity")
        check(TerminalInfo.concreteTTY("/dev/ttys003") == "/dev/ttys003", "concrete macOS terminal device remains usable")
        check(TerminalInfo.concreteTTY("/dev/ttys003\"; bad") == nil, "invalid terminal device cannot enter focus script")
        let capturedTTY = TerminalInfo.capture().tty
        if let actual = capturedTTY {
            check(actual != "/dev/tty" && TerminalInfo.concreteTTY(actual) == actual, "captured device is concrete")
        }
        if let expected = ProcessInfo.processInfo.environment["AGENTPET_CHECK_EXPECT_TTY"] {
            check(capturedTTY == expected, "all-piped Hook resolves actual controlling device through kernel metadata")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentpet-receipt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore()
        store.persistenceURL = root.appendingPathComponent("v1.json")
        store.apply(event(.codex, "UserPromptSubmit", 1), now: time(1))
        check(store.session(id: "a")!.indicator == .running, "new task starts blue rather than implicitly read")
        var legacyWorking = store.session(id: "a")!
        legacyWorking.readAt = time(1)
        check(legacyWorking.indicator == .running, "legacy running read receipt cannot paint a running task green")
        let runningClick = store.session(id: "a")!
        check(store.markOpened(runningClick, at: time(2)) && store.session(id: "a")!.indicator == .running && store.session(id: "a")!.hasReadReceipt, "click reads displayed running message while native work stays blue")
        let clickedRestored = SessionStore(); clickedRestored.persistenceURL = store.persistenceURL; clickedRestored.restoreCodexSessions()
        check(clickedRestored.session(id: "a")!.hasReadReceipt && clickedRestored.session(id: "a")!.indicator == .running, "running click receipt survives restart without turning green")
        store.apply(event(.codex, "PreToolUse", 3), now: time(3))
        check(store.session(id: "a")!.indicator == .running, "running tool heartbeat stays blue")
        let activityRestored = SessionStore(); activityRestored.persistenceURL = store.persistenceURL; activityRestored.restoreCodexSessions()
        check(activityRestored.session(id: "a")!.indicator == .running, "new work after read remains blue after restart")
        store.markOpened(runningClick, at: time(3.5))
        check(store.session(id: "a")!.indicator == .running, "late navigation cannot read a newer activity in the same turn")
        store.apply(event(.codex, "PermissionRequest", 4), now: time(4))
        check(store.session(id: "a")!.indicator == .attention, "new attention message overrides green with orange")
        check(store.markOpened(store.session(id: "a")!, at: time(4.5)) && store.session(id: "a")!.indicator == .read && store.session(id: "a")!.hasReadReceipt, "waiting message click turns green")
        let attentionClick = store.session(id: "a")!
        store.apply(event(.codex, "PreToolUse", 5), now: time(5))
        check(store.session(id: "a")!.indicator == .running, "resuming after reading a waiting message resets visible lamp to blue")
        store.apply(event(.codex, "Stop", 6), now: time(6))
        store.markOpened(attentionClick, at: time(7))
        check(store.session(id: "a")!.indicator == .unread, "old navigation cannot read a later completion")
        store.prune(now: time(1000))
        check(store.session(id: "a")!.state == .done, "unread completion survives timeout")
        let completedClick = store.session(id: "a")!
        store.markOpened(completedClick, at: time(1000))
        store.prune(now: time(1010))
        check(store.session(id: "a")!.state == .done && store.session(id: "a")!.indicator == .read, "old completed card remains green for grace period after click")
        store.prune(now: time(1031))
        check(store.session(id: "a")!.state == .idle, "read card returns to normal lifecycle after grace period")
        store.apply(event(.codex, "UserPromptSubmit", 1040), now: time(1040))
        check(store.session(id: "a")!.indicator == .running && store.session(id: "a")!.readAt == nil, "new turn resets green to blue")
        check(!store.markOpened(completedClick, at: time(1041)) && store.session(id: "a")!.indicator == .running, "late navigation from old turn cannot turn a new task green")
        store.apply(event(.codex, "Stop", 1042), now: time(1042))
        check(store.session(id: "a")!.indicator == .unread, "next completion turns red again")
        let unread = store.session(id: "a")!
        // A failed navigation does not call markOpened at all.
        check(unread.hasUnread && !unread.hasReadReceipt, "failed navigation leaves unread and receipt untouched")
        let other = store.apply(event(.codex, "Stop", 1043, id: "b"), now: time(1043))!
        store.markOpened(unread, at: time(1044))
        check(store.session(id: "b") == other, "click only acknowledges the exact session")
        let restored = SessionStore(); restored.persistenceURL = store.persistenceURL; restored.restoreCodexSessions()
        check(restored.session(id: "a")!.indicator == .read && restored.session(id: "b")!.indicator == .unread, "read and unread colors survive restart")
        store.remove(id: "a")
        store.apply(event(.codex, "UserPromptSubmit", 1100), now: time(1100))
        check(!store.markOpened(unread, at: time(1101)), "late acknowledgement cannot read a recreated session")
        let agy = SessionStore(); agy.persistenceURL = root.appendingPathComponent("agy.json")
        agy.apply(event(.antigravity, "working", 1), now: time(1))
        check(agy.session(id: "a")!.indicator == .running, "Antigravity task starts blue")
        check(agy.markOpened(agy.session(id: "a")!, at: time(1.5)) && agy.session(id: "a")!.indicator == .running && agy.session(id: "a")!.hasReadReceipt, "Antigravity click acknowledges captured message while work stays blue")
        agy.apply(event(.antigravity, "working", 1.8), now: time(1.8))
        check(agy.session(id: "a")!.indicator == .running, "Antigravity fresh activity after click returns to blue")
        agy.apply(event(.antigravity, "done", 2), now: time(2))
        check(agy.session(id: "a")!.indicator == .unread, "Antigravity completion turns red")
        agy.prune(now: time(1000))
        check(agy.session(id: "a") != nil, "Antigravity unread is not lost to timeout")
        let agyClick = agy.session(id: "a")!
        agy.markOpened(agyClick, at: time(1000))
        check(agy.session(id: "a")!.indicator == .read, "Antigravity successful navigation turns green")
        agy.apply(event(.antigravity, "done", 3), now: time(3))
        check(agy.session(id: "a")!.indicator == .read, "duplicate completion does not erase read color or create a new unread message")
        let agyRestored = SessionStore(); agyRestored.persistenceURL = agy.persistenceURL; agyRestored.restoreCodexSessions()
        check(agyRestored.session(id: "a") == agy.session(id: "a"), "Antigravity receipt survives restart in compatible snapshot")
        agy.apply(event(.antigravity, "working", 1001), now: time(1001))
        check(agy.session(id: "a")!.indicator == .running && !agy.markOpened(agyClick, at: time(1002)), "Antigravity new task resets color and rejects old click")
        let generic = SessionStore()
        generic.apply(event(.claude, "UserPromptSubmit", 1), now: time(1))
        generic.apply(event(.claude, "Stop", 2), now: time(2))
        check(generic.session(id: "a")!.indicator == .unread, "shared hook-state notification policy applies to other agents")
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.session(id: "a")!)) as! [String: Any]
        old.removeValue(forKey: "readAt"); old.removeValue(forKey: "interactionGeneration")
        old.removeValue(forKey: "displayRevision"); old.removeValue(forKey: "readDisplayRevision")
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: old))
        check(decoded.readAt == nil && decoded.interactionGeneration == nil && decoded.indicator == .running, "existing snapshot without optional receipt fields stays readable and blue")
        print("\(checks) read receipt checks passed")
    }
}
