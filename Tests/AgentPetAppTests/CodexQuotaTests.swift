import Foundation
import XCTest
@testable import agentpet

final class CodexQuotaTests: XCTestCase {
    func testRemainingColorBandsMatchReferenceBoundaries() {
        for (remaining, expected) in [(0.0, UsageQuotaBand.critical), (0.099, .critical),
                                      (0.1, .low), (0.31, .low), (0.399, .low),
                                      (0.4, .medium), (0.799, .medium), (0.8, .high), (1.0, .high)] {
            XCTAssertEqual(UsageQuotaBand.classify(remaining), expected)
        }
        for remaining in [nil, -.infinity, .nan, -0.01, 1.01] as [Double?] {
            XCTAssertEqual(UsageQuotaBand.classify(remaining), .unavailable)
        }
    }

    func testStatusBarsPreserveUnknownValuesAndKnownEmptyOrFullBudget() {
        for value in [nil, .nan, -.infinity, -0.01, 1.01] as [Double?] {
            XCTAssertNil(StatusQuotaPresentation.valid(value))
        }
        XCTAssertEqual(StatusQuotaPresentation.valid(0), 0, "Exhausted is known, not missing")
        XCTAssertEqual(StatusQuotaPresentation.valid(1), 1)
        XCTAssertEqual(StatusQuotaPresentation.valid(0.8), 0.8)
    }

    private func decode(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testOfficialKeepsBothWindowsAndSelectsCodexBucket() throws {
        let data = try decode(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"planType":"plus","primary":{"usedPercent":2,"windowDurationMins":300,"resetsAt":2000},"secondary":{"usedPercent":69,"windowDurationMins":10080,"resetsAt":3000}},"codex_other":{"primary":{"usedPercent":100}}}}"#)
        let provider = try XCTUnwrap(CodexQuota.provider(result: data))
        XCTAssertEqual(provider.windows.count, 2)
        XCTAssertEqual(provider.windows[0].fractionLeft, 0.98)
        XCTAssertEqual(provider.windows[1].fractionLeft, 0.31)
        XCTAssertEqual(provider.windows[0].durationMinutes, 300)
        XCTAssertEqual(provider.windows[1].durationMinutes, 10080)
        XCTAssertEqual(provider.windows[1].resetsAt, Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(provider.plan, "plus")
    }

    func testMissingOrInvalidUsageNeverBecomesFullRemaining() throws {
        for value in ["null", "true", "-1", "101", "\"2\""] {
            let result = try decode("{\"rateLimits\":{\"primary\":{\"usedPercent\":\(value)},\"secondary\":null}}")
            let p = try XCTUnwrap(CodexQuota.provider(result: result))
            XCTAssertNil(p.windows[0].fractionLeft)
            XCTAssertNil(p.windows[1].fractionLeft)
        }
        for (used, expected) in [(0, 1.0), (1, 0.99), (100, 0.0)] {
            let p = try XCTUnwrap(CodexQuota.provider(result: ["rateLimits": ["primary": ["usedPercent": used]]]))
            XCTAssertEqual(p.windows[0].fractionLeft, expected)
        }
    }

    func testAbsentCodexBucketDoesNotUseOtherModelQuota() {
        XCTAssertNil(CodexQuota.provider(result: ["rateLimitsByLimitId": ["codex_other": ["primary": ["usedPercent": 99]]]]))
    }

    func testActualDurationIsPreservedWithoutAssumingFiveHours() throws {
        let p = try XCTUnwrap(CodexQuota.provider(result: ["rateLimits": ["primary": ["usedPercent": 42, "windowDurationMins": 15]]]))
        XCTAssertEqual(p.windows[0].durationMinutes, 15)
        XCTAssertNil(p.windows[1].durationMinutes)
    }

    func testWhamParsesAbsoluteAndRelativeResetIndependently() throws {
        let body = try decode(#"{"rate_limit":{"primary_window":{"used_percent":2,"limit_window_seconds":18000,"reset_at":5000,"reset_after_seconds":3},"secondary_window":{"used_percent":69,"limit_window_seconds":604800,"reset_after_seconds":4000}}}"#)
        let p = try XCTUnwrap(CodexQuota.provider(wham: body, now: Date(timeIntervalSince1970: 1000)))
        XCTAssertEqual(p.windows[0].fractionLeft, 0.98)
        XCTAssertEqual(p.windows[1].fractionLeft, 0.31)
        XCTAssertEqual(p.windows[0].durationMinutes, 300)
        XCTAssertEqual(p.windows[1].durationMinutes, 10080)
        XCTAssertEqual(p.windows[0].resetsAt, Date(timeIntervalSince1970: 5000))
        XCTAssertEqual(p.windows[1].resetsAt, Date(timeIntervalSince1970: 5000))
    }

    func testWhamHeaderFallbackDoesNotInventWindowDuration() throws {
        let p = try XCTUnwrap(CodexQuota.provider(wham: ["rate_limit": [:]], headers: ["x-codex-primary-used-percent": "7"]))
        XCTAssertEqual(p.windows[0].fractionLeft, 0.93)
        XCTAssertNil(p.windows[0].durationMinutes)
        XCTAssertNil(p.windows[1].fractionLeft)
    }

    func testOfficialRPCHandlesHandshakeAndFragmentedResponses() throws {
        let fixture = #"""
import json,sys,time
assert json.loads(sys.stdin.readline())['method']=='initialize'
sys.stdout.write('{"id":0,"res');sys.stdout.flush();time.sleep(.02)
print('ult":{}}',flush=True)
assert json.loads(sys.stdin.readline())['method']=='initialized'
assert json.loads(sys.stdin.readline())['method']=='account/rateLimits/read'
print('{"method":"account/updated","params":{}}',flush=True)
print('{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":300}}}}',flush=True)
sys.stdin.read()
"""#
        let response = try XCTUnwrap(CodexUsageRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", fixture], timeout: 3))
        let p = try XCTUnwrap(CodexQuota.provider(result: response))
        XCTAssertEqual(p.windows[0].fractionLeft, 0.93)
    }

    func testOfficialRPCTimesOutAndCleansUpUnresponsiveProcess() {
        let start = Date()
        let result = CodexUsageRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time;time.sleep(30)"], timeout: 0.2)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testOfficialRPCErrorAndOversizedLineFailClosed() {
        for fixture in ["print('{\"id\":0,\"error\":{\"code\":-1}}',flush=True)", "print('x'*300000,flush=True)"] {
            XCTAssertNil(CodexUsageRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", fixture], timeout: 2))
        }
    }
}
