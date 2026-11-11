import XCTest
import AppKit
import AVFoundation
import SwiftUI
import AgentPetCore
@testable import agentpet

@MainActor
final class PetAnimationImportTests: XCTestCase {
    override func setUpWithError() throws { try TestIsolation.require() }
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func nativeMovie() throws -> URL {
        try XCTUnwrap(BundledDefaultPet.resourceDirectory).appendingPathComponent("videos/东张西望.mov")
    }
    private func pack(_ root: URL, id: String = "test", count: Int = 2) -> ImagePetPack {
        ImagePetPack(id: id, displayName: id, description: nil,
            clips: Array(repeating: [NSImage(size: .init(width: 2, height: 2))], count: count), directory: root)
    }
    private func preferences() throws -> UserDefaults {
        let suite = "r3-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private func seeds(_ p: ImagePetPack) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: PetAnimationBindings.selectionKeys.map { ($0, p.candidateIDs(for: $0)) })
    }

    func testBatchPartialFailureSameNameOwnedCopyPosterAndRestart() throws {
        let root = try sandbox(), sources = try sandbox()
        let good = sources.appendingPathComponent("same.mov")
        try FileManager.default.copyItem(at: nativeMovie(), to: good)
        let broken = sources.appendingPathComponent("broken.mov")
        try Data([1, 2, 3]).write(to: broken)
        let wrong = sources.appendingPathComponent("wrong.mp4")
        try FileManager.default.copyItem(at: good, to: wrong)
        var p = pack(root)
        let prefs = try preferences(), store = PetAnimationBindingsStore(defaults: prefs)
        store.set(.init(clipIDs: ["sheet:1"]), key: "working", pack: p)
        let result = PetAnimationLibrary.importFiles([good, broken, wrong, good], directory: root,
            key: "working", seedGroups: seeds(p), nativeCount: 0)
        XCTAssertEqual(result.importedIDs.count, 2)
        XCTAssertEqual(Set(result.importedIDs).count, 2)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertTrue(result.failures.contains { $0.contains("broken.mov") })
        XCTAssertTrue(result.failures.contains { $0.contains("wrong.mp4") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path))
        try FileManager.default.removeItem(at: good)
        p.loadAnimations()
        XCTAssertEqual(p.videoClips.count, 2)
        XCTAssertTrue(p.animationIssues.isEmpty, p.animationIssues.joined(separator: "\n"))
        XCTAssertTrue(p.videoClips.allSatisfy { $0.poster?.isValid == true && $0.source == .imported })
        XCTAssertTrue(p.candidateIDs(for: "working").contains("sheet:1"))
        XCTAssertFalse(p.candidateIDs(for: "idle").contains(result.importedIDs[0]))
        XCTAssertEqual(store.bindings(for: p).byKey["working"]?.clipIDs, ["sheet:1"])
        let selection = ["sheet:1", result.importedIDs[1]]
        store.set(.init(mode: .rotate, clipIDs: selection), key: "working", pack: p)
        var restarted = pack(root); restarted.loadAnimations()
        XCTAssertEqual(restarted.animationIDs, p.animationIDs)
        XCTAssertEqual(PetAnimationBindingsStore(defaults: prefs).bindings(for: restarted).byKey["working"]?.clipIDs, selection)
        XCTAssertEqual(PetAnimationBindingsStore(defaults: prefs).bindings(for: pack(try sandbox(), id: "other")).byKey["working"]?.clipIDs, ["sheet:0"])
    }

