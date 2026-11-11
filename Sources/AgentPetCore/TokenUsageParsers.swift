import Foundation

// Version-bound native normalization, separate from the storage/collection gate.
enum TokenUsageParsers {
    static func dsh(_ rows: [(Int64, [String: Any])]) -> TokenReadResult {
        var result = TokenReadResult()
        guard let header = rows.first?.1, header["type"] as? String == "session",
              (try? UsageJSON.count(header["version"])) == 4, let sid = try? UsageJSON.id(header["id"]),
              let seeded = header["isSeeded"] as? Bool else { result.issue("usage.error.unsupported"); return result }
        let events = rows.dropFirst()
        let cuts = events.compactMap { _, e -> Int64? in
            guard e["type"] as? String == "session/end-seed", (e["data"] as? [String: Any])?["inherited"] as? Bool == true else { return nil }
            return try? UsageJSON.count(e["seq"])
        }
        if seeded && cuts.isEmpty { result.issue("usage.error.unsupported"); return result }
        let cut = seeded ? cuts.max()! : -1
        var attempts: [String: Int] = [:], slots: [String: TokenRecord] = [:]
        var route: [String: Any] = [:], priorSeq: Int64 = -1
        for (_, e) in events {
            guard let seq = try? UsageJSON.count(e["seq"]), seq > priorSeq else { result.issue("usage.error.invalid"); continue }
            priorSeq = seq
            guard seq > cut else { continue }
            let kind = e["type"] as? String ?? "", d = e["data"] as? [String: Any] ?? [:]
            if kind == "request/context" { route = d }
            guard let turn = try? UsageJSON.count(d["turn"]), let step = try? UsageJSON.count(d["step"]) else {
                if d["usage"] != nil { result.issue("usage.error.unsupported") }; continue
            }
            let key = "\(turn):\(step)"
            if kind == "llm/retry-started" { attempts[key, default: 0] += 1 }
            guard ["assistant/message", "assistant/attempt"].contains(kind) else {
                if d["usage"] != nil { result.issue("usage.error.unsupported") }; continue
            }
            let stream = d["stream"] as? [[String: Any]] ?? []
            let lastUsage = stream.compactMap { ($0["chunk"] as? [String: Any]) }.last { $0["type"] as? String == "usage" }?["usage"]
            guard let usage = (d["usage"] ?? lastUsage) as? [String: Any] else { continue }
            do {
                let b = try TokenBuckets(input: UsageJSON.count(usage["inputTokens"]), cacheRead: UsageJSON.count(usage["cacheReadTokens"] ?? 0), cacheWrite: UsageJSON.count(usage["cacheWriteTokens"] ?? 0), output: UsageJSON.count(usage["outputTokens"]))
                if let total = usage["totalTokens"], try UsageJSON.count(total) != b.total { result.issue("usage.error.totalMismatch") }
                let source = (d["message"] as? [String: Any])?["source"] as? [String: Any] ?? route
                let provider = source["provider"] as? String, model = source["model"] as? String
                let id = sid + ":" + key + ":\(attempts[key, default: 0])"
                let time = try UsageJSON.time(e["time"])
                slots[id] = TokenRecord(id: id, occurredAt: slots[id]?.occurredAt ?? time, revision: seq,
                    agent: provider == "antigravity" ? .agy : .dsh, buckets: b, model: model, provider: provider)
            } catch { result.issue("usage.error.invalid") }
        }
        result.records = Array(slots.values); return result
    }

