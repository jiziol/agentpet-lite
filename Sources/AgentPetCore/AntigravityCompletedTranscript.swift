import Foundation

/// The CLI exports this public transcript before Stop, while its SQLite save
/// can arrive much later. Only the exact current completed Hook turn is eligible.
enum AntigravityCompletedTranscript {
    /// Select top-level public fields without decoding the exported thinking
    /// value. Unknown values are scanned as bytes, including nested structures.
    static func publicFields(_ data: Data) -> [String: Any]? {
        guard data.count <= 524_288 else { return nil }
        let bytes = [UInt8](data); var offset = 0
        func space() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        func string() -> Range<Int>? {
            let start = offset
            guard offset < bytes.count, bytes[offset] == 34 else { return nil }
            offset += 1
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if byte == 34 { return start..<offset }
                if byte < 32 { return nil }
                if byte == 92 {
                    guard offset < bytes.count else { return nil }
                    let escaped = bytes[offset]; offset += 1
                    if escaped == 117 {
                        guard offset + 4 <= bytes.count,
                              bytes[offset..<offset + 4].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
                        offset += 4
                    } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escaped) { return nil }
                }
            }
            return nil
        }
        func value(depth: Int = 0) -> Range<Int>? {
            guard depth < 32, offset < bytes.count else { return nil }
            let start = offset
            if bytes[offset] == 34 { return string() }
            if bytes[offset] == 123 || bytes[offset] == 91 {
                let end: UInt8 = bytes[offset] == 123 ? 125 : 93
                offset += 1; space()
                while offset < bytes.count && bytes[offset] != end {
                    if bytes[offset] == 44 || bytes[offset] == 58 { offset += 1 }
                    else { guard value(depth: depth + 1) != nil else { return nil } }
                    space()
                }
                guard offset < bytes.count else { return nil }; offset += 1
            } else {
                while offset < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
                guard offset > start else { return nil }
            }
            return start..<offset
        }
        let selected: Set<String> = ["step_index", "type", "source", "status", "created_at", "content"]
        var result: [String: Any] = [:]; var count = 0
        space(); guard offset < bytes.count, bytes[offset] == 123 else { return nil }; offset += 1; space()
        while offset < bytes.count && bytes[offset] != 125 {
            count += 1
            guard count <= 64, let range = string(), range.count <= 128,
                  let key = try? JSONSerialization.jsonObject(with: Data(bytes[range]), options: .fragmentsAllowed) as? String else { return nil }
            space(); guard offset < bytes.count, bytes[offset] == 58 else { return nil }; offset += 1; space()
            guard let range = value() else { return nil }
            if selected.contains(key) {
                guard result[key] == nil, let decoded = try? JSONSerialization.jsonObject(with: Data(bytes[range]), options: .fragmentsAllowed) else { return nil }
                result[key] = decoded
            }
            space(); guard offset < bytes.count else { return nil }
            if bytes[offset] == 125 { break }
            guard bytes[offset] == 44 else { return nil }; offset += 1; space()
        }
        guard offset < bytes.count, bytes[offset] == 125 else { return nil }; offset += 1; space()
        return offset == bytes.count ? result : nil
    }
    static func path(database: String, sessionID: String) -> String? {
        let suffix = "/conversations/\(sessionID).db"
        guard database.hasSuffix(suffix) else { return nil }
        return String(database.dropLast(suffix.count)) + "/brain/\(sessionID)/.system_generated/logs/transcript_full.jsonl"
    }

    static func read(path: String, boundary: AntigravityVisibleMessage.Boundary) -> AntigravityPublicResponse.Step? {
        guard !boundary.hosted, let completed = boundary.completedAt,
              completed >= boundary.startedAt else { return nil }
        let fm = FileManager.default
        guard let before = try? fm.attributesOfItem(atPath: path),
              let length = (before[.size] as? NSNumber)?.uint64Value,
              let modified = before[.modificationDate] as? Date,
              modified >= boundary.startedAt.addingTimeInterval(-1),
              modified <= completed.addingTimeInterval(2),
              let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        // Bounded tail; discard a partial first line instead of guessing at JSON.
        let start = length > 524_288 ? length - 524_288 : 0
        guard (try? file.seek(toOffset: start)) != nil,
              var data = try? file.read(upToCount: 524_288), !data.isEmpty else { return nil }
        if start > 0 {
            guard let newline = data.firstIndex(of: 10) else { return nil }
            data = Data(data.suffix(from: data.index(after: newline)))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var selected: AntigravityPublicResponse.Step?
        // Exported created_at is rounded to seconds; the exact Hook step floor
        // disambiguates prior turns within the same second.
        let earliest = floor(boundary.startedAt.timeIntervalSince1970)
        for line in data.split(separator: 10).suffix(64).reversed() {
            guard let row = publicFields(Data(line)),
                  row["type"] as? String == "PLANNER_RESPONSE", row["source"] as? String == "MODEL",
                  row["status"] as? String == "DONE",
                  let index = row["step_index"] as? Int, index >= boundary.stepFloor,
                  let createdText = row["created_at"] as? String,
                  let created = formatter.date(from: createdText) ?? plain.date(from: createdText),
                  created.timeIntervalSince1970 >= earliest, created <= completed,
                  let text = row["content"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            selected = .init(index: index, executionID: "transcript-\(boundary.startedAt.timeIntervalSinceReferenceDate)",
                             completedAt: completed, text: text)
            break
        }
        guard let after = try? fm.attributesOfItem(atPath: path),
              before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber else { return nil }
        return selected
    }
}
