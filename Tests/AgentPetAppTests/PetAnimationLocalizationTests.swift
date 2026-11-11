import XCTest
import AppKit
@testable import agentpet

final class PetAnimationLocalizationTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func bundle(_ language: String) throws -> Bundle {
        try XCTUnwrap(Bundle(path: root.appendingPathComponent("Localizations/\(language).lproj").path))
    }

    func testAllGroupsAndShippedNamesResolveInEveryLanguageWithoutChangingIdentity() throws {
        let url = root.appendingPathComponent("Sources/App/Resources/DefaultPets/deepseek/animations.json")
        let rows = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["clips"] as? [[String: Any]])
        var pack = ImagePetPack(id: "deepseek", displayName: "deepseek", description: nil, clips: [], directory: root)
        pack.videoClips = rows.map { row in
            PetVideoClip(id: row["id"] as! String, name: row["name"] as! String, category: "", url: url,
                poster: nil, duration: 1, width: 1, height: 1, displayName: row["displayName"] as? String)
        }
        let ids = pack.animationIDs
        for language in ["en", "vi", "zh-Hans", "zh-Hant"] {
            let b = try bundle(language)
            for key in PetAnimationBindings.selectionKeys {
                XCTAssertNotEqual(PetAnimationText.group(key, bundle: b), key)
            }
            for index in 0..<33 {
                let label = PetAnimationText.name(pack: pack, index: index, bundle: b)
                XCTAssertFalse(label.hasPrefix("pet.animation."))
                XCTAssertFalse(label.isEmpty)
                if ["en", "vi"].contains(language) {
                    XCTAssertNil(label.range(of: "\\p{Han}", options: .regularExpression), label)
                }
            }
            XCTAssertEqual(pack.animationIDs, ids)
        }
    }

    func testCustomImportedAndOtherPackNamesRemainVerbatim() throws {
        let b = try bundle("en")
        var pack = ImagePetPack(id: "deepseek", displayName: "", description: nil, clips: [], directory: root)
        let native = PetVideoClip(id: "dsh:写代码", name: "写代码", category: "", url: root,
            poster: nil, duration: 1, width: 1, height: 1)
        pack.videoClips = [native]
        XCTAssertEqual(PetAnimationText.name(pack: pack, index: 0, bundle: b), "Coding")
        pack.videoClips[0].displayName = "用户自定义名称"
        XCTAssertEqual(PetAnimationText.name(pack: pack, index: 0, bundle: b), "用户自定义名称")
        pack.videoClips[0].displayName = nil; pack.videoClips[0].source = .imported
        XCTAssertEqual(PetAnimationText.name(pack: pack, index: 0, bundle: b), "写代码")
        pack.videoClips[0] = native
        let other = ImagePetPack(id: "other", displayName: "", description: nil, clips: [], directory: root, videoClips: [native])
        XCTAssertEqual(PetAnimationText.name(pack: other, index: 0, bundle: b), "写代码")
    }

    func testIntegrationTutorialKeysAndNativeDialogFormatsAreTranslated() throws {
        let keys = ["Integration details", "Got it", "Codex Hooks 官方文档", "OpenCode 版本迁移说明",
                    "integration.install", "integration.codex", "integration.reload", "integration.agy", "integration.opencode",
                    "integration.opencode.install", "integration.opencode.reload", "integration.pi", "integration.compatibility", "dsh.guide.intro", "dsh.guide.install", "dsh.guide.test",
                    "dsh.target.confirmBody", "dsh.package.revealed", "dsh.package.notFound"]
        for language in ["en", "vi", "zh-Hant"] {
            let b = try bundle(language)
            for key in keys {
                let value = b.localizedString(forKey: key, value: "MISSING", table: nil)
                XCTAssertNotEqual(value, "MISSING", "\(language): \(key)")
                if language != "zh-Hant" { XCTAssertNil(value.range(of: "\\p{Han}", options: .regularExpression), value) }
            }
            let format = b.localizedString(forKey: "dsh.target.confirmBody", value: nil, table: nil)
            let body = String(format: format, "/fixture/DSH.app", "/fixture/profile")
            XCTAssertTrue(body.contains("/fixture/DSH.app")); XCTAssertTrue(body.contains("/fixture/profile"))
        }
    }
}
