import Foundation
import CryptoKit
#if !ARCHIVE_PORTABLE
@testable import AgentPetCore
#endif

enum ArchiveReliabilityScenarios {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func runAll() throws -> Int {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agentpet-history-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw Failure(description: name) }; count += 1
        }
        func rejects(_ name: String, _ action: () throws -> Void) throws {
            do { try action() } catch { count += 1; return }
            throw Failure(description: "Expected rejection: " + name)
        }
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(identifier: "UTC")
        func file(_ dir: URL, _ date: Date = t) -> URL { dir.appendingPathComponent(formatter.string(from: date) + ".json") }
        func session(_ id: String, title: String = "private-body-marker") -> AgentSession {
            AgentSession(id: id, agentKind: .claude, project: "/synthetic", title: title,
                         state: .done, message: "private-body-marker", source: .hook, updatedAt: t)
        }
        func store(_ name: String) -> (SessionArchiveStore, URL) {
            let dir = root.appendingPathComponent(name)
            return (SessionArchiveStore(baseURL: dir), dir)
        }
        func stageURL(_ dir: URL, _ id: String) -> URL {
            let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            return dir.appendingPathComponent(".pending").appendingPathComponent(hash + ".json")
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let (normal, ndir) = store("normal")
        try check(try normal.recordsChecked(for: t).isEmpty, "missing history is empty")
        try check(!fm.fileExists(atPath: file(ndir).path), "query does not create daily history")
        try check(normal.archive(session("first"), startedAt: t, endedAt: t.addingTimeInterval(60)) == .archived, "new history created")
        try check(normal.archive(session("second"), startedAt: t, endedAt: t.addingTimeInterval(90)) == .archived, "valid history appended")
        let originalBytes = try Data(contentsOf: file(ndir))
        try check(normal.archive(session("first", title: "replacement"), startedAt: t, endedAt: t.addingTimeInterval(400)) == .alreadyArchived, "duplicate result explicit")
        try check(try Data(contentsOf: file(ndir)) == originalBytes, "duplicate preserves exact bytes")
        let records = try normal.recordsChecked(for: t)
        try check(records.map(\.sessionId) == ["first", "second"], "order preserved")
        try check(records[0].title == "private-body-marker" && records[0].duration == 60 && records[0].endedAt == t.addingTimeInterval(60), "legacy fields and dates retained")
        try check(SessionArchiveStore(baseURL: ndir).archive(session("first"), startedAt: t, endedAt: t) == .alreadyArchived, "restart success dedup")
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file(ndir).path)
        try check(normal.archive(session("mode"), startedAt: t, endedAt: t) == .archived, "existing permissions append")
        try check((try fm.attributesOfItem(atPath: file(ndir).path)[.posixPermissions] as? NSNumber)?.intValue == 0o640, "original mode retained")
        for (i, malformed) in ["", "[{\"sessionId\":\"old\",\"truncated\":", "{}", "null", "[7]", "[{\"sessionId\":\"x\",\"startedAt\":\"bad\"}]"].enumerated() {
            let (s, dir) = store("corrupt-\(i)")
            let broken = Data(malformed.utf8); try broken.write(to: file(dir))
            let id = "pending-\(i)"
            try rejects("decode query") { _ = try s.recordsChecked(for: t) }
            try check(s.records(for: t).isEmpty && s.lastFailure?.kind == .decode, "compatibility query diagnoses corruption")
            try check(s.archive(session(id), startedAt: t, endedAt: t.addingTimeInterval(10)) == .pending, "corruption staged, not successful")
            try check(try Data(contentsOf: file(dir)) == broken, "corrupt original bytes retained")
            try check(s.pendingCount == 1 && s.durablePendingCount == 1, "durable staging counted separately")
            try check(s.retryPending() == 0, "still corrupt retry not success")
            try check(try Data(contentsOf: file(dir)) == broken, "retry never repairs original")
            try check((try fm.attributesOfItem(atPath: stageURL(dir, id).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "pending file private")
            let restarted = SessionArchiveStore(baseURL: dir)
            try check(restarted.pendingCount == 1, "pending recovered after restart")
            try Data("[]".utf8).write(to: file(dir))
            try check(restarted.retryPending() == 1, "corrected history retry succeeds")
            let fetched = try restarted.recordsChecked(for: t)
            try check(fetched.count == 1 && fetched[0].sessionId == id && fetched[0].endedAt == t.addingTimeInterval(10), "first failure time restored")
            try check(restarted.pendingCount == 0 && restarted.durablePendingCount == 0 && !fm.fileExists(atPath: stageURL(dir, id).path), "successful retry clears staging")
            try check(restarted.retryPending() == 0 && restarted.archive(session(id), startedAt: t, endedAt: t) == .alreadyArchived, "retry idempotent")
        }
        let (retry, rdir) = store("first-failure-time")
        try Data("broken".utf8).write(to: file(rdir))
        _ = retry.archive(session("immutable", title: "first"), startedAt: t, endedAt: t.addingTimeInterval(5))
        _ = retry.archive(session("immutable", title: "later"), startedAt: t, endedAt: t.addingTimeInterval(100))
        try Data("[]".utf8).write(to: file(rdir))
        try check(retry.retryPending() == 1, "first snapshot repeated retry")
        try check(retry.records(for: t).first?.title == "first" && retry.records(for: t).first?.duration == 5, "retry does not inflate duration")
        let (permissions, pdir) = store("permissions")
        let valid = Data("[]".utf8); try valid.write(to: file(pdir))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: file(pdir).path)
        try check(permissions.archive(session("unreadable"), startedAt: t, endedAt: t) == .pending, "unreadable history staged")
        try check(permissions.lastFailure?.kind == .read, "read failure classified")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(pdir).path)
        try check(try Data(contentsOf: file(pdir)) == valid && permissions.retryPending() == 1, "read failure original retained and retry")
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: pdir.path)
        try check(permissions.archive(session("write-failure"), startedAt: t, endedAt: t) == .pending, "unwritable daily directory can use existing pending directory")
        try check(permissions.lastFailure?.kind == .write, "write failure diagnosed")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pdir.path)
        try check(permissions.retryPending() == 1, "write permission recovery")
        let (blocked, bdir) = store("all-writes-blocked")
        try Data("broken".utf8).write(to: file(bdir))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: bdir.path)
        try check(blocked.archive(session("memory-only"), startedAt: t, endedAt: t) == .failed, "no disk copy is explicit failed")
        try check(blocked.pendingCount == 1 && blocked.durablePendingCount == 0, "memory-only retry distinct")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bdir.path)
        try Data("[]".utf8).write(to: file(bdir))
        try check(blocked.retryPending() == 1, "memory-only recovery")
        for kind in ["symlink", "directory", "hardlink"] {
            let (s, dir) = store("unsafe-" + kind)
            let target = dir.appendingPathComponent("external"); try valid.write(to: target)
            if kind == "symlink" { try fm.createSymbolicLink(at: file(dir), withDestinationURL: target) }
            if kind == "directory" { try fm.createDirectory(at: file(dir), withIntermediateDirectories: false) }
            if kind == "hardlink" { try fm.linkItem(at: target, to: file(dir)) }
            try check(s.archive(session(kind), startedAt: t, endedAt: t) == .pending, "unsafe target staged")
            try check(s.lastFailure?.kind == .unsafeFile, "unsafe classified")
            try check(try Data(contentsOf: target) == valid, "unsafe target outside bytes unchanged")
            try fm.removeItem(at: file(dir)); try valid.write(to: file(dir))
            try check(s.retryPending() == 1, "unsafe file corrected retry")
        }
        let missingRoot = root.appendingPathComponent("init-root-file")
        try Data("root".utf8).write(to: missingRoot)
        let initFailed = SessionArchiveStore(baseURL: missingRoot)
        try check(initFailed.archive(session("root-failure"), startedAt: t, endedAt: t) == .failed, "root creation failure explicit")
        try check(try Data(contentsOf: missingRoot) == Data("root".utf8), "root file unchanged")
        try fm.removeItem(at: missingRoot)
        try check(initFailed.retryPending() == 1, "root repaired retry")
        let linkedRoot = root.appendingPathComponent("linked-history")
        let outsideRoot = root.appendingPathComponent("unowned-history")
        try fm.createDirectory(at: outsideRoot, withIntermediateDirectories: false)
        try valid.write(to: file(outsideRoot))
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: outsideRoot)
        let linkStore = SessionArchiveStore(baseURL: linkedRoot)
        try check(linkStore.archive(session("root-link"), startedAt: t, endedAt: t) == .failed, "linked root is not used for staging")
        try check(!fm.fileExists(atPath: outsideRoot.appendingPathComponent(".pending").path) && Data(contentsOf: file(outsideRoot)) == valid, "linked root leaves external history unchanged")
        let (linkedStage, lsdir) = store("linked-staging")
        try Data("broken".utf8).write(to: file(lsdir))
        try fm.createSymbolicLink(at: lsdir.appendingPathComponent(".pending"), withDestinationURL: outsideRoot)
        try check(linkedStage.archive(session("pending-link"), startedAt: t, endedAt: t) == .failed, "linked staging refused")
        try check(try fm.contentsOfDirectory(atPath: outsideRoot.path).count == 1, "linked staging creates no external pending file")
        let (pendingCorrupt, pcdir) = store("bad-pending")
        try Data("broken".utf8).write(to: file(pcdir))
        _ = pendingCorrupt.archive(session("spool"), startedAt: t, endedAt: t)
        let spool = stageURL(pcdir, "spool"); try Data("bad-spool".utf8).write(to: spool)
        try check(pendingCorrupt.archive(session("spool"), startedAt: t, endedAt: t) == .failed, "bad spool not overwritten")
        try check(pendingCorrupt.durablePendingCount == 0, "corrupt spool is not counted as durable")
        try check(try Data(contentsOf: spool) == Data("bad-spool".utf8), "bad spool bytes preserved")
        try valid.write(to: file(pcdir))
        try check(pendingCorrupt.retryPending() == 1, "memory snapshot can commit after spool corruption")
        try check(try Data(contentsOf: spool) == Data("bad-spool".utf8), "cleanup preserves corrupt spool for inspection")
        let (dedupPending, dpdir) = store("success-before-cleanup")
        try Data("broken".utf8).write(to: file(dpdir))
        _ = dedupPending.archive(session("cleanup"), startedAt: t, endedAt: t)
        let staged = try decoder.decode(SessionArchive.self, from: Data(contentsOf: stageURL(dpdir, "cleanup")))
        try encoder.encode([staged]).write(to: file(dpdir))
        let recovered = SessionArchiveStore(baseURL: dpdir)
        try check(recovered.retryPending() == 1 && recovered.records(for: t).count == 1, "committed record plus leftover spool does not duplicate")
        let (stagedA, sharedStageDir) = store("cross-instance-first-failure")
        let stagedB = SessionArchiveStore(baseURL: sharedStageDir)
        try Data("broken".utf8).write(to: file(sharedStageDir))
        _ = stagedA.archive(session("cross-instance", title: "first-staged"), startedAt: t, endedAt: t.addingTimeInterval(3))
        try valid.write(to: file(sharedStageDir))
        try check(stagedB.archive(session("cross-instance", title: "later"), startedAt: t, endedAt: t.addingTimeInterval(100)) == .archived, "later instance discovers first staged snapshot")
        try check(stagedB.records(for: t).first?.title == "first-staged" && stagedB.records(for: t).first?.duration == 3, "first durable snapshot wins across instances")
        let (pruning, prdir) = store("retention")
        let recent = t.addingTimeInterval(200 * 86400)
        _ = pruning.archive(session("retention-old"), startedAt: t, endedAt: t)
        _ = pruning.archive(session("retention-new"), startedAt: recent, endedAt: recent)
        let corruptOld = file(prdir, t.addingTimeInterval(-86400)); try Data("corrupt-old".utf8).write(to: corruptOld)
        let corruptFuture = file(prdir, recent.addingTimeInterval(1000 * 86400)); try Data("corrupt-future".utf8).write(to: corruptFuture)
        let unknown = prdir.appendingPathComponent("notes.json"); try Data("unknown".utf8).write(to: unknown)
        pruning.pruneOlderThan(days: 90)
        try check(!fm.fileExists(atPath: file(prdir).path), "valid expired file removed")
        try check(fm.fileExists(atPath: file(prdir, recent).path), "corrupt future date does not skew retention")
        try check(try Data(contentsOf: corruptOld) == Data("corrupt-old".utf8) && Data(contentsOf: corruptFuture) == Data("corrupt-future".utf8), "retention preserves corrupt files")
        try check(try Data(contentsOf: unknown) == Data("unknown".utf8), "unknown JSON filename preserved")
        let (aggregation, adir) = store("aggregation")
        let day = Date().addingTimeInterval(-2 * 86400)
        _ = aggregation.archive(session("aggregate-a"), startedAt: day, endedAt: day)
        _ = aggregation.archive(session("aggregate-b"), startedAt: day.addingTimeInterval(2 * 86400), endedAt: day.addingTimeInterval(2 * 86400))
        try Data("corrupt-middle".utf8).write(to: file(adir, day.addingTimeInterval(86400)))
        try check(aggregation.allRecords(since: day).count == 2, "bad day does not hide other valid days")
        let midnight = Date(timeIntervalSince1970: 1_700_006_400)
        _ = aggregation.archive(session("utc"), startedAt: midnight, endedAt: midnight)
        try check(fm.fileExists(atPath: file(adir, midnight).path), "UTC filename unchanged")
        let concurrentDir = root.appendingPathComponent("concurrent")
        let a = SessionArchiveStore(baseURL: concurrentDir), b = SessionArchiveStore(baseURL: concurrentDir)
        let group = DispatchGroup()
        for n in 0..<40 {
            group.enter()
            let client = n % 2 == 0 ? a : b
            let s = session("parallel-\(n)")
            DispatchQueue.global().async { _ = client.archive(s, startedAt: t, endedAt: t); group.leave() }
        }
        try check(group.wait(timeout: .now() + 10) == .success, "parallel writes finish")
        try check(a.records(for: t).count == 40, "parallel store instances preserve all records")
        try check(b.archive(session("parallel-0"), startedAt: t, endedAt: t) == .alreadyArchived && b.records(for: t).count == 40, "cross-instance duplicate read before append")

        let (integrationArchive, idir) = store("session-integration")
        let sessions = SessionStore(doneToIdleAfter: 1, removeIdleAfter: 1, staleActiveAfter: 1)
        sessions.archiveStore = integrationArchive
        func event(_ name: String, _ id: String, _ at: Date, _ agent: AgentKind = .claude) -> AgentEvent {
            AgentEvent(sessionId: id, agentKind: agent, eventName: name, timestamp: at)
        }
        sessions.apply(event("PreToolUse", "expired", t), now: t)
        sessions.apply(event("Stop", "expired", t.addingTimeInterval(1)), now: t.addingTimeInterval(1))
        if let s = sessions.session(id: "expired") { sessions.markRead(id: s.id, through: s.notificationVersion) }
        sessions.prune(now: t.addingTimeInterval(3))
        try Data("broken".utf8).write(to: file(idir))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: idir.path)
        sessions.prune(now: t.addingTimeInterval(5))
        try check(sessions.session(id: "expired") != nil && integrationArchive.pendingCount == 1, "expiry retains source if history and staging fail")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: idir.path)
        try valid.write(to: file(idir))
        sessions.prune(now: t.addingTimeInterval(9))
        try check(sessions.session(id: "expired") == nil && integrationArchive.records(for: t).count == 1, "periodic prune retries then removes retained source")
        try check(integrationArchive.records(for: t).first?.endedAt == t.addingTimeInterval(5), "prune retry original end time")
        sessions.apply(event("PreToolUse", "end", t), now: t)
        try Data("broken".utf8).write(to: file(idir))
        sessions.apply(event("SessionEnd", "end", t.addingTimeInterval(20)), now: t.addingTimeInterval(20))
        try check(sessions.session(id: "end") == nil && integrationArchive.durablePendingCount == 1, "SessionEnd removes native session and stages failed history")
        try valid.write(to: file(idir))
        sessions.prune(now: t.addingTimeInterval(40))
        try check(integrationArchive.records(for: t).first?.sessionId == "end" && integrationArchive.pendingCount == 0, "SessionEnd periodic retry")
        try check(!integrationArchive.lastFailure!.description.contains("private-body-marker"), "diagnostic contains no record body")
        sessions.apply(event("session.created", "oc-deleted", t, .opencode), now: t)
        try Data("broken".utf8).write(to: file(idir))
        sessions.apply(event("deleted", "oc-deleted", t.addingTimeInterval(50), .opencode), now: t.addingTimeInterval(50))
        try check(sessions.session(id: "oc-deleted") == nil && integrationArchive.durablePendingCount == 1, "opencode deletion stages failed archive")
        try valid.write(to: file(idir))
        sessions.prune(now: t.addingTimeInterval(60))
        try check(integrationArchive.records(for: t).contains(where: { $0.sessionId == "oc-deleted" }), "opencode deletion retried by prune")
        try check(normal.archive(session("invalid"), startedAt: Date(timeIntervalSince1970: .nan), endedAt: t) == .failed, "invalid date rejected before filename/write")
        print("PASS: \(count) archive reliability checks (not the full XCTest suite)")
        return count
    }
}
