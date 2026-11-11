import XCTest
import Darwin
@testable import AgentPetCore

final class LocalAgentConnectionTests: XCTestCase {
    private func fixture(_ body: String) throws -> (URL, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ap-connection-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("client")
        try Data(("#!/usr/bin/env python3\n" + body).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable.path)
    }

    func testCorrelatedHandshakeAndEphemeralPiState() throws {
        for kind: AgentKind in [.codex, .pi, .opencode] {
            let (root, executable) = try fixture("""
            import sys,json,os,pathlib
            if '--version' in sys.argv:
                print('opencode v2.1.3');sys.exit(0)
            assert os.environ['CFFIXED_USER_HOME'] != '\(NSHomeDirectory())'
            pathlib.Path(__file__).with_suffix('.root').write_text(os.getcwd())
            assert 'OPENAI_API_KEY' not in os.environ
            assert pathlib.Path(os.environ['CODEX_HOME']).resolve().is_relative_to(pathlib.Path.cwd())
            if 'api' in sys.argv:
                assert '--standalone' in sys.argv and sys.argv[-1] == '/api/info'
                print(json.dumps({'version':'2.1.3','pid':os.getpid()}));sys.exit(0)
            req=json.loads(sys.stdin.readline())
            assert not any(x in json.dumps(req) for x in ['turn/start','session/new','prompt'])
            print(json.dumps({'id':'wrong','result':{'userAgent':'wrong'}}),flush=True)
            if req.get('type')=='get_state':
                assert '--no-session' in sys.argv and '--no-extensions' in sys.argv
                out={'id':req['id'],'type':'response','command':'get_state','success':True,'data':{'isStreaming':False,'messageCount':0}}
            elif 'app-server' in sys.argv:
                out={'id':req['id'],'result':{'userAgent':'codex/fixture'}}
            else:
                out={'id':req['id'],'result':{'protocolVersion':1,'agentInfo':{'name':'dsh'}}}
            print(json.dumps(out),flush=True)
            if 'app-server' in sys.argv: assert json.loads(sys.stdin.readline())['method']=='initialized'
            sys.stdin.read()
            """)
            defer { try? FileManager.default.removeItem(at: root) }
            let service = LocalAgentConnectionTest(environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "OPENAI_API_KEY": "must-not-inherit"], executableOverrides: [kind: executable])
            let result = service.run(kind, requestID: "test-id", cancellation: .init())
            XCTAssertEqual(result.status, .connected, "\(kind): \(result)")
            XCTAssertTrue(result.evidence.contains("test-id"))
            let temporaryRoot = try String(contentsOf: root.appendingPathComponent("client.root"), encoding: .utf8)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot))
        }
    }

    func testOpenCodeV1UsesACPWithoutCreatingASession() throws {
        let (root, executable) = try fixture("""
        import sys,json
        if '--version' in sys.argv: print('1.19.0');sys.exit(0)
        assert sys.argv[1:] == ['acp']
        r=json.loads(sys.stdin.readline())
        assert r['method']=='initialize'
        print(json.dumps({'id':r['id'],'result':{'protocolVersion':1,'agentInfo':{'name':'opencode'}}}),flush=True)
        sys.stdin.read()
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = LocalAgentConnectionTest(executableOverrides: [.opencode: executable]).run(.opencode, requestID: "v1", cancellation: .init())
        XCTAssertEqual(result.status, .connected)
        XCTAssertTrue(result.evidence.contains("ACP initialize"))
    }

    func testWrongIDVersionOnlyAndMalformedOutputNeverPass() throws {
        for output in ["{'id':'other','result':{'userAgent':'codex'}}", "{'version':'0.163.0'}", "{'id':'test','result':{}}"] {
            let (root, executable) = try fixture("import json\nprint(json.dumps(\(output)),flush=True)\n")
            defer { try? FileManager.default.removeItem(at: root) }
            let result = LocalAgentConnectionTest(executableOverrides: [.codex: executable], timeout: 1)
                .run(.codex, requestID: "test", cancellation: .init())
            XCTAssertEqual(result.status, .failed)
        }
    }

    func testAuthenticationProtocolErrorAndUnavailableAreExplicit() throws {
        for (body, key) in [
            ("import json,sys\nr=json.loads(sys.stdin.readline())\nprint(json.dumps({'id':r['id'],'error':{'code':401,'message':'auth_required'}}),flush=True)\n", "connection.authentication"),
            ("import json,sys\nr=json.loads(sys.stdin.readline())\nprint(json.dumps({'id':r['id'],'error':{'code':-32601,'message':'method missing'}}),flush=True)\n", "connection.rejected"),
            ("import sys\nsys.stderr.write('unauthorized')\nsys.exit(1)\n", "connection.authentication"),
            ("import sys\nsys.exit(2)\n", "connection.unreachable")
        ] {
            let (root, executable) = try fixture(body)
            defer { try? FileManager.default.removeItem(at: root) }
            let result = LocalAgentConnectionTest(executableOverrides: [.codex: executable]).run(.codex, requestID: "test", cancellation: .init())
            XCTAssertEqual(result.status, .failed)
            XCTAssertEqual(result.message, key)
        }
        XCTAssertEqual(LocalAgentConnectionTest(executableOverrides: [.pi: "/does/not/exist"]).run(.pi, requestID: "x", cancellation: .init()).message, "connection.startFailed")
    }

    func testTimeoutAndCancellationReapOwnedDescendants() throws {
        for cancel in [false, true] {
            let (root, executable) = try fixture("""
            import subprocess,time,pathlib,sys
            child=subprocess.Popen(['/bin/sleep','60'])
            pathlib.Path(__file__).with_suffix('.pid').write_text(str(child.pid))
            time.sleep(60)
            """)
            defer { try? FileManager.default.removeItem(at: root) }
            let cancellation = LocalAgentTestCancellation()
            if cancel { DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancellation.cancel() } }
            let began = Date()
            let result = LocalAgentConnectionTest(executableOverrides: [.codex: executable], timeout: cancel ? 5 : 0.4)
                .run(.codex, requestID: "test", cancellation: cancellation)
            XCTAssertEqual(result.status, cancel ? .cancelled : .timedOut)
            XCTAssertLessThan(Date().timeIntervalSince(began), 2)
            let child = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("client.pid"), encoding: .utf8)))
            let deadline = Date().addingTimeInterval(1)
            while kill(child, 0) == 0 && Date() < deadline { usleep(10_000) }
            XCTAssertEqual(kill(child, 0), -1, "The temporary child must not survive cancellation/timeout")
        }
    }

    func testUnsupportedClientsDoNotStartAnyProcess() {
        for kind: AgentKind in [.antigravity, .claude, .dsh] {
            let result = LocalAgentConnectionTest(executableOverrides: [kind: "/does/not/exist"]).run(kind, requestID: "test", cancellation: .init())
            XCTAssertEqual(result.status, .unsupported)
        }
    }

    func testOutputFloodIsBoundedAndUnsupportedVersionDoesNotHandshake() throws {
        let (root, executable) = try fixture("import sys\nsys.stdout.write('x'*300000)\nsys.stdout.flush()\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(LocalAgentConnectionTest(executableOverrides: [.codex: executable]).run(.codex, requestID: "x", cancellation: .init()).message, "connection.outputLimit")
        let (versionRoot, versionCLI) = try fixture("print('opencode v3.0.0')\n")
        defer { try? FileManager.default.removeItem(at: versionRoot) }
        XCTAssertEqual(LocalAgentConnectionTest(executableOverrides: [.opencode: versionCLI]).run(.opencode, requestID: "x", cancellation: .init()).message, "connection.versionUnsupported")
    }

    /// Opt-in real interfaces: no prompt, real profile, hook or persistent session.
    func testInstalledNativeInterfacesWithoutInference() throws {
        guard ProcessInfo.processInfo.environment["AGENTPET_NATIVE_CONNECTION_TEST"] == "1" else {
            throw XCTSkip("Opt in to installed CLI interface checks")
        }
        for kind: AgentKind in [.codex, .opencode, .pi] {
            let result = LocalAgentConnectionTest(timeout: 20).run(kind, requestID: UUID().uuidString, cancellation: .init())
            print("NATIVE \(kind.rawValue): \(result.status) \(result.message) \(result.evidence)")
            XCTAssertEqual(result.status, .connected, "\(kind): \(result)")
        }
    }
}
