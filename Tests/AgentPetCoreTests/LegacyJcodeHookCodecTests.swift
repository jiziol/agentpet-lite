import XCTest
@testable import AgentPetCore

final class LegacyJcodeHookCodecTests: XCTestCase {
    func testHeadersCommentsAndForeignFieldsSurviveRemoval() {
        for header in ["[hooks] # observers", "[ hooks ]", "\t[hooks]\t", "[hooks]\r"] {
            let before = "# user\n\(header)\nturn_end = 'agentpet hook --agent jcode'\npre_tool = 'audit'\n[trust]\napproved = true\n"
            let expected = before.replacingOccurrences(of: "turn_end = 'agentpet hook --agent jcode'\n", with: "")
            XCTAssertEqual(LegacyJcodeHookCodec.uninstall(in: before, events: ["turn_end"]), expected)
            XCTAssertEqual(LegacyJcodeHookCodec.uninstall(in: expected, events: ["turn_end"]), expected)
        }
    }
    func testAmbiguousArraysDottedKeysAndShellSnippetsRemainUntouched() {
        for before in ["[hooks]\nturn_end = ['agentpet hook', 'audit']\n", "hooks.turn_end = 'agentpet hook'\n",
                       "[hooks]\nturn_end = 'agentpet hook; audit'\n", "[hooks]\n# turn_end = 'agentpet hook'\nturn_end_extra = 'agentpet hook'\n"] {
            XCTAssertEqual(LegacyJcodeHookCodec.uninstall(in: before, events: ["turn_end"]), before)
        }
    }
    func testEscapedBasicStringsAreRecognizedConservatively() {
        let command = "\"/a b's/agentpet\" hook"
        let line = "turn_end = " + LegacyJcodeHookCodec.tomlString(command)
        XCTAssertTrue(HookCommandOwnership.ownsTOMLAssignment(line))
        XCTAssertEqual(LegacyJcodeHookCodec.uninstall(in: "[hooks]\n" + line + "\n", events: ["turn_end"]), "[hooks]\n")
    }
}
