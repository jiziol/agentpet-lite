import XCTest
@testable import AgentPetCore
final class DSHVisibleMessageTests: XCTestCase {
    static func data(_ changes: [String:Any] = [:]) throws -> Data {
        var frame:[String:Any] = ["schema":"agentpet.dsh.speech.v1","profile_id":String(repeating:"a",count:24),
          "host_id":"11111111-1111-4111-8111-111111111111","host_started_at":990,"session_id":"native-A",
          "turn":1,"native_seq":3,"observation_revision":2,"item_id":"3","revision":1,"timestamp":1000,
          "role":"assistant","part_type":"text","mode":"snapshot","text":"公开正文"]
        frame.merge(changes){_,n in n};return try JSONSerialization.data(withJSONObject:frame)
    }
    func testDedicatedSocketChannelAndMalformedSpeechCannotBecomeLifecycleOrReplay() throws {
        // This test checks channel isolation, not wall-clock precision. A fixed
        // binary-exact fractional Unix time keeps whole-event equality strict.
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.25)
        let path="/tmp/ap-dsh-speech-"+UUID().uuidString+".sock", server=EventSocketServer(path:path)
        defer{server.stop()}
        let text=expectation(description:"DSH speech"), lifecycle=expectation(description:"lifecycle")
        try server.start(onDSHVisibleMessage:{ m in XCTAssertEqual(m.text,"公开正文");text.fulfill() }){e in
            XCTAssertEqual(e.sessionId,"real-event");lifecycle.fulfill()
        }
        let peer=try SocketTransportScenarios.Peer(path)
        var malformed=try JSONSerialization.jsonObject(with:EventCoding.encoder.encode(AgentEvent(sessionId:"must-not-route",agentKind:.dsh,eventName:"working",timestamp:timestamp))) as! [String:Any]
        malformed["schema"]="agentpet.dsh.speech.v2"
        var data=try Self.data();data.append(10);data.append(try JSONSerialization.data(withJSONObject:malformed));data.append(10)
        let event=AgentEvent(sessionId:"real-event",agentKind:.dsh,eventName:"working",timestamp:timestamp)
        data.append(try EventSender.encodeLine(event));XCTAssertTrue(peer.send(data));wait(for:[text,lifecycle],timeout:2)
        var replay:[AgentEvent]=[];EventSocketServer.decodeLines(data){replay.append($0)};XCTAssertEqual(replay,[event])
    }

    func testFractionalEventTimesPreserveUnixWirePrecisionAndOtherFields() throws {
        // Date stores seconds since 2001; the wire stores a Double since 1970.
        // Adjacent values here exercise both sides of the epoch-conversion
        // rounding boundary without relying on whichever Date() a run samples.
        let referenceSeconds = 814_000_000.0
        for index in 0..<256 {
            let timestamp = Date(timeIntervalSinceReferenceDate:
                referenceSeconds + Double(index) * referenceSeconds.ulp)
            let event = AgentEvent(sessionId: "fractional-\(index)", agentKind: .dsh,
                eventName: "working", project: "/synthetic", message: "fixture",
                model: "fixture-model", timestamp: timestamp)
            var replay: [AgentEvent] = []
            EventSocketServer.decodeLines(try EventSender.encodeLine(event)) { replay.append($0) }

            let unixSeconds = timestamp.timeIntervalSince1970
            var expected = event
            expected.timestamp = Date(timeIntervalSince1970: unixSeconds)
            // Every field, including the time represented by the wire, stays
            // exact. Only the source Date's unrepresentable low bit may differ.
            XCTAssertEqual(replay, [expected], "fractional fixture \(index)")
            let decoded = try XCTUnwrap(replay.first)
            XCTAssertLessThanOrEqual(abs(decoded.timestamp.timeIntervalSince(timestamp)),
                unixSeconds.ulp / 2, "fractional fixture \(index)")
        }
    }
}
