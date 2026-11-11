import XCTest
import Darwin
@testable import AgentPetCore

final class PiACPIdentityTests: XCTestCase {
    private let native = "11111111-1111-4111-8111-111111111111"
    private let other = "22222222-2222-4222-8222-222222222222"
    private let file = "/synthetic/session.jsonl"
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("session-map.json"))
    }
    private func write(_ sessions: [String: Any], to path: URL, version: Int = 1) throws {
        try JSONSerialization.data(withJSONObject: ["version": version, "sessions": sessions]).write(to: path)
    }
    func testExactPathMapsToNativeUUIDWithoutOpeningTranscript() throws {
        try fixture { path in
            try write([native: ["sessionId": native, "sessionFile": file, "cwd": "/same"]], to: path)
            let bytes = try Data(contentsOf: path)
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:" + file, path: path.path), .matched(native))
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:/same/session.jsonl", path: path.path), .notFound)
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:/synthetic", path: path.path), .notFound)
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }
    func testConflictingPathMappingIsAmbiguous() throws {
        try fixture { path in
            try write([native: ["sessionId": native, "sessionFile": file], other: ["sessionId": other, "sessionFile": file]], to: path)
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:" + file, path: path.path), .ambiguous)
        }
    }
    func testBadIdentitySchemaAndInvalidJSONAreUnavailable() throws {
        try fixture { path in
            for id in ["' OR 1=1 --", "invalid", other] {
                try write([native: ["sessionId": id, "sessionFile": file]], to: path)
                XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:" + file, path: path.path), .unavailable)
            }
            try write([native: ["sessionId": native, "sessionFile": file]], to: path, version: 2)
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:" + file, path: path.path), .unavailable)
            try Data("invalid".utf8).write(to: path)
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:" + file, path: path.path), .unavailable)
        }
    }
    func testMissingMapNeverCreatedAndRawUUIDNeverGuessed() throws {
        try fixture { path in
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:" + file, path: path.path), .notFound)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
            XCTAssertEqual(PiACPIdentity.read(sessionID: native, path: path.path), .notFound)
        }
    }
    func testInvalidPathsAreRejected() {
        for id in ["pi:relative.jsonl", "pi:/a/../b.jsonl", "pi:/a\u{0}.jsonl", "pi:/a\n.jsonl", "pi:/a.jsonl/", "pi:/" + String(repeating: "a", count: 4100) + ".jsonl"] {
            XCTAssertNil(PiACPIdentity.sessionFile(id))
        }
    }
    func testOversizedMapAndUnsafeFileTypesFailWithoutBlocking() throws {
        try fixture { path in
            try Data(repeating: 32, count: PiACPIdentity.maxBytes + 1).write(to: path)
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:" + file, path: path.path), .unavailable)
            let link = path.deletingLastPathComponent().appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:" + file, path: link.path), .unavailable)
            let fifo = path.deletingLastPathComponent().appendingPathComponent("fifo.json").path
            XCTAssertEqual(mkfifo(fifo, 0o600), 0)
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:" + file, path: fifo), .unavailable)
            XCTAssertEqual(PiACPIdentity.read(sessionID: "pi:" + file, path: path.deletingLastPathComponent().path), .unavailable)
        }
    }
}