    func testBadRowsDoNotDiscardGoodRowsAndGlobalFailureKeepsNative() throws {
        let root = try sandbox()
        try FileManager.default.copyItem(at: nativeMovie(), to: root.appendingPathComponent("good.mov"))
        let info = try PetAnimationMedia.inspect(root.appendingPathComponent("good.mov"))
        try info.posterPNG.write(to: root.appendingPathComponent("poster.png"))
        try Data([0]).write(to: root.appendingPathComponent("bad.png"))
        let good: [String: Any] = ["id": "good", "name": "good", "category": "native", "file": "good.mov",
            "poster": "poster.png", "duration": 5, "width": 640, "height": 360, "purposes": ["working"]]
        var path = good; path["id"] = "path"; path["file"] = "../escape.mov"
        var poster = good; poster["id"] = "poster"; poster["poster"] = "bad.png"
        var field = good; field["id"] = "field"; field["width"] = "wrong type"
        var media = good; media["id"] = "media"; media["file"] = "bad.mov"
        try Data([0]).write(to: root.appendingPathComponent("bad.mov"))
        let rows: [Any] = [NSNull(), path, poster, field, media, good, good]
        try JSONSerialization.data(withJSONObject: ["version": 1, "clips": rows]).write(to: root.appendingPathComponent("animations.json"))
        let loaded = PetAnimationCatalog.loadResult(directory: root)
        XCTAssertEqual(loaded.clips.map(\.id), ["good"])
        XCTAssertEqual(loaded.issues.count, 6)
        try Data("{bad json".utf8).write(to: root.appendingPathComponent("animations.json"))
        var p = pack(root, count: 1); p.loadAnimations()
        XCTAssertEqual(p.videoClips.count, 0)
        XCTAssertFalse(p.animationIssues.isEmpty)
        let bindings = PetAnimationBindingsStore(defaults: try preferences()).bindings(for: p)
        for key in PetAnimationBindings.selectionKeys { XCTAssertEqual(bindings.byKey[key]?.clipIDs, ["sheet:0"]) }
    }

    func testStaleSelectionNeverReenablesAllCandidatesAndNoMappedRowSemantics() throws {
        let root = try sandbox(), prefs = try preferences()
        var p = pack(root)
        p.videoClips = [PetVideoClip(id: "native", name: "n", category: "n", url: root, poster: nil,
            duration: 1, width: 1, height: 1, purposes: ["working"])]
        let saved = PetAnimationBindings(byKey: ["working": .init(clipIDs: ["missing"]), "idle": .init(clipIDs: ["sheet:1"])])
        let raw = try JSONEncoder().encode(saved)
        prefs.set(raw, forKey: "agentpet.animationBindings.v2.test")
        let prepared = PetAnimationBindingsStore(defaults: prefs).bindings(for: p)
        XCTAssertEqual(prepared.byKey["working"]?.clipIDs, ["native"], "A stale choice falls back inside its valid native purpose map")
        XCTAssertEqual(prepared.byKey["idle"]?.clipIDs, ["sheet:1"])
        XCTAssertEqual(prefs.data(forKey: "agentpet.animationBindings.v2.test"), raw)
        let fresh = PetAnimationBindingsStore(defaults: try preferences()).bindings(for: pack(root, count: 2))
        for key in PetAnimationBindings.selectionKeys { XCTAssertEqual(fresh.byKey[key]?.clipIDs, ["sheet:0"]) }
    }

