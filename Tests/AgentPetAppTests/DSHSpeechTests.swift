import XCTest
@testable import AgentPetCore
@testable import agentpet

final class DSHSpeechTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1000)
    private let host = "11111111-1111-4111-8111-111111111111"
    private func session() -> AgentSession {
        let obs = DSHObservation(schema: 1, profileID: String(repeating: "a", count: 24),
            hostID: host, hostStartedAt: at.addingTimeInterval(-10), nativeSessionID: "native-A",
            revision: 2, nativeSeq: 3, turn: 1, phase: .working, result: nil, pending: [],
            startedAt: at, endedAt: nil, baseline: false, heartbeat: false, gap: false, navigationSocket: nil)
        var s = AgentSession(id: obs.sessionKey, agentKind: .dsh, state: .working, source: .hook, updatedAt: at)
        s.createdAt = at; s.turnStartedAt = at; s.dsh = obs
        return s
    }
    private func frame(_ edits: [String: Any] = [:]) throws -> Data {
        var fields: [String: Any] = ["schema":"agentpet.dsh.speech.v1", "profile_id":String(repeating:"a",count:24),
            "host_id":host, "host_started_at":990.0, "session_id":"native-A", "turn":1,
            "native_seq":3, "observation_revision":2, "item_id":"3", "revision":1,
            "timestamp":1001.0, "role":"assistant", "part_type":"text", "mode":"snapshot",
            "text":"好的。正在检查窗口布局。"]
        fields.merge(edits) { _, new in new }
        return try JSONSerialization.data(withJSONObject: fields)
    }
    private func message(_ edits: [String: Any] = [:]) throws -> DSHVisibleMessage {
        try XCTUnwrap(DSHVisibleMessage.decode(frame(edits)))
    }
    func testPrivateInvalidAndFutureSchemasCannotReachTextOrLifecycle() throws {
        for edit: [String:Any] in [["schema":"agentpet.dsh.speech.v2"],["role":"user"],["part_type":"reasoning"],
             ["mode":"withdraw"],["profile_id":"wrong"],["host_id":"wrong"],["turn":-1],["text":String(repeating:"a",count:2049)]] {
            XCTAssertNil(DSHVisibleMessage.decode(try frame(edit)))
        }
        var events:[AgentEvent]=[]
        EventSocketServer.decodeLines(try frame()+Data([10]),onEvent:{events.append($0)})
        XCTAssertTrue(events.isEmpty,"Speech envelopes must never be restored as persisted events")
    }
    func testLifecycleMayArriveAfterTextButWrongHostProfileTurnAndCancellationReject() throws {
        let now=at.addingTimeInterval(1), m=try message(); var state=DSHSpeechState()
        state.reset(enabled:true,now:at);state.receive([m],now:now)
        XCTAssertTrue(state.drain(sessions:[],now:now).isEmpty); XCTAssertEqual(state.count,1)
        XCTAssertEqual(state.drain(sessions:[session()],now:now).count,1)
        for variant in 0..<5 {
            var s=session()
            switch variant {
            case 0:s.dsh?.hostID="22222222-2222-4222-8222-222222222222"
            case 1:s.dsh?.turn=2
            case 2:s.dshDisconnectedAt=now
            case 3:s.dsh?.result = .cancelled
            default:s.dsh?.result = .failed
            }
            state.reset(enabled:true,now:at);state.receive([m],now:now)
            XCTAssertTrue(state.drain(sessions:[s],now:now).isEmpty)
        }
        state.reset(enabled:true,now:at);state.receive([try message(["profile_id":String(repeating:"b",count:24)])],now:now)
        XCTAssertTrue(state.drain(sessions:[session()],now:now).isEmpty)
    }
    func testDisabledReenabledRestartStaleBoundsAndWithdrawalSupersedePending() throws {
        let now=at.addingTimeInterval(1);var state=DSHSpeechState()
        state.reset(enabled:false,now:at);state.receive([try message()],now:now);XCTAssertEqual(state.count,0)
        state.reset(enabled:true,now:at.addingTimeInterval(2));state.receive([try message()],now:at.addingTimeInterval(2));XCTAssertEqual(state.count,0)
        state.reset(enabled:true,now:at);state.receive([try message()],now:at.addingTimeInterval(6));XCTAssertEqual(state.count,0)
        state.receive([try message(["timestamp":1004.0])],now:now);XCTAssertEqual(state.count,0)
        state.receive([try message(),try message(["revision":2,"mode":"withdraw","text":""])],now:now)
        XCTAssertEqual(state.drain(sessions:[session()],now:now).first?.0.mode,.withdraw)
        let inbox=DSHSpeechInbox()
        XCTAssertTrue(inbox.offer(try message()))
        XCTAssertFalse(inbox.offer(try message(["revision":2,"mode":"withdraw","text":""])))
        XCTAssertEqual(inbox.take().first?.mode,.withdraw)
        for i in 0..<200 { _=inbox.offer(try message(["item_id":String(i)])) }
        XCTAssertEqual(inbox.take().count,128)
    }
    func testSharedDisplayFiveSecondsNoRenewalExactHostTurnAndWithdrawal() throws {
        let s=session(), m=try message(), now=at.addingTimeInterval(1)
        var shared=PetSpeechState()
        let candidate=PetSpeechState.Candidate(fence:.init(s,turnID:"1"),itemID:m.itemID,timestamp:m.timestamp,revision:m.revision,content:.snapshot(m.text))
        shared.receive(candidate,session:s,now:now)
        XCTAssertEqual(shared.rows.first?.label,"@DSH[1]")
        XCTAssertEqual(shared.rows.first?.text,"好的。正在检查窗口布局。")
        XCTAssertEqual(shared.rows.first?.expiresAt,at.addingTimeInterval(6))
        var switched=s;switched.dsh?.hostID="22222222-2222-4222-8222-222222222222"
        XCTAssertTrue(shared.visible(sessions:[switched],hiddenKinds:[],now:now).isEmpty)
        switched=s;switched.dsh?.turn=2
        XCTAssertTrue(shared.visible(sessions:[switched],hiddenKinds:[],now:now).isEmpty)
        shared.receive(.init(fence:.init(s,turnID:"1"),itemID:m.itemID,timestamp:at.addingTimeInterval(2),revision:2,content:.withdraw),session:s,now:at.addingTimeInterval(2))
        XCTAssertTrue(shared.rows.isEmpty)
        shared.receive(candidate,session:s,now:at.addingTimeInterval(2));XCTAssertTrue(shared.rows.isEmpty)
    }

    func testAOBackgroundLifecycleCannotLeakThroughDSHPublicSpeech() throws {
        let now = at.addingTimeInterval(1), m = try message()
        var helper = session()
        helper.project = NSHomeDirectory() + "/.ao/data/background-tasks/title-123"
        helper.dsh?.navigationSocket = "/tmp/agentpet-dsh-502/h-ACP123/nav.sock"
        var state = DSHSpeechState(); state.reset(enabled: true, now: at)
        state.receive([m], now: now)
        XCTAssertTrue(state.drain(sessions: [helper], now: now).isEmpty)
        XCTAssertEqual(state.count, 0, "discard known internal text instead of deferring it for a later heartbeat")
        var shared = PetSpeechState()
        let candidate = PetSpeechState.Candidate(fence: .init(helper, turnID: "1"), itemID: m.itemID,
            timestamp: m.timestamp, revision: m.revision, content: .snapshot(m.text))
        shared.receive(candidate, session: helper, now: now)
        XCTAssertTrue(shared.visible(sessions: [helper], hiddenKinds: [], now: now).isEmpty)
        var ordinary = helper; ordinary.project = "/synthetic/user-workspace"
        state.receive([m], now: now)
        XCTAssertEqual(state.drain(sessions: [ordinary], now: now).count, 1)
    }
}
