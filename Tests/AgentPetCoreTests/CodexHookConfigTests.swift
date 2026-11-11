import XCTest
@testable import AgentPetCore

final class CodexHookConfigTests: XCTestCase {
    func testDefaultAndEnabledDoNotBlock() {
        XCTAssertFalse(CodexHookConfig.isExplicitlyDisabled(in: ""))
        XCTAssertFalse(CodexHookConfig.isExplicitlyDisabled(in: "[features]\nhooks = true\n"))
        XCTAssertFalse(CodexHookConfig.isExplicitlyDisabled(in: "[features]\ncodex_hooks = true\n"))
    }
    func testDisabledModernAndAlias() {
        XCTAssertTrue(CodexHookConfig.isExplicitlyDisabled(in: "[features]\nhooks = false # choice\n"))
        XCTAssertTrue(CodexHookConfig.isExplicitlyDisabled(in: "[features]\ncodex_hooks = false\n"))
    }
    func testModernTakesPrecedenceAndOtherTablesDoNotChangeHint() {
        XCTAssertFalse(CodexHookConfig.isExplicitlyDisabled(in: "[features]\nhooks = true\ncodex_hooks = false\n"))
        XCTAssertFalse(CodexHookConfig.isExplicitlyDisabled(in: "[plugins.other]\nhooks = false\n"))
        XCTAssertFalse(CodexHookConfig.isExplicitlyDisabled(in: "[features]\n# hooks = false\n[profiles.other.features]\nhooks = false\n"))
        XCTAssertTrue(CodexHookConfig.isExplicitlyDisabled(in: "[features] # features\nhooks = false\n[plugins.other]\nhooks = true\n"))
    }
}
