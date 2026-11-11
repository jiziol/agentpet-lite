import XCTest
import AppKit
import CryptoKit
import AgentPetCore
@testable import agentpet

@MainActor
final class BundledDefaultPetTests: XCTestCase {
    private func sandbox() throws -> (URL, UserDefaults, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-pet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "bundled-pet-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (directory, defaults, suite)
    }
    private func cleanup(_ root: URL, _ defaults: UserDefaults, _ suite: String) {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    func testCleanOfflineInstallLoadsAllGroupsAndFreshCareWithoutSavedBindings() throws {
        let (root, defaults, suite) = try sandbox()
        defer { cleanup(root, defaults, suite) }
        // The old network attempt marker must not block the new offline starter.
        defaults.set(true, forKey: "agentpet.defaultPetTried")
        let pets = root.appendingPathComponent("pets")
        let result = try BundledDefaultPet.installIfNeeded(resourceDirectory: BundledDefaultPet.resourceDirectory,
            petsDirectory: pets, selectedPetID: nil, defaults: defaults)
        XCTAssertEqual(result, .installed("deepseek"))
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: pets.appendingPathComponent("deepseek")))
        XCTAssertEqual(pack.clips.count, 1)
        XCTAssertEqual(pack.clips[0].count, 1)
        XCTAssertEqual(pack.clips[0][0].size, NSSize(width: 160, height: 90), "Detached poster details stay in one frame")
        XCTAssertEqual(pack.displayName, "deepseek酱")
        XCTAssertEqual(pack.videoClips.count, 33)
        let expected = ["idle": 9, "working": 4, "waiting": 4, "success": 5,
                        "failure": 2, "quota": 2, "levelup": 3, "tap": 3, "drag": 1]
        let bindings = PetAnimationBindingsStore(defaults: defaults).bindings(for: pack)
        for (purpose, count) in expected {
            let ids = Set(pack.videoClips.filter { $0.purposes.contains(purpose) }.map(\.id))
            XCTAssertEqual(ids.count, count)
            XCTAssertEqual(Set(bindings.byKey[purpose]?.clipIDs ?? []), ids)
            XCTAssertTrue(pack.videoClips.filter { $0.purposes.contains(purpose) }.allSatisfy { $0.poster != nil })
        }
        XCTAssertNil(defaults.object(forKey: "agentpet.care.v2"))
        XCTAssertNil(defaults.object(forKey: "agentpet.animationBindings.v2.deepseek"))
        XCTAssertNil(defaults.object(forKey: "agentpet.petNames"))
        XCTAssertEqual(PetCare.displayLevel(forXP: PetCareState().xp), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pack.directory.appendingPathComponent("spritesheet.webp").path))
        let again = try BundledDefaultPet.installIfNeeded(resourceDirectory: nil, petsDirectory: pets,
                                                        selectedPetID: nil, defaults: defaults)
        XCTAssertEqual(again, .skipped)
    }

    func testFactoryPresetGroupOrderIsExactAndPersonalStateIsAbsent() throws {
        let (root, defaults, suite) = try sandbox()
        defer { cleanup(root, defaults, suite) }
        let pets = root.appendingPathComponent("pets")
        XCTAssertEqual(try BundledDefaultPet.installIfNeeded(resourceDirectory: BundledDefaultPet.resourceDirectory,
            petsDirectory: pets, selectedPetID: nil, defaults: defaults), .installed("deepseek"))
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: pets.appendingPathComponent("deepseek")))
        let expected: [String: [String]] = [
            "idle": ["dsh:悠闲哼歌", "dsh:三球抛接", "dsh:优雅女仆舞", "dsh:是啊，吃什么", "dsh:玩游戏气急败坏", "dsh:原地小憩沉眠", "dsh:吃白饭", "dsh:哈欠连天", "dsh:超大伸懒腰"],
            "working": ["dsh:写代码", "dsh:工作状态-忙碌点按", "dsh:轻快记录", "dsh:吃Token"],
            "waiting": ["dsh:东张西望", "dsh:工作状态-原地踱步张望", "dsh:工作状态-思考冒泡", "dsh:用鲸鱼尾巴拍打地面"],
            "success": ["dsh:工作状态-雀跃庆祝", "dsh:点击回应-元气挥手", "dsh:点击回应-开心跃动", "dsh:轻快摇摆舞", "dsh:可爱宅舞"],
            "failure": ["dsh:工作状态-垂头叹气冒汗", "dsh:点击回应-傲娇生气"],
            "quota": ["dsh:余额-分文不剩", "dsh:余额-袋空如洗"],
            "levelup": ["dsh:拆礼物", "dsh:整体换装试色", "dsh:原地跳跃抓碎头顶物品"],
            "tap": ["dsh:点击回应-害羞惊讶", "dsh:点击回应-挠痒咯咯笑", "dsh:打瞌睡被惊醒"],
            "drag": ["dsh:被鼠标拖拽悬空反馈"],
        ]
        let selected = PetAnimationBindingsStore(defaults: defaults).bindings(for: pack)
        XCTAssertEqual(Set(selected.byKey.keys), PetAnimationBindings.selectionKeys)
        for (key, ids) in expected {
            XCTAssertEqual(pack.candidateIDs(for: key), ids)
            XCTAssertEqual(selected.byKey[key], PetAnimationBinding(mode: .rotate, clipIDs: ids))
        }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            pack.directory.appendingPathComponent("pet.json"))) as? [String: Any])
        XCTAssertEqual(Set(manifest.keys), ["id", "displayName", "description", "spritesheetPath", "spritesheetLayout"])
        XCTAssertNil(defaults.object(forKey: "agentpet.care.v2"))
        XCTAssertNil(defaults.object(forKey: "agentpet.petNames"))
        XCTAssertNil(defaults.object(forKey: "agentpet.animationBindings.v2.deepseek"))
        let fresh = PetCareState()
        XCTAssertEqual(fresh.xp, 0)
        XCTAssertEqual(PetCare.displayLevel(forXP: fresh.xp), 0)
        let restarted = try XCTUnwrap(SpriteSlicer.loadPack(directory: pack.directory))
        XCTAssertEqual(PetAnimationBindingsStore(defaults: defaults).bindings(for: restarted), selected)
    }

    func testExistingChoiceAndUserStateArePreservedByteForByte() throws {
        let (root, defaults, suite) = try sandbox()
        defer { cleanup(root, defaults, suite) }
        let state = Data("existing-private-care-state".utf8)
        let binding = Data("existing-custom-animation-binding".utf8)
        defaults.set(state, forKey: "agentpet.care.v2")
        defaults.set(binding, forKey: "agentpet.animationBindings.v2.deepseek")
        defaults.set(["deepseek": "My companion"], forKey: "agentpet.petNames")
        let before = defaults.persistentDomain(forName: suite)!
        let pets = root.appendingPathComponent("pets")
        XCTAssertEqual(try BundledDefaultPet.installIfNeeded(resourceDirectory: nil, petsDirectory: pets,
                                                            selectedPetID: "my-custom-pet", defaults: defaults), .preserved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pets.path))
        for (key, value) in before {
            XCTAssertEqual(defaults.object(forKey: key) as? NSObject, value as? NSObject)
        }
    }

    func testExistingPackOrUnrecognisedUserFilesAreNeverReplaced() throws {
        for occupied: String in ["deepseek/pet.json", "my-pet/custom.txt", "notes.txt"] {
            let (root, defaults, suite) = try sandbox()
            defer { cleanup(root, defaults, suite) }
            let pets = root.appendingPathComponent("pets"), file = pets.appendingPathComponent(occupied)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data("keep user file".utf8)
            try original.write(to: file)
            XCTAssertEqual(try BundledDefaultPet.installIfNeeded(resourceDirectory: BundledDefaultPet.resourceDirectory,
                petsDirectory: pets, selectedPetID: nil, defaults: defaults), .preserved)
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testInvalidOrMissingResourcesDoNotLeavePartialPetOrConsumeMarker() throws {
        let (root, defaults, suite) = try sandbox()
        defer { cleanup(root, defaults, suite) }
        let pets = root.appendingPathComponent("pets"), invalid = root.appendingPathComponent("invalid")
        XCTAssertThrowsError(try BundledDefaultPet.installIfNeeded(resourceDirectory: nil, petsDirectory: pets,
            selectedPetID: nil, defaults: defaults))
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: invalid.appendingPathComponent("pet.json"))
        XCTAssertThrowsError(try BundledDefaultPet.installIfNeeded(resourceDirectory: invalid, petsDirectory: pets,
            selectedPetID: nil, defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: BundledDefaultPet.installedKey))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pets.path), [])
        XCTAssertEqual(try BundledDefaultPet.installIfNeeded(resourceDirectory: BundledDefaultPet.resourceDirectory,
            petsDirectory: pets, selectedPetID: nil, defaults: defaults), .installed("deepseek"))
    }

    func testHiddenInterruptedStagingDoesNotBlockCleanInstall() throws {
        let (root, defaults, suite) = try sandbox()
        defer { cleanup(root, defaults, suite) }
        let pets = root.appendingPathComponent("pets")
        let oldStage = pets.appendingPathComponent(".bundled-default-interrupted")
        try FileManager.default.createDirectory(at: oldStage, withIntermediateDirectories: true)
        try Data("preserve existing interrupted data".utf8).write(to: oldStage.appendingPathComponent("marker"))
        XCTAssertEqual(try BundledDefaultPet.installIfNeeded(resourceDirectory: BundledDefaultPet.resourceDirectory,
            petsDirectory: pets, selectedPetID: nil, defaults: defaults), .installed("deepseek"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldStage.appendingPathComponent("marker").path))
    }

    func testRelocatedAppUsesItsOwnResourceBundleAndNeverFallsBackToBuildCache() throws {
        let (root, defaults, suite) = try sandbox()
        defer { cleanup(root, defaults, suite) }
        let app = root.appendingPathComponent("Portable.app")
        let resources = app.appendingPathComponent("Contents/Resources/AgentPet_agentpet.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.portable.pet", "CFBundlePackageType": "APPL", "CFBundleName": "Portable"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let source = try XCTUnwrap(BundledDefaultPet.resourceDirectory)
        try FileManager.default.copyItem(at: source.deletingLastPathComponent(),
                                         to: resources.appendingPathComponent("DefaultPets"))
        let sourceBundle = try XCTUnwrap(AppResources.bundle())
        try FileManager.default.copyItem(at: try XCTUnwrap(sourceBundle.resourceURL).appendingPathComponent("Icons"),
                                        to: resources.appendingPathComponent("Icons"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        let located = try XCTUnwrap(BundledDefaultPet.resourceDirectory(in: bundle))
        XCTAssertTrue(located.path.hasPrefix(resources.path + "/"))
        XCTAssertEqual(AppResources.bundle(in: bundle)?.bundleURL.standardizedFileURL.path,
                       resources.standardizedFileURL.path)
        XCTAssertNotNil(AOProjectIcon.loadImage(in: bundle), "AO artwork must resolve from the relocated app too")
        XCTAssertEqual(try BundledDefaultPet.installIfNeeded(resourceDirectory: located,
            petsDirectory: root.appendingPathComponent("pets"), selectedPetID: nil, defaults: defaults), .installed("deepseek"))
        try FileManager.default.removeItem(at: resources)
        XCTAssertNil(AppResources.bundle(in: bundle))
        XCTAssertNil(AOProjectIcon.loadImage(in: bundle))
        XCTAssertNil(BundledDefaultPet.resourceDirectory(in: bundle), "A broken app must not silently use the developer's build cache")
    }

    func testLegacyManifestStillUsesTransparentGutterGrid() throws {
        let (root, defaults, suite) = try sandbox()
        defer { cleanup(root, defaults, suite) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8,
            bytesPerRow: 48, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 1, y: 1, width: 3, height: 6))
        context.fill(CGRect(x: 7, y: 1, width: 3, height: 6))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("sheet.png"))
        let manifest = ["id": "legacy", "displayName": "Legacy", "spritesheetPath": "sheet.png"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("pet.json"))
        let pack = try XCTUnwrap(SpriteSlicer.loadPack(directory: root))
        XCTAssertEqual(pack.clips.count, 1)
        XCTAssertEqual(pack.clips[0].count, 2)
    }
}

