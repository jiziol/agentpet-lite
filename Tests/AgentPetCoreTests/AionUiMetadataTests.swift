import Foundation
import XCTest
import CSQLite
@testable import AgentPetCore

final class AionUiMetadataTests: XCTestCase {
    private let native = "11111111-1111-4111-8111-111111111111"
    private let other = "ses_other"
    private let clock = Date(timeIntervalSince1970: 100)

    private func fixture(_ body: (String, OpaquePointer) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("backend.db").path
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        defer { sqlite3_close(db) }
        try execute(db, "CREATE TABLE conversations(id TEXT PRIMARY KEY,name TEXT,type TEXT,extra TEXT,archived_at INTEGER); CREATE TABLE acp_session(conversation_id TEXT PRIMARY KEY,session_id TEXT); CREATE TABLE teams(id TEXT PRIMARY KEY,name TEXT,lead_agent_id TEXT,agents TEXT,archived_at INTEGER);")
        try body(path, db)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "AionUiFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func insert(_ db: OpaquePointer, id: String = "chat_a", sessionID: String? = nil,
                        backend: String = "antigravity", title: String = "Host title", archived: Bool = false,
                        extra extraFields: [String: String] = [:]) throws {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let payload = ["backend": backend, "workspace": "/same/project"].merging(extraFields) { _, new in new }
        let extra = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        try execute(db, "INSERT INTO conversations VALUES(\(quote(id)),\(quote(title)),'acp',\(quote(extra)),\(archived ? "1" : "NULL")); INSERT INTO acp_session VALUES(\(quote(id)),\(quote(sessionID ?? native)));")
    }

    private func insertTeam(_ db: OpaquePointer, id: String = "team_a", name: String = "Team Alpha",
                            lead: String? = "slot_lead",
                            agents: [[String: String]] = [["slot_id": "slot_lead", "role": "lead",
                                                          "conversation_id": "chat_a", "backend": "antigravity"]],
                            archived: Bool = false) throws {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let json = String(data: try JSONSerialization.data(withJSONObject: agents, options: [.sortedKeys]), encoding: .utf8)!
        let leadValue = lead.map { quote($0) } ?? "NULL"
        try execute(db, "INSERT INTO teams VALUES(\(quote(id)),\(quote(name)),\(leadValue),\(quote(json)),\(archived ? "1" : "NULL"));")
    }

    private func record(_ path: String, sessionID: String? = nil, kind: AgentKind = .antigravity) throws -> AionUiMetadata.Record {
        guard case .matched(let record) = AionUiMetadata.read(sessionID: sessionID ?? native, agentKind: kind, database: path) else {
            XCTFail("Expected exact association")
            throw NSError(domain: "AionUiFixture", code: 2)
        }
        return record
    }

