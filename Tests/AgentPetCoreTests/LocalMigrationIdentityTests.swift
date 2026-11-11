import XCTest
@testable import AgentPetCore

final class LocalMigrationIdentityTests: XCTestCase {
    private let bundle = "io.github.jiziol.agentpet-lite"

    func testReceiptMustBelongToExactPrivateRootsAndBundle() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for name in [".agentpet-local", ".agentpet-lite"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let source = home.path + "/.agentpet-local", destination = home.path + "/.agentpet-lite"
        let marker = URL(fileURLWithPath: destination + "/local-migration-v1.json")
        var record: [String: Any] = ["protocol": 1, "status": "copied", "sourceRoot": source,
            "destinationRoot": destination, "sourceBundle": "local.acerz.agentpet", "destinationBundle": bundle]
        func save() throws {
            try JSONSerialization.data(withJSONObject: record).write(to: marker)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
        XCTAssertNil(LocalMigrationIdentity.sourceRoot(destination: destination, home: home.path, bundle: bundle))
        try save()
        XCTAssertEqual(LocalMigrationIdentity.sourceRoot(destination: destination, home: home.path, bundle: bundle), source)
        record["destinationBundle"] = "another.app"; try save()
        XCTAssertNil(LocalMigrationIdentity.sourceRoot(destination: destination, home: home.path, bundle: bundle))
        record["destinationBundle"] = bundle; record["sourceRoot"] = home.path; try save()
        XCTAssertNil(LocalMigrationIdentity.sourceRoot(destination: destination, home: home.path, bundle: bundle))
        record["sourceRoot"] = source; record["status"] = "planned"; try save()
        XCTAssertNil(LocalMigrationIdentity.sourceRoot(destination: destination, home: home.path, bundle: bundle))
    }

    func testLockPreventsLocalAndLiteRunningTogetherAndReleasesOnFailure() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let local = home.path + "/local", lite = home.path + "/lite"
        let old = AgentPetInstanceLock(), migrated = AgentPetInstanceLock(), another = AgentPetInstanceLock()
        XCTAssertTrue(old.acquire(directories: [local]))
        XCTAssertFalse(migrated.acquire(directories: [local, lite]))
        XCTAssertTrue(another.acquire(directories: [lite]), "failed multi-lock acquisition must release earlier locks")
        old.release(); another.release()
        XCTAssertTrue(migrated.acquire(directories: [local, lite]))
        XCTAssertFalse(old.acquire(directories: [local]))
        migrated.release()
        XCTAssertTrue(old.acquire(directories: [local]))
    }

    func testGeneratedV1PluginUsesItsSelectedSocketRootAndStillOwnsOldTemplates() {
        let binary = "/Applications/AgentPet Lite.app/Contents/MacOS/agentpet"
        let current = OpencodePlugin.source(binary: binary, speechSocketPath: "/tmp/lite/agentpet.sock")
        XCTAssertTrue(current.contains("const folder = SPEECH_SOCKET.slice"))
        XCTAssertTrue(OpencodePlugin.isOwned(current))
        let previous = OpencodePlugin.source(binary: binary, speechSocketPath: "/tmp/local/agentpet.sock", legacyLocalDirectory: true)
        XCTAssertTrue(previous.contains("const folder = homedir()"))
        XCTAssertTrue(OpencodePlugin.isOwned(previous), "migration must retain exact ownership of the previous template")
        XCTAssertFalse(OpencodePlugin.isOwned(previous + "\n// user edit"))
    }

    func testCopiedQueuesKeepOneCopyWithoutDroppingDifferentOrLinkedFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let local = home.appendingPathComponent("local"), lite = home.appendingPathComponent("lite")
        for root in [local, lite] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("queue"), withIntermediateDirectories: true)
            try Data("same".utf8).write(to: root.appendingPathComponent("queue/same.json"))
            try Data(root.lastPathComponent.utf8).write(to: root.appendingPathComponent("queue/different.json"))
        }
        try Data("new".utf8).write(to: lite.appendingPathComponent("queue/new.json"))
        try FileManager.default.createSymbolicLink(at: lite.appendingPathComponent("queue/link.json"),
                                                 withDestinationURL: local.appendingPathComponent("queue/same.json"))
        LocalMigrationIdentity.removeCopiedQueueDuplicates(destination: lite.path, source: local.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lite.appendingPathComponent("queue/same.json").path))
        for name in ["different.json", "new.json", "link.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: lite.appendingPathComponent("queue/" + name).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("queue/same.json").path))
    }
}
