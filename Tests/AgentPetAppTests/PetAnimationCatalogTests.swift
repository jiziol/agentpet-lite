import XCTest
import AppKit
@testable import agentpet

@MainActor
final class PetAnimationCatalogTests: XCTestCase {
    func testAllNinePurposesAllowMultipleAndOldDataIsNotOverwrittenOnRead() throws {
        let suite = "animation-rules-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PetAnimationBindings(byKey: Dictionary(uniqueKeysWithValues:
            PetAnimationBindings.selectionKeys.map { ($0, PetAnimationBinding(mode: .rotate, clipIDs: ["sheet:0", "sheet:1"])) }))
        let raw = try JSONEncoder().encode(settings)
        defaults.set(raw, forKey: "agentpet.animationBindings.v2.test")
        let pack = ImagePetPack(id: "test", displayName: "Test", description: nil,
                               clips: Array(repeating: [NSImage(size: .init(width: 1, height: 1))], count: 2),
                               directory: URL(fileURLWithPath: "/tmp"))
        let store = PetAnimationBindingsStore(defaults: defaults)
        for key in PetAnimationBindings.selectionKeys {
            let expected = PetAnimationBindings.selectionKeys.contains(key)
            XCTAssertEqual(store.bindings(for: pack).byKey[key]?.clipIDs.count, expected ? 2 : 1)
            store.set(.init(mode: .rotate, clipIDs: ["sheet:0", "sheet:1"]), key: key, pack: pack)
            XCTAssertEqual(store.bindings(for: pack).byKey[key]?.mode, expected ? .rotate : .fixed)
        }
        let readOnly = PetAnimationBindingsStore(defaults: UserDefaults(suiteName: suite)!)
        defaults.set(raw, forKey: "agentpet.animationBindings.v2.test")
        _ = readOnly.bindings(for: pack)
        XCTAssertEqual(defaults.data(forKey: "agentpet.animationBindings.v2.test"), raw)
    }
    func testLegacyMigrationKeepsChoiceClampsBadIndicesAndNeverOverwritesOldKey() throws {
        let suite = "animation-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = try JSONEncoder().encode(["levelup": 7, "working": -4])
        defaults.set(old, forKey: "agentpet.bindings.test")
        let pack = ImagePetPack(id: "test", displayName: "Test", description: nil,
                               clips: Array(repeating: [NSImage(size: .init(width: 1, height: 1))], count: 9),
                               directory: URL(fileURLWithPath: "/tmp"))
        let store = PetAnimationBindingsStore(defaults: defaults)
        XCTAssertEqual(store.bindings(for: pack).byKey["levelup"]?.clipIDs, ["sheet:7"])
        XCTAssertEqual(store.bindings(for: pack).byKey["working"]?.clipIDs, ["sheet:0"])
        store.set(.init(mode: .rotate, clipIDs: ["sheet:0", "sheet:1", "sheet:0", "missing"]), key: "working", pack: pack)
        XCTAssertEqual(store.bindings(for: pack).byKey["working"]?.clipIDs, ["sheet:0", "sheet:1"])
        XCTAssertEqual(defaults.data(forKey: "agentpet.bindings.test"), old)
        let restarted = PetAnimationBindingsStore(defaults: defaults)
        XCTAssertEqual(restarted.bindings(for: pack), store.bindings(for: pack))
        restarted.restoreLegacy(for: pack)
        XCTAssertEqual(restarted.bindings(for: pack).byKey["levelup"]?.clipIDs, ["sheet:7"])
    }

    func testCatalogRejectsTraversalDuplicatesMissingFilesAndOversizedDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        try FileManager.default.copyItem(at: media.appendingPathComponent("videos/东张西望.mov"), to: root.appendingPathComponent("clip.mov"))
        try FileManager.default.copyItem(at: media.appendingPathComponent("posters/东张西望.png"), to: root.appendingPathComponent("poster.png"))
        func write(_ changes: [String: Any] = [:], duplicate: Bool = false) throws {
            var row: [String: Any] = ["id": "dsh:a", "name": "动作", "category": "玩耍",
                                      "file": "clip.mov", "poster": "poster.png", "duration": 10,
                                      "width": 640, "height": 360]
            row.merge(changes) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "clips": duplicate ? [row, row] : [row]])
            try data.write(to: root.appendingPathComponent("animations.json"))
        }
        try write()
        XCTAssertEqual(PetAnimationCatalog.load(directory: root).count, 1)
        try write(["purposes": ["working"], "displayName": "思考"])
        XCTAssertEqual(PetAnimationCatalog.load(directory: root).first?.purposes, ["working"])
        XCTAssertEqual(PetAnimationCatalog.load(directory: root).first?.displayName, "思考")
        let invalid: [[String: Any]] = [["file": "../clip.mov"], ["file": "/tmp/clip.mov"],
                                       ["file": "missing.mov"], ["duration": 601], ["id": "sheet:0"],
                                       ["purposes": ["unknown"]]]
        for changes in invalid {
            try write(changes)
            XCTAssertTrue(PetAnimationCatalog.load(directory: root).isEmpty)
        }
        try write(duplicate: true)
        XCTAssertEqual(PetAnimationCatalog.load(directory: root).count, 1, "Duplicate rejects only the later row")
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.mov"), withDestinationURL: outside)
        XCTAssertNil(PetAnimationCatalog.localFile("link.mov", directory: root))
    }

    func testCuratedNativeGroupsDoNotInjectSheetRowsAndKeepUserChoicesReadOnly() throws {
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let source = try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
        let frame = try XCTUnwrap(source.clips.first)
        let pack = ImagePetPack(id: "curated", displayName: "Curated", description: nil,
            clips: Array(repeating: frame, count: 9), directory: directory, videoClips: source.videoClips)
        let suite = "curated-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var chosen: [String: PetAnimationBinding] = [:]
        for key in PetAnimationBindings.selectionKeys {
            let expected = pack.videoClips.filter { $0.purposes.contains(key) }.map(\.id)
            XCTAssertFalse(expected.isEmpty)
            XCTAssertEqual(pack.candidateIDs(for: key), expected, "Respect the actual curated purpose list for \(key)")
            chosen[key] = .init(mode: .rotate, clipIDs: Array(expected.suffix(1)))
            XCTAssertEqual(pack.nativeFallbackID(for: key), expected.first)
        }
        let saved = PetAnimationBindings(byKey: chosen)
        let raw = try JSONEncoder().encode(saved)
        defaults.set(raw, forKey: "agentpet.animationBindings.v2.curated")
        let prepared = PetAnimationBindingsStore(defaults: defaults).bindings(for: pack)
        XCTAssertEqual(prepared, saved)
        XCTAssertEqual(defaults.data(forKey: "agentpet.animationBindings.v2.curated"), raw)
        let groups = PetAnimationRemoval.groups(pack: pack, bindings: prepared)
        XCTAssertTrue(groups.values.allSatisfy { !$0.contains(where: { $0.hasPrefix("sheet:") }) })
    }

    func testCuratedGroupsRetainAnExplicitLegacySpriteChoiceAndUserMembership() throws {
        let directory = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        let source = try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
        var pack = ImagePetPack(id: "mixed-choice", displayName: "Mixed", description: nil,
            clips: Array(repeating: try XCTUnwrap(source.clips.first), count: 9),
            directory: directory, videoClips: source.videoClips)
        let mapped = try XCTUnwrap(pack.candidateIDs(for: "working").first)
        let saved = PetAnimationBindings(byKey: ["working": .init(mode: .rotate, clipIDs: ["sheet:8", mapped])])
        let suite = "curated-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = try JSONEncoder().encode(saved)
        defaults.set(raw, forKey: "agentpet.animationBindings.v2.mixed-choice")
        let store = PetAnimationBindingsStore(defaults: defaults)
        let prepared = store.bindings(for: pack)
        XCTAssertEqual(prepared.byKey["working"]?.clipIDs, ["sheet:8", mapped])
        XCTAssertTrue(PetAnimationRemoval.groups(pack: pack, bindings: prepared)["working"]?.contains("sheet:8") == true)
        // Existing explicit groups, including records from earlier R3 versions,
        // remain authoritative. No read-time cleanup or hidden file deletion.
        pack.animationGroups["working"] = ["sheet:8", mapped]
        XCTAssertEqual(pack.candidateIDs(for: "working"), ["sheet:8", mapped])
        XCTAssertEqual(store.bindings(for: pack).byKey["working"]?.clipIDs, ["sheet:8", mapped])
        XCTAssertEqual(defaults.data(forKey: "agentpet.animationBindings.v2.mixed-choice"), raw)
    }

}