    func testExactNativeIDProducesHostRouteWithoutConversationIDGuessing() throws {
        try fixture { path, db in
            try insert(db)
            let match = try record(path)
            XCTAssertEqual(match.conversation.id, "chat_a")
            let url = try XCTUnwrap(match.conversation.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "aionui")
            XCTAssertEqual(components.host, "navigate")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "route", value: "/conversation/chat_a")])
            XCTAssertEqual(AionUiMetadata.read(sessionID: "chat_a", agentKind: .antigravity, database: path), .notFound)
        }
    }

    func testSameTitleAndWorkspaceCannotBindOtherSession() throws {
        try fixture { path, db in
            try insert(db, sessionID: other)
            XCTAssertEqual(AionUiMetadata.read(sessionID: native, agentKind: .antigravity, database: path), .notFound)
        }
    }

    func testWrongBackendCannotBindMatchingNativeID() throws {
        try fixture { path, db in
            try insert(db, backend: "opencode")
            XCTAssertEqual(AionUiMetadata.read(sessionID: native, agentKind: .antigravity, database: path), .notFound)
            XCTAssertEqual(try record(path, kind: .opencode).conversation.agentKind, .opencode)
        }
    }

    func testAmbiguousNativeIDNeverChoosesFirstConversation() throws {
        try fixture { path, db in
            try insert(db)
            try insert(db, id: "chat_b")
            XCTAssertEqual(AionUiMetadata.read(sessionID: native, agentKind: .antigravity, database: path), .ambiguous)
        }
    }

    func testArchivedConversationDoesNotStealLiveAssociation() throws {
        try fixture { path, db in
            try insert(db, archived: true)
            XCTAssertEqual(AionUiMetadata.read(sessionID: native, agentKind: .antigravity, database: path), .notFound)
            try insert(db, id: "chat_b")
            XCTAssertEqual(try record(path).conversation.id, "chat_b")
        }
    }

    func testVerifiedBindingCanStillOpenAfterIdleACPAnchorIsReleased() throws {
        try fixture { path, db in
            try insert(db)
            let target = try record(path).conversation
            try execute(db, "DELETE FROM acp_session")
            XCTAssertEqual(AionUiMetadata.read(sessionID: native, agentKind: .antigravity, database: path), .notFound)
            guard case .matched(let confirmed) = AionUiMetadata.revalidate(target, database: path) else {
                return XCTFail("Stored exact host association should survive idle runtime release")
            }
            XCTAssertEqual(confirmed.conversation, target)
            try execute(db, "UPDATE conversations SET archived_at=1")
            XCTAssertEqual(AionUiMetadata.revalidate(target, database: path), .notFound)
        }
    }

    func testInvalidStoredRoutesAndNativeInputsAreRejected() throws {
        for id in ["", "../settings", "a/b", "a?prompt=run", "a#fragment", "a%2Fother", "a\n", String(repeating: "a", count: 129)] {
            XCTAssertNil(AionUiConversation(id: id, nativeSessionID: native, agentKind: .antigravity).url)
        }
        try fixture { path, db in
            try insert(db, id: "../settings")
            XCTAssertEqual(AionUiMetadata.read(sessionID: native, agentKind: .antigravity, database: path), .notFound)
            XCTAssertEqual(AionUiMetadata.read(sessionID: "' OR 1=1 --", agentKind: .antigravity, database: path), .notFound)
        }
    }

    func testMissingDatabaseIsNotCreated() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertEqual(AionUiMetadata.read(sessionID: native, agentKind: .antigravity, database: path), .notFound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testEmbeddedNULCannotTruncateAStoredConversationIntoAnotherRoute() throws {
        try fixture { path, db in
            try insert(db)
            try execute(db, "UPDATE conversations SET id='chat_a' || char(0) || 'suffix'; UPDATE acp_session SET conversation_id='chat_a' || char(0) || 'suffix'")
            XCTAssertEqual(AionUiMetadata.read(sessionID: native, agentKind: .antigravity, database: path), .notFound)
        }
    }

    func testBrokenSchemaIsUnavailableRatherThanNoAssociation() throws {
        try fixture { path, db in
            try execute(db, "DROP TABLE acp_session")
            XCTAssertEqual(AionUiMetadata.read(sessionID: native, agentKind: .antigravity, database: path), .unavailable)
        }
    }

    func testReadDoesNotModifyDatabaseAndUsesLatestRenamedHostTitle() throws {
        try fixture { path, db in
            try insert(db)
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertEqual(try record(path).title, "Host title")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
            try execute(db, "UPDATE conversations SET name='New host title' WHERE id='chat_a'")
            XCTAssertEqual(try record(path).title, "New host title")
        }
    }

    func testTitleIsWhitespaceNormalizedAndBounded() throws {
        try fixture { path, db in
            try insert(db, title: " \n host\t" + String(repeating: "字", count: 500))
            let title = try XCTUnwrap(try record(path).title)
            XCTAssertTrue(title.hasPrefix("host "))
            XCTAssertEqual(title.count, 240)
        }
    }

    func testMalformedExtraDoesNotGuessAgentFromACPTransport() throws {
        try fixture { path, db in
            try insert(db)
            try execute(db, "UPDATE conversations SET extra='invalid'")
            XCTAssertEqual(AionUiMetadata.read(sessionID: native, agentKind: .antigravity, database: path), .notFound)
        }
    }

    func testHostAttachmentPreservesRunningStateClocksAndReceiptRevision() throws {
        try fixture { path, db in
            try insert(db)
            let store = SessionStore()
            let before = try XCTUnwrap(store.apply(AgentEvent(sessionId: native, agentKind: .antigravity,
                eventName: "PreInvocation", terminalProgram: "iTerm.app", terminalTTY: "/dev/ttys009", timestamp: clock), now: clock))
            XCTAssertTrue(store.updateAionUiMetadata(id: native, createdAt: before.createdAt, record: try record(path)))
            let after = try XCTUnwrap(store.session(id: native))
            XCTAssertEqual(after.state, before.state)
            XCTAssertEqual(after.indicator, .running)
            XCTAssertEqual(after.updatedAt, before.updatedAt)
            XCTAssertEqual(after.stateSince, before.stateSince)
            XCTAssertEqual(after.turnStartedAt, before.turnStartedAt)
            XCTAssertEqual(after.notificationVersion, before.notificationVersion)
            XCTAssertEqual(after.displayRevision, before.displayRevision)
            XCTAssertEqual(after.terminalProgram, "iTerm.app")
            XCTAssertEqual(after.validAionUiConversation?.id, "chat_a")
            store.markOpened(after, at: clock.addingTimeInterval(1))
            XCTAssertEqual(store.session(id: native)?.indicator, .running)
        }
    }

    func testCompletedHostMessageOnlyTurnsGreenAfterExplicitSuccessfulRead() throws {
        try fixture { path, db in
            try insert(db)
            let store = SessionStore()
            var event = AgentEvent(sessionId: native, agentKind: .antigravity, eventName: "Stop", timestamp: clock)
            event.turnResult = .completed
            let before = try XCTUnwrap(store.apply(event, now: clock))
            store.updateAionUiMetadata(id: native, createdAt: before.createdAt, record: try record(path))
            let clicked = try XCTUnwrap(store.session(id: native))
            XCTAssertEqual(clicked.indicator, .unread)
            store.markOpened(clicked, at: clock.addingTimeInterval(1))
            XCTAssertEqual(store.session(id: native)?.indicator, .read)
        }
    }

    func testLateMetadataCannotAttachToRecreatedSession() throws {
        try fixture { path, db in
            try insert(db)
            let store = SessionStore()
            store.apply(AgentEvent(sessionId: native, agentKind: .antigravity, eventName: "PreInvocation", timestamp: clock), now: clock)
            store.remove(id: native)
            let later = clock.addingTimeInterval(10)
            store.apply(AgentEvent(sessionId: native, agentKind: .antigravity, eventName: "PreInvocation", timestamp: later), now: later)
            XCTAssertFalse(store.updateAionUiMetadata(id: native, createdAt: clock, record: try record(path)))
            XCTAssertNil(store.session(id: native)?.aionUiConversation)
        }
    }

    func testHostBindingSurvivesSnapshotRestoreWithoutChangingUnread() throws {
        try fixture { path, db in
            try insert(db)
            let store = SessionStore()
            store.persistenceURL = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("snapshot.json")
            let before = try XCTUnwrap(store.apply(AgentEvent(sessionId: native, agentKind: .antigravity, eventName: "Stop", timestamp: clock), now: clock))
            store.updateAionUiMetadata(id: native, createdAt: before.createdAt, record: try record(path))
            let restored = SessionStore()
            restored.persistenceURL = store.persistenceURL
            restored.restoreCodexSessions()
            XCTAssertEqual(restored.session(id: native), store.session(id: native))
            XCTAssertEqual(restored.session(id: native)?.indicator, .unread)
        }
    }

    /// A stored live verification round-trips, and snapshots without the field
    /// (older builds) stay readable as "historical / pending re-check".
    func testVerificationRoundTripsAndOlderSnapshotsStayReadable() throws {
        var session = AgentSession(id: native, agentKind: .antigravity, state: .done, source: .hook, updatedAt: clock)
        session.createdAt = clock
        session.aionUiConversation = .init(id: "chat_a", nativeSessionID: native, agentKind: .antigravity,
                                           teamID: "team_a", teamName: "Team Alpha", teamRole: .lead)
        session.aionUiVerification = .init(conversationID: "chat_a", teamID: "team_a", teamRole: .lead,
                                           sessionCreatedAt: clock, verifiedAt: clock)
        let dto = AgentSessionDTO(session)
        let encoded = try JSONEncoder().encode(dto)
        XCTAssertEqual(try JSONDecoder().decode(AgentSessionDTO.self, from: encoded).session, session)
        XCTAssertEqual(try JSONDecoder().decode(AgentSessionDTO.self, from: encoded).session
            .attestableAionUiVerification?.teamRole, .lead)
        // A snapshot without the key (and an older no-host-field snapshot) never
        // fabricates a verification.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "aionUiVerification")
        let legacySession = try JSONDecoder()
            .decode(AgentSessionDTO.self, from: try JSONSerialization.data(withJSONObject: legacy)).session
        XCTAssertNil(legacySession.aionUiVerification)
        XCTAssertNil(legacySession.attestableAionUiVerification)
        let plain = AgentSession(id: native, agentKind: .opencode, state: .working, source: .hook, updatedAt: clock)
        XCTAssertNil(try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(plain)).aionUiVerification)
    }

    /// A restored snapshot never inherits "currently verified": a check from an
    /// earlier launch is history even when it is 0 s old, while its identity and
    /// time stay readable. A fresh check in the new launch heals it.
    func testRestoredSnapshotNeverInheritsVerificationAcrossLaunches() throws {
        try fixture { path, db in
            try insertTeam(db, agents: [["slot_id": "slot_lead", "role": "lead",
                                         "conversation_id": "chat_a", "backend": "antigravity"]])
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            let url = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("snapshot.json")
            AionUiVerificationLaunch.beginLaunch("launch-1")
            let store = SessionStore()
            store.persistenceURL = url
            let session = try XCTUnwrap(store.apply(AgentEvent(sessionId: native, agentKind: .antigravity,
                eventName: "PreInvocation", timestamp: clock), now: clock))
            XCTAssertTrue(store.updateAionUiMetadata(id: native, createdAt: session.createdAt,
                                                     record: try record(path), verifiedAt: clock))
            XCTAssertEqual(store.session(id: native)?.aionUiVerification?.launchEpoch, "launch-1")
            XCTAssertEqual(store.session(id: native)?.aionUiVerification?.launchEpoch,
                           AionUiVerificationLaunch.epoch)
            // Relaunch: the persisted check is history, its identity and time kept.
            AionUiVerificationLaunch.beginLaunch("launch-2")
            let restored = SessionStore()
            restored.persistenceURL = store.persistenceURL
            restored.restoreCodexSessions()
            let restoredSession = try XCTUnwrap(restored.session(id: native))
            XCTAssertEqual(restoredSession.aionUiVerification?.launchEpoch, "launch-1")
            XCTAssertNotEqual(restoredSession.aionUiVerification?.launchEpoch, AionUiVerificationLaunch.epoch,
                              "the persisted check belongs to the previous launch even at 0 s")
            XCTAssertEqual(restoredSession.aionUiVerification?.verifiedAt, clock)
            XCTAssertEqual(restoredSession.validAionUiTeam?.teamRole, .lead)
            XCTAssertEqual(restoredSession.attestableAionUiVerification?.conversationID, "chat_a")
            // A fresh check inside the new launch restores currency in memory
            // without a snapshot write for an unchanged identity.
            XCTAssertFalse(restored.updateAionUiMetadata(id: native, createdAt: session.createdAt,
                                                         record: try record(path),
                                                         verifiedAt: clock.addingTimeInterval(1)))
            XCTAssertEqual(restored.session(id: native)?.aionUiVerification?.launchEpoch,
                           AionUiVerificationLaunch.epoch)
            XCTAssertEqual(restored.session(id: native)?.aionUiVerification?.verifiedAt,
                           clock.addingTimeInterval(1))
        }
    }

    func testOlderSnapshotsWithoutHostFieldRemainReadable() throws {
        let session = AgentSession(id: native, agentKind: .opencode, state: .working, source: .hook, updatedAt: clock)
        let data = try JSONEncoder().encode(session)
        XCTAssertNil(try JSONDecoder().decode(AgentSession.self, from: data).validAionUiConversation)
        var wrong = session
        wrong.aionUiConversation = AionUiConversation(id: "chat_a", nativeSessionID: other, agentKind: .opencode)
        XCTAssertNil(wrong.validAionUiConversation)
    }

    func testPiFileIdentityUsesExactACPIndexAndPreservesClickedIdentity() throws {
        try fixture { path, db in
            try insert(db, backend: "pi")
            let map = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("pi-map.json")
            let file = "/synthetic/pi-session.jsonl", id = "pi:/synthetic/pi-session.jsonl"
            try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [native: ["sessionId": native, "sessionFile": file]]]).write(to: map)
            guard case .matched(let record) = AionUiMetadata.read(sessionID: id, agentKind: .pi, database: path, piSessionMap: map.path) else {
                return XCTFail("Pi's file identity must resolve through the ACP map")
            }
            XCTAssertEqual(record.conversation.nativeSessionID, id)
            XCTAssertEqual(record.conversation.id, "chat_a")
            XCTAssertEqual(record.conversation.agentKind, .pi)
            let store = SessionStore()
            let before = try XCTUnwrap(store.apply(.init(sessionId: id, agentKind: .pi, eventName: "done", timestamp: clock), now: clock))
            XCTAssertTrue(store.updateAionUiMetadata(id: id, createdAt: before.createdAt, record: record))
            XCTAssertEqual(store.session(id: id)?.validAionUiConversation, record.conversation)
            XCTAssertEqual(store.session(id: id)?.state, before.state)
            XCTAssertEqual(store.session(id: id)?.notificationVersion, before.notificationVersion)
            try FileManager.default.removeItem(at: map)
            try execute(db, "DELETE FROM acp_session")
            guard case .matched(let confirmed) = AionUiMetadata.revalidate(record.conversation, database: path) else {
                return XCTFail("An already verified Pi binding can outlive the idle ACP anchor")
            }
            XCTAssertEqual(confirmed.conversation, record.conversation)
            try execute(db, "UPDATE conversations SET archived_at=1")
            XCTAssertEqual(AionUiMetadata.revalidate(record.conversation, database: path), .notFound)
        }
    }

    func testPiMappingNeverGuessesFromFileNameAndRejectsWrongOrAmbiguousHost() throws {
        try fixture { path, db in
            let map = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("pi-map.json")
            let id = "pi:/synthetic/" + native + ".jsonl"
            try insert(db, backend: "pi")
            XCTAssertEqual(AionUiMetadata.read(sessionID: id, agentKind: .pi, database: path, piSessionMap: map.path), .notFound)
            try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [native: ["sessionId": native, "sessionFile": String(id.dropFirst(3))]]]).write(to: map)
            try execute(db, "UPDATE conversations SET extra='{\"backend\":\"codex\"}'")
            XCTAssertEqual(AionUiMetadata.read(sessionID: id, agentKind: .pi, database: path, piSessionMap: map.path), .notFound)
            try execute(db, "UPDATE conversations SET extra='{\"backend\":\"pi\"}'")
            try insert(db, id: "chat_b", backend: "pi")
            XCTAssertEqual(AionUiMetadata.read(sessionID: id, agentKind: .pi, database: path, piSessionMap: map.path), .ambiguous)
        }
    }

    func testVerifiedGUIHostIsNotHiddenAsAnUnidentifiedCodexCompletion() {
        var session = AgentSession(id: native, agentKind: .codex, state: .done, source: .hook, updatedAt: clock)
        XCTAssertTrue(session.isUnidentifiedCodexCompletion)
        session.aionUiConversation = AionUiConversation(id: "chat_a", nativeSessionID: native, agentKind: .codex)
        XCTAssertFalse(session.isUnidentifiedCodexCompletion)
    }

    // MARK: - AionUI Teams

    func testTeamAssociationValidatesSlotConversationBackendAndLead() throws {
        try fixture { path, db in
            try insertTeam(db, agents: [
                ["slot_id": "slot_lead", "role": "lead", "conversation_id": "chat_a", "backend": "antigravity"],
                ["slot_id": "slot_mate", "role": "teammate", "conversation_id": "chat_b", "backend": "antigravity"]])
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            let lead = try record(path)
            XCTAssertEqual(lead.conversation.teamID, "team_a")
            XCTAssertEqual(lead.conversation.teamName, "Team Alpha")
            XCTAssertEqual(lead.conversation.teamRole, .lead)
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(lead.conversation.teamURL),
                                                         resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "route", value: "/team/team_a")])
            try insert(db, id: "chat_b", sessionID: other, extra: ["teamId": "team_a", "slot_id": "slot_mate"])
            let mate = try record(path, sessionID: other)
            XCTAssertEqual(mate.conversation.teamRole, .teammate)
            XCTAssertEqual(mate.conversation.teamName, "Team Alpha")
        }
    }

    func testTeamMarkSurvivesFailedVerificationWithoutDegrading() throws {
        // slot.conversation_id does not name the conversation being resolved
        try fixture { path, db in
            try insertTeam(db, agents: [["slot_id": "slot_lead", "role": "lead",
                                         "conversation_id": "chat_b", "backend": "antigravity"]])
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            let match = try record(path)
            XCTAssertEqual(match.conversation.teamID, "team_a")
            XCTAssertNil(match.conversation.teamName)
            XCTAssertNil(match.conversation.teamRole)
        }
        // slot.backend does not match the resolved agent kind
        try fixture { path, db in
            try insertTeam(db, agents: [["slot_id": "slot_lead", "role": "lead",
                                         "conversation_id": "chat_a", "backend": "opencode"]])
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            XCTAssertNil(try record(path).conversation.teamRole)
        }
        // duplicate slot entries are not a unique identity
        try fixture { path, db in
            try insertTeam(db, agents: [["slot_id": "slot_lead", "role": "lead",
                                         "conversation_id": "chat_a", "backend": "antigravity"],
                                        ["slot_id": "slot_lead", "role": "teammate",
                                         "conversation_id": "chat_a", "backend": "antigravity"]])
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            let match = try record(path)
            XCTAssertEqual(match.conversation.teamID, "team_a")
            XCTAssertNil(match.conversation.teamRole)
        }
        // archived team keeps the mark but drops verification
        try fixture { path, db in
            try insertTeam(db, archived: true)
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            let match = try record(path)
            XCTAssertEqual(match.conversation.teamID, "team_a")
            XCTAssertNil(match.conversation.teamRole)
        }
        // a missing team row keeps the mark for safe display/navigation
        try fixture { path, db in
            try insert(db, extra: ["teamId": "team_missing", "slot_id": "slot_lead"])
            let match = try record(path)
            XCTAssertEqual(match.conversation.teamID, "team_missing")
            XCTAssertNil(match.conversation.teamRole)
            XCTAssertNotNil(match.conversation.teamURL)
        }
        // role claims lead while lead_agent_id names another slot
        try fixture { path, db in
            try insertTeam(db, lead: "slot_other", agents: [["slot_id": "slot_lead", "role": "lead",
                                                             "conversation_id": "chat_a", "backend": "antigravity"]])
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            XCTAssertNil(try record(path).conversation.teamRole)
        }
        // no Team mark at all: the ordinary association is untouched
        try fixture { path, db in
            try insert(db)
            let match = try record(path)
            XCTAssertNil(match.conversation.teamID)
            XCTAssertNil(match.conversation.teamURL)
            XCTAssertEqual(match.conversation.url?.absoluteString.contains("/conversation/chat_a"), true)
        }
    }

    func testShippedLeadSpellingAndDefensiveAliasBothValidate() throws {
        try fixture { path, db in
            try insertTeam(db, agents: [["slot_id": "slot_lead", "role": "leader",
                                         "conversation_id": "chat_a", "backend": "antigravity"]])
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            XCTAssertEqual(try record(path).conversation.teamRole, .lead)
        }
        try fixture { path, db in
            // lead_agent_id names this slot while its role says teammate
            try insertTeam(db, agents: [["slot_id": "slot_lead", "role": "teammate",
                                         "conversation_id": "chat_a", "backend": "antigravity"]])
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            XCTAssertNil(try record(path).conversation.teamRole)
        }
    }

    /// A Team association whose live re-check keeps failing loses its cached
    /// verification immediately, then its verified role after the bounded grace
    /// window, while keeping the raw Team mark for safe display/navigation. A
    /// later successful re-check heals everything.
    func testUnverifiableTeamVerificationIsDroppedAndLaterSelfHeals() throws {
        try fixture { path, db in
            try insertTeam(db, agents: [["slot_id": "slot_lead", "role": "lead",
                                         "conversation_id": "chat_a", "backend": "antigravity"]])
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            let store = SessionStore()
            let session = try XCTUnwrap(store.apply(AgentEvent(sessionId: native, agentKind: .antigravity,
                eventName: "PreInvocation", timestamp: clock), now: clock))
            XCTAssertTrue(store.updateAionUiMetadata(id: native, createdAt: session.createdAt,
                                                     record: try record(path), verifiedAt: clock))
            let verified = try XCTUnwrap(store.session(id: native))
            XCTAssertEqual(verified.validAionUiTeam?.teamRole, .lead)
            XCTAssertEqual(verified.attestableAionUiVerification?.conversationID, "chat_a")
            XCTAssertEqual(verified.attestableAionUiVerification?.teamID, "team_a")
            XCTAssertEqual(verified.attestableAionUiVerification?.sessionCreatedAt, session.createdAt)
            XCTAssertEqual(verified.attestableAionUiVerification?.verifiedAt, clock)
            // First unverifiable check: the cached verification goes, the mark stays.
            XCTAssertTrue(store.clearAionUiVerification(id: native, createdAt: session.createdAt, clearRole: false))
            let lapsed = try XCTUnwrap(store.session(id: native))
            XCTAssertNil(lapsed.attestableAionUiVerification)
            XCTAssertEqual(lapsed.validAionUiTeam?.teamRole, .lead)
            XCTAssertEqual(lapsed.aionUiTeamScope?.teamName, "Team Alpha")
            XCTAssertFalse(store.clearAionUiVerification(id: native, createdAt: session.createdAt, clearRole: false))
            // A recreated instance and a missing session change nothing.
            XCTAssertFalse(store.clearAionUiVerification(id: native, createdAt: clock.addingTimeInterval(999),
                                                         clearRole: true))
            XCTAssertFalse(store.clearAionUiVerification(id: "missing", createdAt: clock, clearRole: true))
            // Grace window expired: the role is dropped, the raw mark stays.
            XCTAssertTrue(store.clearAionUiVerification(id: native, createdAt: session.createdAt, clearRole: true))
            let degraded = try XCTUnwrap(store.session(id: native))
            XCTAssertNil(degraded.validAionUiTeam)
            XCTAssertEqual(degraded.aionUiTeamScope?.teamID, "team_a")
            XCTAssertEqual(degraded.aionUiTeamScope?.teamName, "Team Alpha")
            XCTAssertNotNil(degraded.validAionUiConversation)
            // A later successful re-check restores the verified identity.
            XCTAssertTrue(store.updateAionUiMetadata(id: native, createdAt: session.createdAt,
                                                     record: try record(path), verifiedAt: clock.addingTimeInterval(61)))
            let healed = try XCTUnwrap(store.session(id: native))
            XCTAssertEqual(healed.validAionUiTeam?.teamRole, .lead)
            XCTAssertEqual(healed.attestableAionUiVerification?.verifiedAt, clock.addingTimeInterval(61))
        }
    }

    /// A refreshed check time is not a content change: the same identity is not
    /// rewritten into the snapshot on every poll.
    func testRefreshedVerificationTimeDoesNotRewriteTheSameIdentity() throws {
        try fixture { path, db in
            try insertTeam(db, agents: [["slot_id": "slot_lead", "role": "lead",
                                         "conversation_id": "chat_a", "backend": "antigravity"]])
            try insert(db, extra: ["teamId": "team_a", "slot_id": "slot_lead"])
            let store = SessionStore()
            let session = try XCTUnwrap(store.apply(AgentEvent(sessionId: native, agentKind: .antigravity,
                eventName: "PreInvocation", timestamp: clock), now: clock))
            XCTAssertTrue(store.updateAionUiMetadata(id: native, createdAt: session.createdAt,
                                                     record: try record(path), verifiedAt: clock))
            XCTAssertFalse(store.updateAionUiMetadata(id: native, createdAt: session.createdAt,
                                                      record: try record(path), verifiedAt: clock.addingTimeInterval(2)))
            // The refreshed time is still kept in memory.
            XCTAssertEqual(store.session(id: native)?.attestableAionUiVerification?.verifiedAt,
                           clock.addingTimeInterval(2))
        }
    }

    func testConversationCodableKeepsTeamFieldsOptionalForOlderSnapshots() throws {
        let legacy = Data(#"{"id":"chat_a","nativeSessionID":"n","agentKind":"codex"}"#.utf8)
        let decoded = try JSONDecoder().decode(AionUiConversation.self, from: legacy)
        XCTAssertNil(decoded.teamID)
        XCTAssertNil(decoded.teamName)
        XCTAssertNil(decoded.teamRole)
        XCTAssertNil(decoded.teamURL)
        let modern = AionUiConversation(id: "chat_a", nativeSessionID: "n", agentKind: .codex,
                                        teamID: "team_a", teamName: "Team Alpha", teamRole: .lead)
        let round = try JSONDecoder().decode(AionUiConversation.self, from: JSONEncoder().encode(modern))
        XCTAssertEqual(round, modern)
        XCTAssertEqual(round.teamRole, .lead)
        XCTAssertEqual(round.teamURL, modern.teamURL)
    }
}
