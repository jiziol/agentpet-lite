import XCTest
import Foundation
import AppKit
import SwiftUI
import CSQLite
@testable import AgentPetCore
@testable import agentpet

@MainActor
final class AntigravitySpeechObservationTests: XCTestCase {
    func testTerminalStopExportTraversesCoordinatorIntoFiveSecondNativePanel() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let enabled = settings.petBubbleEnabled, hidden = settings.hiddenKinds
        let controller = PetController()
        let split = controller.splitPet, show = controller.showChat
        settings.petBubbleEnabled = true; settings.hiddenKinds = []
        controller.splitPet = false; controller.showChat = true
        defer {
            controller.clearProgress(); PetWindowController.shared.stop()
            controller.splitPet = split; controller.showChat = show
            settings.petBubbleEnabled = enabled; settings.hiddenKinds = hidden
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let at = Date()
        var session = AgentSession(id: UUID().uuidString.lowercased(), agentKind: .antigravity,
                                   state: .working, source: .hook, updatedAt: at)
        session.turnStartedAt = at; session.antigravityEventAt = at; session.antigravityStepFloor = 0
        let db = dir.appendingPathComponent("conversations/\(session.id).db").path
        let transcript = dir.appendingPathComponent("brain/\(session.id)/.system_generated/logs/transcript_full.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (db as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        controller.update(sessions: [session])
        var received = 0
        let coordinator = SessionObservationCoordinator(current: { $0 == session.id ? session : nil }, receive: { _ in },
            human: { _, _, _, _ in }, agyMessage: { _, message in
                received += 1; controller.showProgress(message, session: session)
            }, agySpeechPath: { _ in db })
        defer { coordinator.stop() }
        coordinator.setMessagesEnabled(true); coordinator.reconcile([session])
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let row: [String: Any] = ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
                                 "created_at": ISO8601DateFormatter().string(from: Date()), "content": "终端完成正文验证", "thinking": "PRIVATE"]
        var data = try JSONSerialization.data(withJSONObject: row); data.append(10)
        try data.write(to: transcript, options: .atomic)
        session.state = .done; session.antigravityTurnResult = .completed
        session.turnEndedAt = Date(); session.antigravityEventAt = session.turnEndedAt
        controller.update(sessions: [session]); coordinator.reconcile([session])
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(received, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db), "The timely route cannot depend on SQLite being saved")
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "AgentPet Lite Pet Messages" && $0.isVisible })
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<PetSpeechView>)
        let model = host.rootView.model
        XCTAssertEqual(model.speechRows.first?.text, "终端完成正文验证")
        XCTAssertEqual(model.speechRows.first?.label, "@agy[1]")
        let expiry = try XCTUnwrap(model.speechRows.first?.expiresAt)
        RunLoop.main.run(until: Date().addingTimeInterval(3.2))
        XCTAssertTrue(panel.isVisible); XCTAssertEqual(model.speechRows.first?.expiresAt, expiry)
        coordinator.reconcile([session])
        RunLoop.main.run(until: expiry.addingTimeInterval(0.15))
        XCTAssertEqual(received, 1); XCTAssertTrue(model.speechRows.isEmpty); XCTAssertFalse(panel.isVisible)
    }

    func testCommittedSourceTraversesCoordinatorAndDisableRestartCannotReplay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("own-native.db").path
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        func sql(_ s: String) { XCTAssertEqual(sqlite3_exec(db, s, nil, nil, nil), SQLITE_OK) }
        func v(_ input: UInt64) -> Data {
            var n = input; var result = Data()
            repeat { let b = UInt8(n & 127); n >>= 7; result.append(b | (n == 0 ? 0 : 128)) } while n != 0
            return result
        }
        func b(_ n: Int, _ data: Data) -> Data { v(UInt64(n << 3 | 2)) + v(UInt64(data.count)) + data }
        func text(_ n: Int, _ text: String) -> Data { b(n, Data(text.utf8)) }
        func time(_ date: Date) -> Data {
            let t = date.timeIntervalSince1970, s = floor(t)
            return Data([8]) + v(UInt64(s)) + Data([16]) + v(UInt64((t - s) * 1e9))
        }
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        sql("CREATE TABLE steps(idx INTEGER PRIMARY KEY,step_type INTEGER,status INTEGER,metadata BLOB,step_payload BLOB)")
        sql("CREATE TABLE executor_metadata(idx INTEGER PRIMARY KEY,data BLOB)")
        sql("INSERT INTO executor_metadata VALUES(0,X'\(hex(Data([8,4,24,10]) + text(9,"execution")))')")
        let at = Date()
        var session = AgentSession(id: UUID().uuidString.lowercased(), agentKind: .antigravity, state: .working, source: .hook, updatedAt: at)
        session.turnStartedAt = at; session.antigravityEventAt = at; session.antigravityStepFloor = 10
        var received: [AntigravityVisibleMessage] = []
        let coordinator = SessionObservationCoordinator(current: { $0 == session.id ? session : nil }, receive: { _ in },
            human: { _, _, _, _ in }, agyMessage: { id, message in
                XCTAssertEqual(id, session.id); XCTAssertTrue(message.boundary.matches(session)); received.append(message)
            }, agySpeechPath: { _ in path })
        defer { coordinator.stop() }
        coordinator.setMessagesEnabled(true); coordinator.reconcile([session])
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        func commit(_ body: String) {
            let now = Date()
            let metadata = text(12,"execution") + b(1,time(at)) + b(6,time(now)) + b(7,time(now)) + b(8,time(now))
            let payload = Data([8,15,32,3]) + b(20,text(1,body) + text(3,"PRIVATE_THINKING"))
            sql("INSERT OR REPLACE INTO steps VALUES(10,15,3,X'\(hex(metadata))',X'\(hex(payload))')")
        }
        commit("正在检查消息归属")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(received.count, 1); XCTAssertEqual(received.first?.text, "正在检查消息归属")
        coordinator.setMessagesEnabled(false)
        commit("关闭期间的正文")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(received.count, 1)
        coordinator.setMessagesEnabled(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(received.count, 1, "Restart starts a fresh observation baseline")
        commit("重新开启后的新正文")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(received.count, 2)
        coordinator.stop(); commit("退出后的文字")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(received.count, 2)
    }
}
