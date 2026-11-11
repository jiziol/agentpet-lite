import XCTest
@testable import AgentPetCore

final class CodexHookOriginTests: XCTestCase {
    private let process = CodexHookOrigin.Identity(pid: 321, startTicks: 123456789)
    private func registry(tag: String = "aionui-session-title", pid: Int32 = 321,
                          ticks: UInt64? = 123456789, epoch: String = "11111111-1111-4111-8111-111111111111",
                          version: Int = 1) throws -> Data {
        var entry: [String: Any] = ["pid": pid, "opaque_owner_tag": tag, "instance_epoch": epoch]
        if let ticks { entry["start_time_ticks"] = ticks }
        return try JSONSerialization.data(withJSONObject: ["version": version, "processes": [entry]])
    }

    func testExactTitleAncestorIsRecognizedWithoutAnyCodexDatabase() throws {
        XCTAssertEqual(CodexHookOrigin.titleAncestor(in: try registry(), ancestors: [process]), process)
        XCTAssertNil(CodexHookOrigin.titleAncestor(in: try registry(), ancestors: []))
    }

    func testReusedPIDUnrelatedProcessNormalTeamAndUnknownRegistryStayTracked() throws {
        let records = [try registry(ticks: 123456788), try registry(ticks: nil), try registry(pid: 322),
                       try registry(epoch: "bad-epoch"), try registry(version: 2),
                       try registry(tag: "aionui-session-title-extra"), try registry(tag: "team-leader"),
                       try registry(tag: "gpt-6-luna"), try registry(tag: "gpt-6.1-sol"),
                       try registry(tag: "deepseek-v4.1-flash"), Data("not JSON".utf8)]
        for data in records { XCTAssertNil(CodexHookOrigin.titleAncestor(in: data, ancestors: [process])) }
    }

    func testBoundedRegistryAndRealKernelAncestors() throws {
        XCTAssertNil(CodexHookOrigin.titleAncestor(in: Data(repeating: 32, count: 262_145), ancestors: [process]))
        let live = try XCTUnwrap(CodexHookOrigin.ancestors().first)
        XCTAssertEqual(CodexHookOrigin.identity(live.pid), live)
        XCTAssertEqual(CodexHookOrigin.titleAncestor(in: try registry(pid: live.pid, ticks: live.startTicks), ancestors: [live]), live)
        XCTAssertNil(CodexHookOrigin.identity(0))
        XCTAssertNil(CodexHookOrigin.identity(-1))
    }
}
