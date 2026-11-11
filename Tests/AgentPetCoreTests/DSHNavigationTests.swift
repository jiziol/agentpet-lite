import XCTest
import Foundation
import Darwin
@testable import AgentPetCore

final class DSHNavigationTests: XCTestCase {
    private func observation(path: String) -> DSHObservation {
        DSHObservation(schema: 1, profileID: String(repeating: "a", count: 24),
            hostID: UUID().uuidString, hostStartedAt: Date(), nativeSessionID: "session-fixture",
            revision: 1, nativeSeq: 1, turn: 1, phase: .done, result: .completed, pending: [],
            startedAt: Date(), endedAt: Date().addingTimeInterval(1), baseline: false,
            heartbeat: false, gap: false, navigationSocket: path)
    }

    private func exchange(mode: String = "ok", verifyOnly: Bool = false,
                          timeout: TimeInterval = 1) throws -> DSHNavigation.Receipt? {
        let root = "/tmp/agentpet-dsh-\(getuid())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = root + "/h-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/nav.sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        defer { close(listener) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        for (index, byte) in path.utf8.enumerated() {
            withUnsafeMutablePointer(to: &address.sun_path) { $0.withMemoryRebound(to: UInt8.self, capacity: 104) { $0[index] = byte } }
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        XCTAssertEqual(bound, 0); XCTAssertEqual(listen(listener, 1), 0)
        XCTAssertEqual(chmod(path, 0o600), 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            defer { close(fd) }
            if mode == "probe" {
                var byte: UInt8 = 0
                XCTAssertEqual(read(fd, &byte, 1), 0, "Probe must send no navigation/verification frame")
                return
            }
            var data = Data(); var bytes = [UInt8](repeating: 0, count: 1024)
            while !data.contains(10) && data.count < 8192 {
                let count = read(fd, &bytes, bytes.count)
                guard count > 0 else { return }
                data.append(contentsOf: bytes.prefix(count))
            }
            guard var reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            if mode == "silent" { usleep(300_000); return }
            reply["clientID"] = "fixture-client"; reply["generation"] = UUID().uuidString
            reply["ok"] = mode != "negative"
            if mode == "host" { reply["hostID"] = UUID().uuidString }
            if mode == "request" { reply["requestID"] = "different-request" }
            if mode == "session" { reply["nativeSessionID"] = "different-session" }
            if mode == "profile" { reply["profileID"] = String(repeating: "b", count: 24) }
            if mode == "generation" { reply["generation"] = "invalid" }
            if mode == "verify" { reply["ok"] = reply["verifyOnly"] as? Bool == true }
            let output: Data
            if mode == "oversize" { output = Data(repeating: 65, count: 9000) }
            else if mode == "malformed" { output = Data("not-json\n".utf8) }
            else { output = (try? JSONSerialization.data(withJSONObject: reply))! + Data([10]) }
            output.withUnsafeBytes { buffer in
                _ = Darwin.send(fd, buffer.baseAddress, buffer.count, MSG_NOSIGNAL)
            }
        }
        let began = ProcessInfo.processInfo.systemUptime
        let receipt: DSHNavigation.Receipt?
        if mode == "probe" {
            XCTAssertEqual(DSHNavigation.probePeer(observation(path: path)), getpid())
            receipt = nil
        } else {
            receipt = DSHNavigation.select(observation(path: path), timeout: timeout, verifyOnly: verifyOnly)
        }
        if mode == "silent" { XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.23) }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        return receipt
    }

    func testReadinessProbeSendsNoFrame() throws { _ = try exchange(mode: "probe") }

    func testExactReplyAndKernelPeerPID() throws {
        let reply = try exchange()
        XCTAssertEqual(reply?.peerPID, getpid()); XCTAssertEqual(reply?.clientID, "fixture-client")
    }
    func testWrongHostFails() throws { XCTAssertNil(try exchange(mode: "host")) }
    func testWrongProfileFails() throws { XCTAssertNil(try exchange(mode: "profile")) }
    func testWrongSessionFails() throws { XCTAssertNil(try exchange(mode: "session")) }
    func testWrongRequestFails() throws { XCTAssertNil(try exchange(mode: "request")) }
    func testMalformedGenerationFails() throws { XCTAssertNil(try exchange(mode: "generation")) }
    func testNegativeAndInvalidFramesFail() throws {
        for mode in ["negative", "malformed", "oversize"] { XCTAssertNil(try exchange(mode: mode)) }
    }
    func testTimeoutIsBounded() throws { XCTAssertNil(try exchange(mode: "silent", timeout: 0.08)) }
    func testVerificationRequestIsExplicit() throws { XCTAssertNotNil(try exchange(mode: "verify", verifyOnly: true)) }
    func testUnsafeAndMissingEndpointFail() {
        XCTAssertFalse(DSHNavigation.safeEndpoint("/tmp/other/nav.sock"))
        XCTAssertNil(DSHNavigation.select(observation(path: "/tmp/agentpet-dsh-\(getuid())/h-missing/nav.sock")))
    }
    func testProcessAncestryContainsCurrentProcess() { XCTAssertEqual(DSHNavigation.processAncestors(of: getpid()).first, getpid()) }

    func testEndpointRejectsWritableDirectoryAndSymlink() throws {
        let root = "/tmp/agentpet-dsh-\(getuid())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = root + "/h-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/nav.sock"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/tmp/nonexistent")
        XCTAssertFalse(DSHNavigation.safeEndpoint(path))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory)
        XCTAssertFalse(DSHNavigation.safeEndpoint(path))
    }
}
