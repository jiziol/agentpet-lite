import XCTest
@testable import agentpet

@MainActor
final class BubbleSettingsTests: XCTestCase {
    private let retentionKey = "agentpet.bubble.readResultRetention"
    private let quotaKey = "agentpet.bubble.codexLowQuotaReminderEnabled"
    private let petBubbleKey = "agentpet.bubble.petBubbleEnabled"
    private let multiAgentBubbleKey = "agentpet.bubble.multiAgentBubbleEnabled"
    private let sessionGroupingKey = "agentpet.bubble.sessionGrouping"
    private let collapseDuplicatesKey = "agentpet.bubble.collapseDuplicates"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "agentpet.bubble.superchatEnabled")
        UserDefaults.standard.removeObject(forKey: retentionKey)
        UserDefaults.standard.removeObject(forKey: quotaKey)
        UserDefaults.standard.removeObject(forKey: petBubbleKey)
        UserDefaults.standard.removeObject(forKey: multiAgentBubbleKey)
        UserDefaults.standard.removeObject(forKey: sessionGroupingKey)
        UserDefaults.standard.removeObject(forKey: collapseDuplicatesKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: multiAgentBubbleKey)
        UserDefaults.standard.removeObject(forKey: sessionGroupingKey)
        UserDefaults.standard.removeObject(forKey: collapseDuplicatesKey)
        UserDefaults.standard.removeObject(forKey: "agentpet.bubble.superchatEnabled")
        UserDefaults.standard.removeObject(forKey: retentionKey)
        UserDefaults.standard.removeObject(forKey: quotaKey)
        UserDefaults.standard.removeObject(forKey: petBubbleKey)
        super.tearDown()
    }

    func testReadRetentionDefaultsToThreeSecondsAndRejectsUnknownValue() {
        XCTAssertEqual(BubbleSettings().readResultRetention, .threeSeconds)
        UserDefaults.standard.set("invalid", forKey: retentionKey)
        XCTAssertEqual(BubbleSettings().readResultRetention, .threeSeconds)
    }
    func testQuotaReminderMigratesLegacyChoiceAndNewChoiceWins() {
        let suite = "quota-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = "agentpet.bubble.reactiveBubblesEnabled"
        XCTAssertTrue(BubbleSettings.loadCodexLowQuotaReminderEnabled(defaults: defaults))
        defaults.set(false, forKey: legacy)
        XCTAssertFalse(BubbleSettings.loadCodexLowQuotaReminderEnabled(defaults: defaults))
        defaults.set(true, forKey: petBubbleKey)
        XCTAssertTrue(BubbleSettings.loadCodexLowQuotaReminderEnabled(defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: quotaKey))
        defaults.set(false, forKey: petBubbleKey)
        XCTAssertFalse(BubbleSettings.loadCodexLowQuotaReminderEnabled(defaults: defaults))
        defaults.removeObject(forKey: petBubbleKey)
        defaults.set(true, forKey: quotaKey)
        XCTAssertTrue(BubbleSettings.loadCodexLowQuotaReminderEnabled(defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: legacy))
        defaults.set(false, forKey: quotaKey)
        defaults.set(true, forKey: legacy)
        XCTAssertFalse(BubbleSettings.loadCodexLowQuotaReminderEnabled(defaults: defaults))
    }

    func testQuotaReminderChoicePersistsIndependentlyOfLegacyChoice() {
        let legacy = "agentpet.bubble.reactiveBubblesEnabled"
        let before = UserDefaults.standard.object(forKey: legacy) as? Bool
        let settings = BubbleSettings()
        settings.codexLowQuotaReminderEnabled = false
        XCTAssertFalse(BubbleSettings().codexLowQuotaReminderEnabled)
        settings.codexLowQuotaReminderEnabled = true
        XCTAssertTrue(BubbleSettings().codexLowQuotaReminderEnabled)
        XCTAssertEqual(UserDefaults.standard.object(forKey: legacy) as? Bool, before)
    }

    func testLegacyPetBubbleChoiceDoesNotChangeIndependentSuperchat() {
        UserDefaults.standard.set(false, forKey: quotaKey)
        let settings = BubbleSettings()
        XCTAssertFalse(settings.petBubbleEnabled)
        settings.petBubbleEnabled = true
        XCTAssertTrue(BubbleSettings().petBubbleEnabled)
        XCTAssertFalse(settings.codexLowQuotaReminderEnabled)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: quotaKey))
    }

    func testEveryReadRetentionChoicePersists() {
        let settings = BubbleSettings()
        for value in ReadResultRetention.allCases {
            settings.readResultRetention = value
            XCTAssertEqual(BubbleSettings().readResultRetention, value)
        }
    }

    func testOpacityPreservesExistingChoiceAndPersistsLowerValues() {
        let key = "agentpet.bubble.opacity"
        let before = UserDefaults.standard.object(forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(0.75, forKey: key)
        let settings = BubbleSettings()
        XCTAssertEqual(settings.opacity, 0.75)
        settings.opacity = 0.35
        XCTAssertEqual(BubbleSettings().opacity, 0.35)
        XCTAssertEqual(settings.readResultRetention, BubbleSettings().readResultRetention)
    }

    func testBackgroundOpacitySupportsClearFillAndRejectsNonfiniteValue() {
        let key = "agentpet.bubble.opacity"
        let before = UserDefaults.standard.object(forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(-1.0, forKey: key)
        let settings = BubbleSettings()
        XCTAssertEqual(settings.opacity, 0)
        settings.opacity = .nan
        XCTAssertEqual(settings.opacity, 1)
        XCTAssertEqual(BubbleSettings().opacity, 1)
        settings.opacity = 2
        XCTAssertEqual(BubbleSettings().opacity, 1)
        settings.opacity = 0
        XCTAssertEqual(BubbleSettings().opacity, 0)
    }

    func testMultiAgentBubbleDefaultsOn() {
        let settings = BubbleSettings()

        XCTAssertTrue(settings.multiAgentBubbleEnabled)
    }

    func testMultiAgentBubblePersists() {
        let settings = BubbleSettings()

        settings.multiAgentBubbleEnabled = true

        XCTAssertTrue(BubbleSettings().multiAgentBubbleEnabled)
    }

    func testSessionGroupingDefaultsToByKind() {
        XCTAssertEqual(BubbleSettings().sessionGrouping, .byKind)
    }

    func testSessionGroupingPersists() {
        let settings = BubbleSettings()
        settings.sessionGrouping = .allSessions
        XCTAssertEqual(BubbleSettings().sessionGrouping, .allSessions)
    }

    func testSessionGroupingMigratesFromLegacyCollapseOff() {
        UserDefaults.standard.set(false, forKey: collapseDuplicatesKey)
        XCTAssertEqual(BubbleSettings().sessionGrouping, .allSessions)
    }

    func testModelTokenExistsAndHasMetadata() {
        XCTAssertTrue(BubbleToken.allCases.contains(.model))
        XCTAssertEqual(BubbleToken.model.shortName, "Model")
        XCTAssertEqual(BubbleToken.model.chipSymbol, "cpu")
    }

    func testModelTokenVisibilityInPresets() {
        func isVisible(_ layout: BubbleLayout) -> Bool? {
            layout.tokens.first { $0.token == .model }?.isVisible
        }
        XCTAssertEqual(isVisible(.original), false)
        XCTAssertEqual(isVisible(.standard), false)
        XCTAssertEqual(isVisible(.detailed), true)
    }
}
