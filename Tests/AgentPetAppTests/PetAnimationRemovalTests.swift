import XCTest
import AppKit
import SwiftUI
import AgentPetCore
@testable import agentpet

@MainActor
final class PetAnimationRemovalTests: XCTestCase {
    override func setUpWithError() throws { try TestIsolation.require() }
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r3-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func preferences() throws -> UserDefaults {
        let name = "r3-removal-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func nativeMovie() throws -> URL {
        try XCTUnwrap(BundledDefaultPet.resourceDirectory).appendingPathComponent("videos/东张西望.mov")
    }
    private func installNative(_ directory: URL, id: String = "one") throws -> ImagePetPack {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = try PetAnimationMedia.inspect(nativeMovie())
        try info.posterPNG.write(to: directory.appendingPathComponent("sheet.png"))
        let manifest: [String: Any] = ["id": id, "displayName": "Test", "spritesheetPath": "sheet.png", "spritesheetLayout": "single"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("pet.json"))
        return try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
    }
    private func imported(_ directory: URL, key: String = "working") throws -> (ImagePetPack, String) {
        var pack = try installNative(directory)
        let store = PetAnimationBindingsStore(defaults: try preferences())
        let result = PetAnimationLibrary.importFiles([try nativeMovie()], directory: directory, key: key,
            seedGroups: PetAnimationRemoval.groups(pack: pack, bindings: store.bindings(for: pack)), nativeCount: 0)
        XCTAssertTrue(result.failures.isEmpty)
        pack.loadAnimations()
        return (pack, try XCTUnwrap(result.importedIDs.first))
    }

