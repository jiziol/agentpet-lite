import Foundation
import Darwin
import XCTest

/// Fail-fast guard for test classes that can mutate `UserDefaults`/the app's
/// runtime state. `verify-local.sh` exports an isolated home; a plain
/// `swift test` must not touch the user's real preferences.
enum TestIsolation {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func validate(home: String, environment: [String: String], loginHome: String? = nil) throws {
        let expected = environment["CFFIXED_USER_HOME"] ?? ""
        guard expected.hasPrefix("/"), home.hasPrefix("/") else {
            throw Failure(description: "CFFIXED_USER_HOME is missing; refusing to run a stateful test")
        }
        let actualURL = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL
        let expectedURL = URL(fileURLWithPath: expected).resolvingSymlinksInPath().standardizedFileURL
        let accountHome = loginHome ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) }
        guard actualURL.path != "/", accountHome.map({
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path != actualURL.path
        }) == true else {
            throw Failure(description: "Refusing the login home (or an unknown account home) as a test home")
        }
        guard actualURL.path == expectedURL.path else {
            throw Failure(description: "NSHomeDirectory (\(actualURL.path)) != CFFIXED_USER_HOME (\(expectedURL.path))")
        }

        let local = environment["AGENTPET_LOCAL_HOME"] ?? ""
        guard local.hasPrefix("/") else {
            throw Failure(description: "AGENTPET_LOCAL_HOME is missing; refusing to run a stateful test")
        }
        let localURL = URL(fileURLWithPath: local).resolvingSymlinksInPath().standardizedFileURL
        let homePrefix = actualURL.path.hasSuffix("/") ? actualURL.path : actualURL.path + "/"
        guard localURL.path != actualURL.path, localURL.path.hasPrefix(homePrefix) else {
            throw Failure(description: "AGENTPET_LOCAL_HOME must be a child of the isolated home")
        }

        let tmp = environment["TMPDIR"] ?? ""
        guard !tmp.isEmpty, URL(fileURLWithPath: tmp).path.hasPrefix("/") else {
            throw Failure(description: "TMPDIR is missing or not absolute")
        }
        for key in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"] {
            guard let value = environment[key], value.hasPrefix("/") else {
                throw Failure(description: "\(key) is missing; use verify-local's isolated environment")
            }
            let url = URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL
            guard url.path == actualURL.path || url.path.hasPrefix(homePrefix) else {
                throw Failure(description: "\(key) must be inside the isolated home")
            }
        }
    }

    /// Call from `setUpWithError` before touching any shared settings/defaults.
    static func require() throws {
        let environment = ProcessInfo.processInfo.environment
        try validate(home: NSHomeDirectory(), environment: environment)
        print("TEST_ISOLATION_OK home=\(NSHomeDirectory()) CFFIXED_USER_HOME=\(environment["CFFIXED_USER_HOME"] ?? "") AGENTPET_LOCAL_HOME=\(environment["AGENTPET_LOCAL_HOME"] ?? "") TMPDIR=\(environment["TMPDIR"] ?? "")")
    }
}

final class TestIsolationTests: XCTestCase {
    func testNegativeValidationRejectsMissingOrMismatchedHome() {
        XCTAssertThrowsError(try TestIsolation.validate(home: "/Users/real", environment: [:]))
        XCTAssertThrowsError(try TestIsolation.validate(
            home: "/Users/real",
            environment: ["CFFIXED_USER_HOME": "/tmp/other", "AGENTPET_LOCAL_HOME": "/tmp/other/data",
                          "TMPDIR": "/tmp", "XDG_CONFIG_HOME": "/tmp/other/config",
                          "XDG_DATA_HOME": "/tmp/other/data", "XDG_CACHE_HOME": "/tmp/other/cache",
                          "XDG_STATE_HOME": "/tmp/other/state"]))
        XCTAssertThrowsError(try TestIsolation.validate(
            home: "/tmp/isolated",
            environment: ["CFFIXED_USER_HOME": "/tmp/isolated", "AGENTPET_LOCAL_HOME": "/tmp/isolated",
                          "TMPDIR": "/tmp", "XDG_CONFIG_HOME": "/tmp/isolated/config",
                          "XDG_DATA_HOME": "/tmp/isolated/data", "XDG_CACHE_HOME": "/tmp/isolated/cache",
                          "XDG_STATE_HOME": "/tmp/isolated/state"]))
    }

    func testRealLoginHomeAndRootCannotMasqueradeAsIsolation() {
        for home in ["/", "/Users/login"] {
            let env = ["CFFIXED_USER_HOME": home, "AGENTPET_LOCAL_HOME": home + "/data",
                       "TMPDIR": "/tmp", "XDG_CONFIG_HOME": home + "/config",
                       "XDG_DATA_HOME": home + "/data", "XDG_CACHE_HOME": home + "/cache",
                       "XDG_STATE_HOME": home + "/state"]
            XCTAssertThrowsError(try TestIsolation.validate(home: home, environment: env, loginHome: "/Users/login"))
        }
    }

    func testCurrentHomeWithoutIsolationWouldBeRejected() {
        XCTAssertThrowsError(try TestIsolation.validate(home: NSHomeDirectory(), environment: [:]))
    }

    func testValidIsolationShapePasses() throws {
        try TestIsolation.validate(
            home: "/tmp/isolated-home",
            environment: ["CFFIXED_USER_HOME": "/tmp/isolated-home",
                          "AGENTPET_LOCAL_HOME": "/tmp/isolated-home/.agentpet-local",
                          "TMPDIR": "/tmp/isolated-tmp",
                          "XDG_CONFIG_HOME": "/tmp/isolated-home/.config",
                          "XDG_DATA_HOME": "/tmp/isolated-home/.local/share",
                          "XDG_CACHE_HOME": "/tmp/isolated-home/.cache",
                          "XDG_STATE_HOME": "/tmp/isolated-home/.local/state"])
    }
}
