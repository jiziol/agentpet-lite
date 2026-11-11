import XCTest
@testable import agentpet

@MainActor
final class AOExperimentSettingsTests: XCTestCase {
    func testNewPreferenceDefaultsOffAndDoesNotRewriteOtherFilters() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AOExperiment.preferenceKey)
        defer {
            if let previous { defaults.set(previous, forKey: AOExperiment.preferenceKey) }
            else { defaults.removeObject(forKey: AOExperiment.preferenceKey) }
        }
        defaults.removeObject(forKey: AOExperiment.preferenceKey)
        let settings = BubbleSettings()
        let kinds = settings.hiddenKinds, aion = settings.showAionUiTeams
        XCTAssertFalse(settings.aoExperimentEnabled)
        XCTAssertFalse(settings.aoExperimentActive)
        settings.aoExperimentEnabled = true
        XCTAssertTrue(BubbleSettings().aoExperimentEnabled)
        XCTAssertEqual(settings.hiddenKinds, kinds)
        XCTAssertEqual(settings.showAionUiTeams, aion)
        settings.aoExperimentEnabled = false
        XCTAssertFalse(BubbleSettings().aoExperimentEnabled)
    }

    func testBuildAvailabilityCannotBeBypassedBySavedPreference() {
        XCTAssertTrue(AOExperiment.isAvailable)
        XCTAssertFalse(AOExperiment.isActive(requested: false))
        XCTAssertTrue(AOExperiment.isActive(requested: true))
    }
}
