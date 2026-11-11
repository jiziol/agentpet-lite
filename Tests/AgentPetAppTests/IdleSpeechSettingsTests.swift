import XCTest
@testable import agentpet

@MainActor
final class IdleSpeechSettingsTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let name = "idle-speech-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
    }
    func testConfirmedPoolsAreDistinctAndFitThirtyCharacters() {
        let lines = WhaleSpeechStyle.allCases.flatMap(\.lines)
        XCTAssertEqual(lines.count, 45)
        XCTAssertEqual(Set(lines).count, 45)
        for style in WhaleSpeechStyle.allCases {
            XCTAssertEqual(style.lines.count, 15)
            for line in style.lines { XCTAssertLessThanOrEqual(line.count, 30, line) }
        }
        XCTAssertEqual(WhaleSpeechStyle.lazyHealing.lines[11], "偷偷在后台给你贴了个“今日免加班”符咒，嘘，别让老板发现啦。")
        XCTAssertEqual(WhaleSpeechStyle.geekPartner.lines[11], "盯——这变量命名很有想法嘛，我在思维链里沉默三秒才忍住没笑。")
    }
    func testOnlyEffectiveLegacyIdleCustomIsMigratedOnce() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "agentpet.bubble.multiAgentBubbleEnabled")
            defaults.set("custom", forKey: "agentpet.bubbleMsgSource")
            let old = ["all": ["idle": [" 第一条 ", "", "第二条"], "working": ["不能当闲聊"]],
                       "codex": ["idle": ["不能混入"]]]
            defaults.set(try JSONEncoder().encode(old), forKey: "agentpet.bubbleMsgCustom")
            defaults.set("custom", forKey: "agentpet.chatSource")
            defaults.set(try JSONEncoder().encode(["idle": ["未启用的旧内容"]]), forKey: "agentpet.chatCustom")
            let settings = IdleSpeechSettings(defaults: defaults)
            XCTAssertEqual(settings.source, .custom)
            XCTAssertEqual(settings.lines, ["第一条", "第二条"])
            XCTAssertEqual(try JSONDecoder().decode([String: [String: [String]]].self, from: defaults.data(forKey: "agentpet.bubbleMsgCustom")!), old)
            defaults.set(false, forKey: "agentpet.bubble.multiAgentBubbleEnabled")
            XCTAssertEqual(IdleSpeechSettings(defaults: defaults).lines, ["第一条", "第二条"])
        }
    }
    func testSingleModeMigratesOnlyIdleAndEmptyCustomFallsBack() throws {
        try withDefaults { defaults in
            defaults.set(false, forKey: "agentpet.bubble.multiAgentBubbleEnabled")
            defaults.set("custom", forKey: "agentpet.chatSource")
            defaults.set(try JSONEncoder().encode(["idle": ["只有闲聊"], "done": ["不迁移结果"]]), forKey: "agentpet.chatCustom")
            XCTAssertEqual(IdleSpeechSettings(defaults: defaults).lines, ["只有闲聊"])
        }
        try withDefaults { defaults in
            defaults.set("custom", forKey: "agentpet.bubbleMsgSource")
            defaults.set(try JSONEncoder().encode(["all": ["idle": [" ", "\n"]]]), forKey: "agentpet.bubbleMsgCustom")
            let settings = IdleSpeechSettings(defaults: defaults)
            XCTAssertEqual(settings.source, .builtin)
            XCTAssertEqual(settings.style, .lazyHealing)
        }
    }
    func testEmptyApplyDoesNotLoseValidContentAndCustomIsLiteral() {
        withDefaults { defaults in
            let settings = IdleSpeechSettings(defaults: defaults)
            XCTAssertTrue(settings.applyCustom("  保留这句！\n\n第二句～  "))
            XCTAssertFalse(settings.applyCustom(" \n \t"))
            settings.style = .geekPartner
            XCTAssertEqual(settings.lines, ["保留这句！", "第二句～"])
            XCTAssertEqual(IdleSpeechSettings(defaults: defaults).lines, settings.lines)
        }
    }
    func testPicksDoNotImmediatelyRepeatEvenAcrossStyleSwitches() {
        withDefaults { defaults in
            let settings = IdleSpeechSettings(defaults: defaults)
            var previous = settings.pick()
            for _ in 0..<100 {
                let next = settings.pick()
                XCTAssertNotEqual(previous, next); previous = next
            }
            settings.style = .tsundere
            XCTAssertNotEqual(settings.pick(), previous)
            XCTAssertTrue(settings.applyCustom("一句"))
            XCTAssertEqual(settings.pick(), "一句")
            XCTAssertEqual(settings.pick(), "一句")
        }
    }
}