    static func codexBuckets(_ raw: [String: Any]) throws -> TokenBuckets {
        let input = try UsageJSON.count(raw["input_tokens"]), read = try UsageJSON.count(raw["cached_input_tokens"])
        let write = try UsageJSON.count(raw["cache_write_input_tokens"] ?? 0), out = try UsageJSON.count(raw["output_tokens"])
        let reasoning = try UsageJSON.count(raw["reasoning_output_tokens"] ?? 0)
        guard read + write <= input, reasoning <= out else { throw TokenUsageError.invalid("subsets") }
        let b = try TokenBuckets(input: input - read - write, cacheRead: read, cacheWrite: write, output: out)
        if let total = raw["total_tokens"], try UsageJSON.count(total) != b.total { throw TokenUsageError.invalid("total") }
        return b
    }
    static func codex(_ rows: [(Int64, [String: Any])], fileID: String) -> TokenReadResult {
        var result = TokenReadResult()
        guard let meta = rows.first?.1, meta["type"] as? String == "session_meta",
              let p = meta["payload"] as? [String: Any], let sid = try? UsageJSON.id(p["id"]) else { result.issue("usage.error.unsupported"); return result }
        let history = p["history_base"] as? [String: Any]
        let cut = try? UsageJSON.count(p["forked_from_ordinal_exclusive"] ?? p["subagent_history_start_ordinal"] ?? history?["end_ordinal_exclusive"] ?? 0)
        if p["forked_from_id"] != nil && (cut ?? 0) == 0 { result.issue("usage.error.unsupported"); return result }
        var previous: TokenBuckets?, model: String?, reset = false
        for (offset, row) in rows.dropFirst() {
            guard let payload = row["payload"] as? [String: Any] else { continue }
            if row["type"] as? String == "turn_context" { model = payload["model"] as? String }
            guard row["type"] as? String == "event_msg", payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any] else { continue }
            do {
                guard let raw = info["total_token_usage"] as? [String: Any], let lastRaw = info["last_token_usage"] as? [String: Any] else { throw TokenUsageError.invalid("usage") }
                let total = try codexBuckets(raw)
                let ordinal = try row["ordinal"].map { try UsageJSON.count($0) }
                if (cut ?? 0) > 0 && ordinal == nil { result.issue("usage.error.unsupported"); continue }
                let inherited = (ordinal ?? Int64.max) < (cut ?? 0)
                defer { previous = total }
                if inherited { continue }
                // Status/context snapshots can repeat the verified cumulative
                // counters with an unbucketed estimate in last_token_usage.
                // They add no consumption and must not discard the baseline.
                if total == previous { continue }
                let last = try codexBuckets(lastRaw)
                let b: TokenBuckets
                if let prev = previous {
                    b = try TokenBuckets(input: total.input - prev.input, cacheRead: total.cacheRead - prev.cacheRead, cacheWrite: total.cacheWrite - prev.cacheWrite, output: total.output - prev.output)
                    guard b == last else { throw TokenUsageError.invalid("delta") }
                } else {
                    guard !reset, total == last || (cut ?? 0) > 0 else { result.issue("usage.error.partial"); continue }
                    b = last
                }
                let id = sid + ":" + (ordinal.map(String.init) ?? "\(fileID):offset-\(offset)")
                result.records.append(TokenRecord(id: id, occurredAt: try UsageJSON.time(row["timestamp"]), revision: ordinal ?? offset, agent: .codex, buckets: b, model: model))
            } catch { previous = nil; reset = true; result.issue("usage.error.invalid") }
        }
        return result
    }

    static func claude(_ rows: [(Int64, [String: Any])]) -> TokenReadResult {
        var result = TokenReadResult(), slots: [String: TokenRecord] = [:]
        for (offset, row) in rows where row["type"] as? String == "assistant" {
            guard let message = row["message"] as? [String: Any], let raw = message["usage"] as? [String: Any] else { continue }
            do {
                let native = try UsageJSON.id(message["id"]), sid = try UsageJSON.id(row["sessionId"])
                let b = try TokenBuckets(input: UsageJSON.count(raw["input_tokens"]), cacheRead: UsageJSON.count(raw["cache_read_input_tokens"] ?? 0), cacheWrite: UsageJSON.count(raw["cache_creation_input_tokens"] ?? 0), output: UsageJSON.count(raw["output_tokens"]))
                let id = sid + ":" + native, time = try UsageJSON.time(row["timestamp"])
                slots[id] = TokenRecord(id: id, occurredAt: slots[id]?.occurredAt ?? time, revision: offset, agent: .claude, buckets: b, model: message["model"] as? String)
            } catch { result.issue("usage.error.invalid") }
        }
        result.records = Array(slots.values); return result
    }
}
