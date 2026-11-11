// Explicit private historical audit, excluded from routine test discovery.
// Run via scripts/audit-agy-records.sh; no live host/model task is started.
#if AGENTPET_NATIVE_RECORD_AUDITS
import XCTest
import Foundation
import CryptoKit
@testable import AgentPetCore

final class AntigravitySpeechNativeRecordTests: XCTestCase {
    func testInstalledNativeCompletedRecordsMatchExactHostPublicRowsWhenOptedIn() throws {
        let file = try XCTUnwrap(ProcessInfo.processInfo.environment["AGENTPET_AGY_RECORD_ANCHORS"],
                                 "Use scripts/audit-agy-records.sh aionui RECORD_INDEX_JSON")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        let rows = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            let id = try XCTUnwrap(row["id"] as? String)
            let start = Date(timeIntervalSinceReferenceDate: try XCTUnwrap(row["turnStartedAt"] as? Double))
            var session = AgentSession(id: id, agentKind: .antigravity, state: .done, source: .hook, updatedAt: start)
            session.turnStartedAt = start; session.antigravityEventAt = start
            session.antigravityStepFloor = try XCTUnwrap(row["antigravityStepFloor"] as? Int)
            let boundary = try XCTUnwrap(AntigravityVisibleMessage.Boundary(session: session, enabledAt: start))
            let path = try XCTUnwrap(AntigravityHumanInput.databasePath(sessionID: id))
            let snapshot = try XCTUnwrap(AntigravityPublicResponse.read(path: path, boundary: boundary))
            XCTAssertFalse(snapshot.cancelled)
            let step = try XCTUnwrap(snapshot.step)
            let host = try XCTUnwrap(AntigravityHostVisibility.read(nativeID: id, step: step,
                startedAt: start, knownRow: nil, database: AionUiMetadata.defaultDatabase))
            XCTAssertFalse(host.id.isEmpty)
            XCTAssertEqual(host.text, step.text)
            let digest = SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            print("native-public-record session_hash=\(digest) step=\(step.index) chars=\(step.text.count) host_match=true historical_only=true")
        }
    }
}
#endif
