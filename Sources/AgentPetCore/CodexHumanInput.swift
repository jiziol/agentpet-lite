import Foundation

/// Follows native call IDs and explicit UI replies. An async "accepted" receipt
/// only means the dialog was created; it never counts as the user's answer.
public struct CodexHumanInputTracker: Sendable {
    private struct Call: Sendable {
        var requests: [HumanRequest]
        let asynchronous: Bool
    }
    private var calls: [String: Call] = [:]
    private var closed: [String: Date] = [:]
    private var turnID: String?
    private var turnStartedAt: Date?

    public init() {}
    public var pending: [HumanRequest] { calls.values.flatMap(\.requests).sorted { $0.createdAt < $1.createdAt } }
    public var resolved: [HumanRequest] { closed.map { HumanRequest(id: $0.key, kind: .reply, createdAt: $0.value) } }

    public mutating func ingest(_ data: Data) -> (HumanIntervention, Date)? {
        guard data.count <= 1_048_576 else { return nil }
        if data.range(of: Data("event_msg".utf8)) != nil, let lifecycle = CodexLifecycle.parse(data) {
            if lifecycle.result == nil {
                // A new native turn supersedes earlier cards in AgentPet's
                // single-current-turn display. This sends no answer/approval
                // to Codex; ordinary work in the same turn keeps waiting.
                guard lifecycle.turnID != turnID,
                      lifecycle.timestamp > (turnStartedAt ?? .distantPast) else { return nil }
                turnID = lifecycle.turnID; turnStartedAt = lifecycle.timestamp
                return finish(pending.filter { $0.createdAt < lifecycle.timestamp }.map(\.id), at: lifecycle.timestamp)
            }
            if lifecycle.result == .cancelled || lifecycle.result == .failed {
                guard turnID == nil || lifecycle.turnID == turnID else { return nil }
                // A cancelled dialog cannot occupy tracker capacity forever.
                _ = finish(pending.map(\.id), at: lifecycle.timestamp)
            }
            return nil
        }
        // Most rollout records contain tools, usage or prose unrelated to input.
        let mayAsk = data.range(of: Data("request_user_input".utf8)) != nil
        guard mayAsk || !calls.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "response_item",
              let p = root["payload"] as? [String: Any],
              let timestamp = CodexLifecycle.date(root["timestamp"]) else { return nil }
        if p["type"] as? String == "function_call",
           HumanIntervention.toolKind(p["name"] as? String) != nil,
           let id = p["call_id"] as? String, HumanIntervention.validID(id), calls[id] == nil, calls.count < 64,
           timestamp >= (turnStartedAt ?? .distantPast) {
            let argument = (p["arguments"] as? String)?.data(using: .utf8)
            let object = argument.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard let questions = object?["questions"] as? [[String: Any]], !questions.isEmpty, questions.count <= 32 else { return nil }
            let requests = (0..<max(1, questions.count)).map { index in
                let choice = questions.indices.contains(index) && !(questions[index]["options"] as? [Any] ?? []).isEmpty
                return HumanRequest(id: id + "#" + String(index), kind: choice ? .choice : .reply, createdAt: timestamp)
            }
            guard requests.allSatisfy({ HumanIntervention.validID($0.id) && (closed[$0.id] ?? .distantPast) < timestamp }) else { return nil }
            let name = (p["name"] as? String)?.components(separatedBy: ".").last
            calls[id] = Call(requests: requests, asynchronous: name == "request_user_input_async")
            return (HumanIntervention(action: .asked, requests: requests), timestamp)
        }
        if p["type"] as? String == "function_call_output", let id = p["call_id"] as? String, let call = calls[id] {
            let output = (p["output"] as? String)?.data(using: .utf8)
            let object = output.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if call.asynchronous {
                if object?["accepted"] as? Bool == true { return nil }
                guard object?["accepted"] as? Bool == false || object?["answers"] != nil || object?["error"] != nil else { return nil }
            }
            return finish(call.requests.map(\.id), at: timestamp)
        }
        guard p["type"] as? String == "message", p["role"] as? String == "user",
              let content = p["content"] as? [[String: Any]] else { return nil }
        var ids: [String] = []
        for part in content {
            guard let text = part["text"] as? String,
                  let start = text.range(of: "<send_user_message_question_reply>"),
                  let end = text.range(of: "</send_user_message_question_reply>", range: start.upperBound..<text.endIndex),
                  let bytes = String(text[start.upperBound..<end.lowerBound]).data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else { continue }
            for row in rows {
                guard let item = row["questionItemId"] as? String, let encoded = item.data(using: .utf8),
                      let key = try? JSONSerialization.jsonObject(with: encoded) as? [Any], key.count == 3,
                      let tool = key[0] as? String, HumanIntervention.toolKind(tool) != nil,
                      let call = key[1] as? String, let index = key[2] as? Int, index >= 0, index < 32 else { continue }
                ids.append(call + "#" + String(index))
            }
        }
        return finish(ids, at: timestamp)
    }

    private mutating func finish(_ ids: [String], at timestamp: Date) -> (HumanIntervention, Date)? {
        let known = pending.filter { ids.contains($0.id) && $0.createdAt <= timestamp }
        guard !known.isEmpty else { return nil }
        let finished = Set(known.map(\.id))
        for (id, var call) in calls {
            call.requests.removeAll { finished.contains($0.id) }
            if call.requests.isEmpty { calls.removeValue(forKey: id) }
            else { calls[id] = call }
        }
        for request in known { closed[request.id] = timestamp }
        closed = Dictionary(uniqueKeysWithValues: closed.sorted { $0.value > $1.value }.prefix(128).map { ($0.key, $0.value) })
        return (HumanIntervention(action: .resolved, requests: known), timestamp)
    }
}