extension BundledDefaultPetTests {
    private func sha(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func mediaSandbox() throws -> (root: URL, resource: URL, pets: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        let resource = root.appendingPathComponent("resource/deepseek")
        let pets = root.appendingPathComponent("pets")
        try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pets.appendingPathComponent("deepseek/videos"),
                                                withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["id": "deepseek"])
            .write(to: resource.appendingPathComponent("pet.json"))
        try JSONSerialization.data(withJSONObject: ["id": "deepseek"])
            .write(to: pets.appendingPathComponent("deepseek/pet.json"))
        return (root, resource, pets)
    }

    func testMediaRefreshUpdatesKnownOldFilesAddsPeekAndPreservesUserFiles() throws {
        let (root, resource, pets) = try mediaSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldMovie = Data("old movie".utf8), newMovie = Data("new movie".utf8)
        let oldPoster = Data("old poster".utf8), newPoster = Data("new poster".utf8)
        let peek = Data("new peek".utf8)
        try FileManager.default.createDirectory(at: resource.appendingPathComponent("videos"),
                                                withIntermediateDirectories: true)
        try newMovie.write(to: resource.appendingPathComponent("videos/drag.mov"))
        try newPoster.write(to: resource.appendingPathComponent("drag.png"))
        try peek.write(to: resource.appendingPathComponent("edge-peek.png"))
        let pack = pets.appendingPathComponent("deepseek")
        try oldMovie.write(to: pack.appendingPathComponent("videos/drag.mov"))
        // The poster was already updated by a previous launch.
        try newPoster.write(to: pack.appendingPathComponent("drag.png"))
        let files: [BundledDefaultPet.MediaFile] = [
            .init(path: "videos/drag.mov", oldSHA256: sha(oldMovie), newSHA256: sha(newMovie)),
            .init(path: "drag.png", oldSHA256: sha(oldPoster), newSHA256: sha(newPoster)),
            .init(path: "edge-peek.png", oldSHA256: nil, newSHA256: sha(peek)),
        ]
        let report = BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: resource, petsDirectory: pets,
            files: files)
        XCTAssertEqual(Set(report.updated), ["videos/drag.mov", "edge-peek.png"])
        XCTAssertEqual(report.unchanged, ["drag.png"])
        XCTAssertTrue(report.blocked.isEmpty)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: pack.appendingPathComponent("videos/drag.mov")), newMovie)
        XCTAssertEqual(try Data(contentsOf: pack.appendingPathComponent("edge-peek.png")), peek)

        let again = BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: resource, petsDirectory: pets, files: files)
        XCTAssertTrue(again.updated.isEmpty)
        XCTAssertEqual(again.unchanged.count, 3)
    }

    func testMediaRefreshNeverOverwritesUserModifiedOrSymlinkedFiles() throws {
        let (root, resource, pets) = try mediaSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldMovie = Data("old".utf8), newMovie = Data("new".utf8)
        let userMovie = Data("user edited".utf8)
        try FileManager.default.createDirectory(at: resource.appendingPathComponent("videos"),
                                                withIntermediateDirectories: true)
        try newMovie.write(to: resource.appendingPathComponent("videos/drag.mov"))
        let outside = root.appendingPathComponent("outside.mov")
        try userMovie.write(to: outside)
        let pack = pets.appendingPathComponent("deepseek")
        try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("videos/drag.mov"),
                                                   withDestinationURL: outside)
        let files: [BundledDefaultPet.MediaFile] = [
            .init(path: "videos/drag.mov", oldSHA256: sha(oldMovie), newSHA256: sha(newMovie)),
        ]
        let report = BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: resource, petsDirectory: pets, files: files)
        XCTAssertTrue(report.failed.contains("videos/drag.mov"))
        XCTAssertEqual(try Data(contentsOf: outside), userMovie)

        try FileManager.default.removeItem(at: pack.appendingPathComponent("videos/drag.mov"))
        try userMovie.write(to: pack.appendingPathComponent("videos/drag.mov"))
        let blocked = BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: resource, petsDirectory: pets, files: files)
        XCTAssertTrue(blocked.blocked.contains("videos/drag.mov"))
        XCTAssertEqual(try Data(contentsOf: pack.appendingPathComponent("videos/drag.mov")), userMovie)
    }


    func testMediaRefreshRejectsSymlinkedDestinationDirectory() throws {
        let (root, resource, pets) = try mediaSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let newMovie = Data("new".utf8)
        try FileManager.default.createDirectory(at: resource.appendingPathComponent("videos"),
                                                withIntermediateDirectories: true)
        try newMovie.write(to: resource.appendingPathComponent("videos/drag.mov"))
        let pack = pets.appendingPathComponent("deepseek")
        let outside = root.appendingPathComponent("outside-videos")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: pack.appendingPathComponent("videos"))
        try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("videos"),
                                                   withDestinationURL: outside)
        let files: [BundledDefaultPet.MediaFile] = [
            .init(path: "videos/drag.mov", oldSHA256: nil, newSHA256: sha(newMovie)),
        ]
        let report = BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: resource, petsDirectory: pets, files: files)
        XCTAssertTrue(report.failed.contains("videos/drag.mov"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("drag.mov").path))
    }

    func testMediaRefreshRetriesPartialFailureWithoutTouchingMetadata() throws {
        let (root, resource, pets) = try mediaSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = Data("new movie".utf8)
        let pack = pets.appendingPathComponent("deepseek")
        let metadata = Data("{\"version\":1,\"clips\":[]}".utf8)
        try metadata.write(to: pack.appendingPathComponent("animations.json"))
        let files: [BundledDefaultPet.MediaFile] = [
            .init(path: "videos/drag.mov", oldSHA256: nil, newSHA256: sha(movie)),
        ]
        let failed = BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: resource, petsDirectory: pets, files: files)
        XCTAssertTrue(failed.failed.contains("videos/drag.mov"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pack.appendingPathComponent("videos/drag.mov").path))

        try FileManager.default.createDirectory(at: resource.appendingPathComponent("videos"),
                                                withIntermediateDirectories: true)
        try movie.write(to: resource.appendingPathComponent("videos/drag.mov"))
        let retried = BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: resource, petsDirectory: pets, files: files)
        XCTAssertEqual(retried.updated, ["videos/drag.mov"])
        XCTAssertEqual(try Data(contentsOf: pack.appendingPathComponent("animations.json")), metadata)
        XCTAssertEqual(try Data(contentsOf: pack.appendingPathComponent("videos/drag.mov")), movie)
    }

    func testMediaRefreshSkipsNonDefaultOrMissingPack() throws {
        let (root, resource, pets) = try mediaSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = pets.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["id": "other"])
            .write(to: other.appendingPathComponent("pet.json"))
        let files: [BundledDefaultPet.MediaFile] = []
        XCTAssertFalse(BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: resource, petsDirectory: pets, files: files).skipped)
        try FileManager.default.removeItem(at: pets.appendingPathComponent("deepseek"))
        XCTAssertTrue(BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: resource, petsDirectory: pets, files: files).skipped)
    }

    func testMediaRefreshRejectsSourceHashMismatchAndMissingResource() throws {
        let (root, resource, pets) = try mediaSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let declared = Data("declared".utf8)
        try FileManager.default.createDirectory(at: resource.appendingPathComponent("videos"),
                                                withIntermediateDirectories: true)
        try Data("actual".utf8).write(to: resource.appendingPathComponent("videos/drag.mov"))
        let files: [BundledDefaultPet.MediaFile] = [
            .init(path: "videos/drag.mov", oldSHA256: nil, newSHA256: sha(declared)),
        ]
        let bad = BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: resource, petsDirectory: pets, files: files)
        XCTAssertTrue(bad.failed.contains("videos/drag.mov"))
        XCTAssertTrue(BundledDefaultPet.refreshMediaIfNeeded(
            resourceDirectory: nil, petsDirectory: pets, files: files).skipped)
    }
}