    func testLibraryBadEntryIsIsolatedAndImportDoesNotOverwriteDamagedDocument() throws {
        let root = try sandbox(), p = pack(root)
        let imported = PetAnimationLibrary.importFiles([try nativeMovie()], directory: root, key: "tap", seedGroups: seeds(p), nativeCount: 0)
        let file = root.appendingPathComponent(PetAnimationLibrary.filename)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var assets = raw["assets"] as! [Any]; assets.append(["id": 9]); raw["assets"] = assets
        let damaged = try JSONSerialization.data(withJSONObject: raw)
        try damaged.write(to: file)
        let loaded = PetAnimationLibrary.load(directory: root, nativeIDs: [])
        XCTAssertEqual(loaded.clips.map(\.id), imported.importedIDs)
        XCTAssertEqual(loaded.issues.count, 1)
        let attempt = PetAnimationLibrary.importFiles([try nativeMovie()], directory: root, key: "idle", seedGroups: seeds(p), nativeCount: 0)
        XCTAssertTrue(attempt.importedIDs.isEmpty)
        XCTAssertFalse(attempt.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testResourceAndPathLimits() throws {
        let root = try sandbox(), p = pack(root)
        let result = PetAnimationLibrary.importFiles([try nativeMovie()], directory: root, key: "drag", seedGroups: seeds(p), nativeCount: 512)
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertTrue(result.failures.first?.contains("512") == true)
        let oversized = root.appendingPathComponent("oversized.mov")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(PetAnimationLimits.movieBytes + 1)); try handle.close()
        XCTAssertThrowsError(try PetAnimationMedia.inspect(oversized))
        try Data(repeating: 32, count: PetAnimationLimits.manifestBytes + 1).write(to: root.appendingPathComponent("animations.json"))
        XCTAssertTrue(PetAnimationCatalog.loadResult(directory: root).clips.isEmpty)
        XCTAssertNil(PetAnimationCatalog.localFile("../anything", directory: root))
        XCTAssertNil(PetAnimationCatalog.localFile("/tmp/anything", directory: root))
    }

    func testStoreImportRefreshAndUnusableNativePackError() async throws {
        let root = try sandbox(), native = root.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let info = try PetAnimationMedia.inspect(nativeMovie())
        try info.posterPNG.write(to: native.appendingPathComponent("sheet.png"))
        let manifest: [String: Any] = ["id": "native", "displayName": "Native", "spritesheetPath": "sheet.png", "spritesheetLayout": "single"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: native.appendingPathComponent("pet.json"))
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: broken.appendingPathComponent("pet.json"))
        let bindings = PetAnimationBindingsStore(defaults: try preferences())
        let library = ImagePetStore(petsDirectory: root, bindingsStore: bindings)
        library.reload()
        XCTAssertEqual(library.packs.count, 1)
        XCTAssertEqual(library.loadingIssues.count, 1)
        XCTAssertTrue(library.loadingIssues[0].contains("原生回退"))
        let result = await library.importAnimations([try nativeMovie()], for: "native", key: "drag")
        XCTAssertEqual(result.importedIDs.count, 1, result.failures.joined(separator: "\n"))
        let importedID = try XCTUnwrap(result.importedIDs.first)
        let updated = try XCTUnwrap(library.pack(id: "native"))
        XCTAssertEqual(updated.videoClips.count, 1)
        XCTAssertTrue(updated.candidateIDs(for: "drag").contains(importedID))
        XCTAssertFalse(updated.candidateIDs(for: "tap").contains(importedID))
        XCTAssertEqual(bindings.bindings(for: updated).byKey["drag"]?.clipIDs, ["sheet:0"])
        XCTAssertFalse(library.importingPetIDs.contains("native"))
        // One asset can be referenced by another group without copying media.
        let file = native.appendingPathComponent(PetAnimationLibrary.filename)
        var doc = try JSONDecoder().decode(PetAnimationLibrary.Document.self, from: Data(contentsOf: file))
        doc.groups["tap", default: []].append(importedID)
        try JSONEncoder().encode(doc).write(to: file, options: .atomic)
        await library.reloadAnimations(for: "native")
        let shared = try XCTUnwrap(library.pack(id: "native"))
        XCTAssertTrue(shared.candidateIDs(for: "tap").contains(importedID))
        XCTAssertEqual(shared.videoClips.count, 1)
        XCTAssertEqual(shared.video(for: importedID)?.url, updated.video(for: importedID)?.url)
    }

    func testNativeSettingsRenderingWithMixedMediaInBothAppearances() throws {
        guard let path = ProcessInfo.processInfo.environment["R3_RENDER_DIR"] else { throw XCTSkip("Set R3_RENDER_DIR for native snapshot evidence") }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        let root = try sandbox(), prefs = try preferences()
        var p = pack(root)
        let info = try PetAnimationMedia.inspect(nativeMovie())
        let image = try XCTUnwrap(NSImage(data: info.posterPNG))
        p = ImagePetPack(id: p.id, displayName: p.displayName, description: nil, clips: [[image], [image]], directory: root)
        let result = PetAnimationLibrary.importFiles([try nativeMovie()], directory: root, key: "working", seedGroups: seeds(p), nativeCount: 0)
        XCTAssertEqual(result.importedIDs.count, 1)
        p.loadAnimations()
        let bindings = PetAnimationBindingsStore(defaults: prefs)
        bindings.set(.init(mode: .rotate, clipIDs: ["sheet:1", result.importedIDs[0]]), key: "working", pack: p)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let hosting = NSHostingView(rootView: PetAnimationSettingsView(pack: p,
                library: ImagePetStore(petsDirectory: root, bindingsStore: bindings), store: bindings)
                .frame(width: 680, alignment: .topLeading).padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, name == "light" ? .light : .dark))
            hosting.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            window.displayIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent("animation-\(name).png"))
            window.orderOut(nil)
        }
    }

    func testRejectsActualOpaqueCodecEvenWithMovExtension() async throws {
        let root = try sandbox(), url = root.appendingPathComponent("opaque.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 255, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        while !input.isReadyForMoreMediaData { await Task.yield() }
        XCTAssertTrue(adaptor.append(frame, withPresentationTime: .zero))
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        XCTAssertThrowsError(try PetAnimationMedia.inspect(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Alpha"), error.localizedDescription)
        }
    }
}