    func testCannotRemoveLastNativeEvenWhenCustomRemainsAndBulkIsAllOrNothing() throws {
        let directory = try sandbox(), (pack, id) = try imported(directory)
        let file = directory.appendingPathComponent(PetAnimationLibrary.filename)
        let before = try Data(contentsOf: file)
        let store = PetAnimationBindingsStore(defaults: try preferences())
        for ids: Set<String> in [["sheet:0"], ["sheet:0", id]] {
            XCTAssertThrowsError(try PetAnimationLibrary.remove(ids: ids, key: "working", pack: pack, bindings: store.bindings(for: pack)))
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(pack.video(for: id)).url.path))
        }
    }

    func testOldNineSpritesCanBeRemovedFromDragWhileNativeMovieRemains() throws {
        let directory = try sandbox(), native = try installNative(directory)
        let movie = PetVideoClip(id: "drag-native", name: "Drag", category: "Drag", url: try nativeMovie(), poster: nil, duration: 5, width: 640, height: 360, purposes: ["drag"])
        var pack = ImagePetPack(id: native.id, displayName: native.displayName, description: nil,
            clips: Array(repeating: native.clips[0], count: 9), directory: directory, videoClips: [movie])
        // A group materialized by the old R3 candidate can explicitly contain
        // all rows. Preserve that record until the user removes them.
        pack.animationGroups["drag"] = (0..<9).map { "sheet:\($0)" } + [movie.id]
        try JSONEncoder().encode(PetAnimationLibrary.Document(groups: pack.animationGroups))
            .write(to: directory.appendingPathComponent(PetAnimationLibrary.filename))
        let settings = PetAnimationBindings(byKey: ["drag": .init(clipIDs: [movie.id])])
        let ids = Set((0..<9).map { "sheet:\($0)" })
        let result = try PetAnimationLibrary.remove(ids: ids, key: "drag", pack: pack, bindings: settings)
        XCTAssertEqual(result.binding.clipIDs, [movie.id])
        let nativeAfter = try Data(contentsOf: directory.appendingPathComponent("sheet.png"))
        XCTAssertFalse(nativeAfter.isEmpty)
        let doc = try JSONDecoder().decode(PetAnimationLibrary.Document.self, from: Data(contentsOf: directory.appendingPathComponent(PetAnimationLibrary.filename)))
        XCTAssertEqual(doc.groups["drag"], [movie.id])
        XCTAssertTrue(doc.groups["idle"]?.contains("sheet:8") == true)
        var restarted = pack; restarted.loadAnimations()
        // This synthetic native movie is not in animations.json; group records,
        // rather than file deletion or bundle edits, carry the removal intent.
        XCTAssertFalse(restarted.candidateIDs(for: "drag").contains("sheet:0"))
    }

    func testSharedReferenceSurvivesFirstGroupRemovalThenLastReferenceCleansOwnedFiles() throws {
        let directory = try sandbox(), (initial, id) = try imported(directory)
        let file = directory.appendingPathComponent(PetAnimationLibrary.filename)
        var doc = try JSONDecoder().decode(PetAnimationLibrary.Document.self, from: Data(contentsOf: file))
        doc.groups["tap", default: []].append(id)
        try JSONEncoder().encode(doc).write(to: file, options: .atomic)
        var pack = initial; pack.loadAnimations()
        let original = try nativeMovie(), originalBytes = try Data(contentsOf: original)
        let owned = try XCTUnwrap(pack.video(for: id)).url
        let settings = PetAnimationBindings(byKey: ["working": .init(clipIDs: [id]), "tap": .init(clipIDs: [id])])
        let first = try PetAnimationLibrary.remove(ids: [id], key: "working", pack: pack, bindings: settings)
        XCTAssertTrue(first.warnings.isEmpty)
        XCTAssertEqual(first.binding.clipIDs, ["sheet:0"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        pack.loadAnimations()
        XCTAssertFalse(pack.candidateIDs(for: "working").contains(id))
        XCTAssertTrue(pack.candidateIDs(for: "tap").contains(id))
        var revised = settings; revised.byKey["working"] = first.binding
        let second = try PetAnimationLibrary.remove(ids: [id], key: "tap", pack: pack, bindings: revised)
        XCTAssertTrue(second.warnings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        pack.loadAnimations()
        XCTAssertFalse(pack.animationIDs.contains(id))
        XCTAssertTrue(pack.animationIssues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sheet.png").path))
    }

    func testStoreRepairsBindingAndRestartCannotResurrectRemovedAssetOrSprite() async throws {
        let root = try sandbox(), directory = root.appendingPathComponent("one")
        let (pack, id) = try imported(directory)
        let defaults = try preferences(), store = PetAnimationBindingsStore(defaults: defaults)
        store.set(.init(clipIDs: [id]), key: "working", pack: pack)
        let library = ImagePetStore(petsDirectory: root, bindingsStore: store); library.reload()
        let warnings = try await library.removeAnimations([id], for: pack.id, key: "working")
        XCTAssertTrue(warnings.isEmpty)
        let after = try XCTUnwrap(library.pack(id: pack.id))
        XCTAssertEqual(store.bindings(for: after).byKey["working"]?.clipIDs, ["sheet:0"])
        let restarted = try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
        XCTAssertFalse(restarted.candidateIDs(for: "working").contains(id))
        XCTAssertEqual(PetAnimationBindingsStore(defaults: defaults).bindings(for: restarted).byKey["working"]?.clipIDs, ["sheet:0"])
        XCTAssertFalse(library.importingPetIDs.contains(pack.id))
    }

    func testCrashBeforePreferenceRepairStillUsesRetainedNativeAndOtherPetIsUnaffected() throws {
        let directory = try sandbox(), (pack, id) = try imported(directory)
        let defaults = try preferences(), store = PetAnimationBindingsStore(defaults: defaults)
        store.set(.init(clipIDs: [id]), key: "working", pack: pack)
        let oldPreferences = defaults.data(forKey: "agentpet.animationBindings.v2.one")
        _ = try PetAnimationLibrary.remove(ids: [id], key: "working", pack: pack, bindings: store.bindings(for: pack))
        XCTAssertEqual(defaults.data(forKey: "agentpet.animationBindings.v2.one"), oldPreferences)
        let after = try XCTUnwrap(SpriteSlicer.loadPack(directory: directory))
        XCTAssertEqual(PetAnimationBindingsStore(defaults: defaults).bindings(for: after).byKey["working"]?.clipIDs, ["sheet:0"])
        let other = try installNative(try sandbox(), id: "other")
        XCTAssertEqual(PetAnimationBindingsStore(defaults: defaults).bindings(for: other).byKey["working"]?.clipIDs, ["sheet:0"])
    }

    func testRemovalSelectionNeverInheritsPlaybackAndReentryOrGroupExitClearsIt() {
        var mode = PetAnimationRemovalSelection()
        let playback = PetAnimationBinding(mode: .rotate, clipIDs: ["sheet:0", "video"])
        mode.enter(); XCTAssertTrue(mode.ids.isEmpty)
        mode.toggle("video"); XCTAssertEqual(mode.ids, ["video"])
        XCTAssertEqual(playback.clipIDs, ["sheet:0", "video"])
        mode.enter(); XCTAssertTrue(mode.ids.isEmpty)
        mode.toggle("sheet:0"); mode.exit()
        XCTAssertFalse(mode.active); XCTAssertTrue(mode.ids.isEmpty)
    }

    func testNativeFileAliasRetainsImportedMediaOwnership() throws {
        let directory = try sandbox(), (initial, id) = try imported(directory)
        let owned = try XCTUnwrap(initial.video(for: id))
        var pack = initial
        pack.videoClips.append(PetVideoClip(id: "native-alias", name: "Native", category: "Native",
            url: owned.url, poster: owned.poster, duration: owned.duration, width: owned.width,
            height: owned.height, purposes: ["tap"]))
        pack.animationGroups["tap", default: ["sheet:0"]].append("native-alias")
        let settings = PetAnimationBindings(byKey: ["working": .init(clipIDs: [id])])
        let plan = try PetAnimationRemoval.plan(ids: [id], key: "working", pack: pack, bindings: settings)
        XCTAssertFalse(plan.unreferencedImportedIDs.contains(id), "A native entry still reads this managed file")
    }

    func testCleanupDoesNotFollowManagedFileSymlinkOrRemoveUnrelatedFiles() throws {
        for useSymlink in [true, false] {
            let directory = try sandbox(), (pack, id) = try imported(directory)
            let clip = try XCTUnwrap(pack.video(for: id)), folder = clip.url.deletingLastPathComponent()
            let external = try sandbox().appendingPathComponent("user.mov")
            let original = Data("user original".utf8); try original.write(to: external)
            let extra = folder.appendingPathComponent("unrelated.txt")
            try original.write(to: extra)
            if useSymlink {
                let poster = folder.appendingPathComponent("poster.png")
                try FileManager.default.removeItem(at: poster)
                try FileManager.default.createSymbolicLink(at: poster, withDestinationURL: external)
            }
            let settings = PetAnimationBindingsStore(defaults: try preferences()).bindings(for: pack)
            let result = try PetAnimationLibrary.remove(ids: [id], key: "working", pack: pack, bindings: settings)
            XCTAssertEqual(result.warnings.isEmpty, !useSymlink)
            XCTAssertEqual(try Data(contentsOf: external), original)
            XCTAssertEqual(try Data(contentsOf: extra), original)
            XCTAssertEqual(FileManager.default.fileExists(atPath: clip.url.path), useSymlink,
                           "Prevalidate both owned files before cleaning either")
        }
    }

    func testRemovedNativeMembershipDoesNotReappearOnRestartOrLaterImport() throws {
        let directory = try sandbox(), base = try installNative(directory)
        let pack = ImagePetPack(id: base.id, displayName: base.displayName, description: nil,
            clips: [base.clips[0], base.clips[0]], directory: directory)
        let settings = PetAnimationBindings(byKey: ["working": .init(clipIDs: ["sheet:1"])])
        let first = try PetAnimationLibrary.remove(ids: ["sheet:1"], key: "working", pack: pack, bindings: settings)
        XCTAssertEqual(first.binding.clipIDs, ["sheet:0"])
        var restarted = pack; restarted.loadAnimations()
        let prepared = PetAnimationBindingsStore(defaults: try preferences()).bindings(for: restarted)
        XCTAssertEqual(restarted.candidateIDs(for: "working"), ["sheet:0"])
        let result = PetAnimationLibrary.importFiles([try nativeMovie()], directory: directory, key: "tap",
            seedGroups: PetAnimationRemoval.groups(pack: restarted, bindings: prepared), nativeCount: 0)
        XCTAssertEqual(result.importedIDs.count, 1)
        restarted.loadAnimations()
        XCTAssertEqual(restarted.candidateIDs(for: "working"), ["sheet:0"])
        XCTAssertTrue(restarted.candidateIDs(for: "idle").contains("sheet:1"))
    }

    func testInvalidSelectionOrDamagedLibraryDoesNotPartiallyMutate() throws {
        let directory = try sandbox(), (pack, id) = try imported(directory)
        let file = directory.appendingPathComponent(PetAnimationLibrary.filename)
        let settings = PetAnimationBindingsStore(defaults: try preferences()).bindings(for: pack)
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try PetAnimationLibrary.remove(ids: [id, "missing"], key: "working", pack: pack, bindings: settings))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let damaged = Data("{bad".utf8); try damaged.write(to: file)
        XCTAssertThrowsError(try PetAnimationLibrary.remove(ids: [id], key: "working", pack: pack, bindings: settings))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testShiftRangeWorksInBothDirectionsAndShrinksWithoutLosingOtherMarks() {
        let order = ["a", "b", "c", "d", "e", "f"]
        var selection = PetAnimationRemovalSelection()
        selection.enter()
        selection.select("f", extendingRange: false, orderedIDs: order)
        selection.select("d", extendingRange: false, orderedIDs: order)
        selection.select("a", extendingRange: true, orderedIDs: order)
        XCTAssertEqual(selection.ids, ["a", "b", "c", "d", "f"])
        selection.select("c", extendingRange: true, orderedIDs: order)
        XCTAssertEqual(selection.ids, ["c", "d", "f"], "Shrinking a range keeps unrelated marks, without stale range items")
        selection.select("e", extendingRange: true, orderedIDs: order)
        XCTAssertEqual(selection.ids, ["d", "e", "f"])
    }

    func testMarqueeReplacesOrAddsAndDraggingBackDoesNotKeepOldHits() {
        var selection = PetAnimationRemovalSelection()
        selection.enter(); selection.toggle("old")
        selection.beginMarquee(additive: false)
        selection.updateMarquee(intersecting: ["a", "b"])
        XCTAssertEqual(selection.ids, ["a", "b"])
        selection.updateMarquee(intersecting: ["a"])
        XCTAssertEqual(selection.ids, ["a"])
        selection.endMarquee()
        selection.beginMarquee(additive: true)
        selection.updateMarquee(intersecting: ["c", "d"])
        XCTAssertEqual(selection.ids, ["a", "c", "d"])
        selection.updateMarquee(intersecting: [])
        XCTAssertEqual(selection.ids, ["a"], "Empty additive rectangle preserves the pre-drag selection")
        selection.endMarquee()
        selection.beginMarquee(additive: false)
        selection.updateMarquee(intersecting: [])
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testExitDropsRangeAnchorAndLateDragUpdatesCannotReselectAfterCancel() {
        var selection = PetAnimationRemovalSelection()
        selection.enter(); selection.toggle("a")
        selection.beginMarquee(additive: true)
        selection.updateMarquee(intersecting: ["b"])
        selection.exit()
        selection.updateMarquee(intersecting: ["c"])
        XCTAssertTrue(selection.ids.isEmpty)
        selection.enter()
        selection.select("c", extendingRange: true, orderedIDs: ["a", "b", "c"])
        XCTAssertEqual(selection.ids, ["c"], "A new deletion session must not inherit the old anchor")
    }

    func testMarqueeHitsPartialCardsInAnyDragDirectionAndIgnoresTouchingBorders() {
        let frames: [String: CGRect] = [
            "a": CGRect(x: 10, y: 10, width: 80, height: 80),
            "b": CGRect(x: 100, y: 10, width: 80, height: 80),
            "c": CGRect(x: 10, y: 100, width: 80, height: 80)]
        XCTAssertEqual(PetAnimationRemovalSelection.intersectingIDs(
            rect: CGRect(x: 50, y: 50, width: 60, height: 40), frames: frames), ["a", "b"])
        XCTAssertEqual(PetAnimationRemovalSelection.intersectingIDs(
            rect: CGRect(x: 110, y: 90, width: -60, height: -40), frames: frames), ["a", "b"])
        XCTAssertTrue(PetAnimationRemovalSelection.intersectingIDs(
            rect: CGRect(x: 90, y: 0, width: 10, height: 100), frames: frames).isEmpty)
    }

}
