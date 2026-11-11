import Foundation
import XCTest
@testable import AgentPetCore

final class OpencodeTUINavigationTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let process = Process()
        let instance = String(repeating: "a", count: 32)
        let nonce = String(repeating: "b", count: 48)
        let sid = "ses_navigationTest"
        var record: URL!
        init(owners: [Bool], response: String = "ok") throws {
            root = URL(fileURLWithPath: "/tmp/ocn-" + String(UUID().uuidString.prefix(8)))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let directory = root.appendingPathComponent("opencode-tui")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let script = root.appendingPathComponent("server.py")
            try #"""
            import json,os,socket,sys,threading,time
            from pathlib import Path
            root=Path(sys.argv[1]);owners=json.loads(sys.argv[2]);response=sys.argv[3]
            nonce='b'*48;listeners=[]
            def serve(sock,owns):
                while True:
                    c,_=sock.accept()
                    with c:
                        data=b''
                        while b'\n' not in data:
                            chunk=c.recv(4096)
                            if not chunk:break
                            data+=chunk
                        if not data:continue
                        req=json.loads(data.split(b'\n')[0])
                        with (root/'calls.jsonl').open('a') as f:f.write(json.dumps(req)+'\n')
                        reply={**req,'pid':os.getpid(),'ok':owns,'owns':owns}
                        if req['action']=='select':
                            reply['route']={'type':'session','sessionID':req['sessionID'] if response!='wrong-route' else 'ses_wrong'}
                            if response=='failed':reply['ok']=False
                            if response=='wrong-nonce':reply['nonce']='c'*48
                        c.sendall(json.dumps(reply).encode()+b'\n')
            for i,owns in enumerate(owners):
                instance=('%032x'%(i+1));path=root/('oc2-%s-%s.sock'%(os.getpid(),instance[:16]))
                # A distinct high half keeps the socket basename unique.
                instance=('%016x'%(i+1))+'0'*16;path=root/('oc2-%s-%s.sock'%(os.getpid(),instance[:16]))
                sock=socket.socket(socket.AF_UNIX);sock.bind(str(path));os.chmod(path,0o600);sock.listen();listeners.append(sock)
                row={'schema':1,'version':'2.2.2','pid':os.getpid(),'instance':instance,'nonce':nonce,'socket':str(path),'project':str(root.resolve()),'program':'iTerm.app','tty':'/dev/ttys999','updatedAt':time.time()}
                record=root/'opencode-tui'/('instance-%s-%s.json'%(os.getpid(),instance[:16]));record.write_text(json.dumps(row));os.chmod(record,0o600)
                threading.Thread(target=serve,args=(sock,owns),daemon=True).start()
            (root/'ready').write_text('ready')
            while True:time.sleep(1)
            """#.write(to: script, atomically: true, encoding: .utf8)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, root.path, String(data: try JSONEncoder().encode(owners), encoding: .utf8)!, response]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let until = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path), process.isRunning, Date() < until { usleep(10_000) }
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) else { close(); throw NSError(domain: "fixture", code: 1) }
            record = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        }
        func close() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        var session: AgentSession { .init(id: sid, agentKind: .opencode, project: root.path, state: .working, source: .hook, updatedAt: Date()) }
        var calls: [[String: Any]] {
            (try? String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8))?.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? []
        }
    }

    func testOnlyTheUniqueOwningTUIIsSelectedAndReturnsItsTerminal() throws {
        let f = try Fixture(owners: [false, true]); defer { f.close() }
        XCTAssertEqual(OpencodeTUINavigation.endpoints(base: f.root.path).count, 2, "Both private endpoints must validate before probing")
        let actual = try XCTUnwrap(realpath(f.root.path, nil)); defer { free(actual) }
        XCTAssertEqual(OpencodeTUINavigation.endpoints(base: f.root.path).first?.project, String(cString: actual))
        let outcome = OpencodeTUINavigation.navigate(f.session, base: f.root.path)
        guard case .selected(let terminal) = outcome else { return XCTFail("Unique TUI must be selected: \(outcome), calls: \(f.calls)") }
        XCTAssertEqual(terminal, .init(program: "iTerm.app", tty: "/dev/ttys999"))
        XCTAssertEqual(f.calls.filter { $0["action"] as? String == "probe" }.count, 2)
        XCTAssertEqual(f.calls.filter { $0["action"] as? String == "select" }.count, 1)
    }
    func testAmbiguousOrUnownedSessionNeverSelectsAnInstance() throws {
        for owners in [[true, true], [false, false]] {
            let f = try Fixture(owners: owners); defer { f.close() }
            let result = OpencodeTUINavigation.navigate(f.session, base: f.root.path)
            if owners[0] { guard case .ambiguous = result else { return XCTFail("Must refuse ambiguous owners") } }
            else { guard case .unavailable = result else { return XCTFail("Project alone cannot supply ownership") } }
            XCTAssertFalse(f.calls.contains { $0["action"] as? String == "select" })
        }
    }
    func testWrongRouteNonceAndRejectedTargetCannotProduceSuccess() throws {
        for response in ["failed", "wrong-route", "wrong-nonce"] {
            let f = try Fixture(owners: [true], response: response); defer { f.close() }
            guard case .failed = OpencodeTUINavigation.navigate(f.session, base: f.root.path) else { return XCTFail("Invalid receipt must fail: " + response) }
        }
    }
    func testStalePublicOrWrongVersionRegistryCannotAdvertiseNavigation() throws {
        for mutation in ["stale", "version", "public", "project"] {
            let f = try Fixture(owners: [true]); defer { f.close() }
            var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.record)) as? [String: Any])
            if mutation == "stale" { row["updatedAt"] = Date().addingTimeInterval(-60).timeIntervalSince1970 }
            if mutation == "version" { row["version"] = "2.1.9" }
            if mutation == "project" { row["project"] = "/unrelated" }
            try JSONSerialization.data(withJSONObject: row).write(to: f.record)
            if mutation == "public" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.record.path) }
            guard case .unsupported = OpencodeTUINavigation.navigate(f.session, base: f.root.path) else { return XCTFail("Unsafe registry must not be used: " + mutation) }
            XCTAssertTrue(f.calls.isEmpty)
        }
    }
    func testExportsExactOwnedTUIPartForNodeContractChecks() throws {
        let source = OpencodeTUIPlugin.source(speechSocketPath: NSHomeDirectory() + "/.agentpet-local/speech.sock")
        XCTAssertTrue(OpencodeTUIPlugin.isOwned(source))
        XCTAssertFalse(OpencodeTUIPlugin.isOwned(source + "\n// user customization"))
        if let directory = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"] {
            try source.write(toFile: directory + "/opencode-tui.mjs", atomically: true, encoding: .utf8)
        }
    }
    func testClosedProcessAndLinkedRegistryAreIgnored() throws {
        let f = try Fixture(owners: [true]); defer { f.close() }
        XCTAssertTrue(OpencodeTUINavigation.endpoints(base: f.root.path, live: { _ in false }).isEmpty)
        let original = f.root.appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: f.record, to: original)
        try FileManager.default.createSymbolicLink(at: f.record, withDestinationURL: original)
        XCTAssertTrue(OpencodeTUINavigation.endpoints(base: f.root.path).isEmpty)
        try FileManager.default.removeItem(at: f.record)
        try FileManager.default.linkItem(at: original, to: f.record)
        XCTAssertTrue(OpencodeTUINavigation.endpoints(base: f.root.path).isEmpty)
        XCTAssertTrue(f.calls.isEmpty)
    }
    func testMigratedV1SocketCannotBlockAnExactV2OwnerAndLiveV1StaysFirst() throws {
        let f = try Fixture(owners: [true]); defer { f.close() }
        var session = f.session
        session.opencodeNavigationSocket = "/removed-v1.sock"
        session.terminalProgram = "old-server-terminal"
        guard case .selected(let v2) = OpencodeTUINavigation.select(session, base: f.root.path, legacySelection: { _ in false }) else { return XCTFail("Exact V2 ownership must recover a migrated session") }
        XCTAssertEqual(v2.tty, "/dev/ttys999")
        let calls = f.calls.count
        guard case .selected(let v1) = OpencodeTUINavigation.select(session, base: f.root.path, legacySelection: { _ in true }) else { return XCTFail("Live V1 must retain its original route") }
        XCTAssertEqual(v1.program, "old-server-terminal")
        XCTAssertEqual(f.calls.count, calls, "A successful V1 route must not probe any V2 instance")
    }
}
