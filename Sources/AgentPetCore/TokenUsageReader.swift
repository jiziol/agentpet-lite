import Foundation
import CUsageZstd

/// Bounded read-only native persistence. No processes, credentials or migrations.
public enum TokenUsageReader {
    public static func read(_ instance: TokenUsageInstance, since: Date, now: Date = Date()) -> TokenReadResult {
        if instance.source == .opencode { return TokenUsageOpenCode.read(instance, since: since, now: now) }
        var result = TokenReadResult()
        let roots: [URL]
        switch instance.source {
        case .dsh: roots = [instance.root.appendingPathComponent("sessions")]
        case .codex: roots = ["sessions", "archived_sessions"].map { instance.root.appendingPathComponent($0) }
        case .claude: roots = [instance.root]
        default: roots = []
        }
        var foundRoot = false, fileCount = 0
        var enumerationFailed = false
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            foundRoot = true
            guard let rootInfo = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true else {
                result.issue("usage.error.unsupported"); continue
            }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
                result.issue("usage.error.unavailable"); continue
            }
            while let url = enumerator.nextObject() as? URL {
                do {
                    let attr = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
                    if attr.isSymbolicLink == true { enumerator.skipDescendants(); result.issue("usage.error.unsupported"); continue }
                    let name = url.lastPathComponent
                    let supported = instance.source == .dsh ? ["session.v4.jsonl", "session.v4.jsonl.zstd"].contains(name) : url.pathExtension == "jsonl"
                    if !supported {
                        if instance.source == .dsh && name.hasPrefix("session.v") && name.contains("jsonl"),
                           attr.contentModificationDate.map({ $0 >= since }) ?? true { result.issue("usage.error.unsupported") }
                        continue
                    }
                    guard attr.isRegularFile == true else { continue }
                    result.files.insert(TokenUsageInstance.digest(url.path))
                    fileCount += 1
                    guard fileCount <= 10000 else { result.issue("usage.error.limit"); break }
                    guard let modified = attr.contentModificationDate else { result.issue("usage.error.unavailable"); continue }
                    if modified < since { continue }
                    let limit = instance.source == .codex ? 512 * 1024 * 1024 : 64 * 1024 * 1024
                    guard let size = attr.fileSize, size <= limit else { result.issue("usage.error.limit"); continue }
                    let objects: [(Int64, [String: Any])]
                    if instance.source == .codex {
                        objects = try codexRows(url, size: size, result: &result)
                    } else {
                        let handle = try FileHandle(forReadingFrom: url)
                        let data: Data
                        do { data = try handle.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data(); try handle.close() }
                        catch { try? handle.close(); throw error }
                        guard data.count <= 64 * 1024 * 1024 else { throw TokenUsageError.limit }
                        var plain = data
                        if name.hasSuffix(".zstd") {
                            var output: UnsafeMutableRawPointer?, size = 0
                            let status = data.withUnsafeBytes { bytes in usage_zstd_decode(bytes.baseAddress, bytes.count, 128 * 1024 * 1024, &output, &size) }
                            defer { usage_zstd_free(output) }
                            guard status >= 0, let output else { throw status == -2 ? TokenUsageError.limit : TokenUsageError.corrupt }
                            plain = Data(bytes: output, count: size)
                            if status == 1 { result.issue("usage.error.partial") }
                        }
                        // Never accept an unterminated JSON row as a committed event.
                        if plain.last != 10 { result.issue("usage.error.partial") }
                        let lines = plain.split(separator: 10, omittingEmptySubsequences: false).dropLast()
                        var rows: [(Int64, [String: Any])] = [], offset: Int64 = 0
                        for line in lines {
                            defer { offset += Int64(line.count + 1) }
                            guard !line.isEmpty else { continue }
                            guard line.count <= 16 * 1024 * 1024,
                                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                                result.issue("usage.error.corrupt"); continue
                            }
                            rows.append((offset, object))
                        }
                        objects = rows
                    }
                    let parsed: TokenReadResult
                    switch instance.source {
                    case .dsh: parsed = TokenUsageParsers.dsh(objects)
                    case .codex: parsed = TokenUsageParsers.codex(objects, fileID: TokenUsageInstance.digest(url.lastPathComponent))
                    case .claude: parsed = TokenUsageParsers.claude(objects)
                    default: parsed = TokenReadResult()
                    }
                    if parsed.records.contains(where: { $0.occurredAt > now }) { result.issue("usage.error.partial") }
                    result.records += parsed.records.filter { $0.occurredAt >= since && $0.occurredAt <= now }
                    for issue in parsed.issues { result.issue(issue) }
                    let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    if after.fileSize != attr.fileSize || after.contentModificationDate != attr.contentModificationDate { result.issue("usage.error.partial") }
                } catch {
                    result.issue((error as? TokenUsageError)?.errorDescription ?? "usage.error.unavailable")
                }
            }
            // Enumerator errors are not exposed reliably by all Foundation versions.
            // Check access explicitly so an inaccessible directory is never a true zero.
            if !FileManager.default.isReadableFile(atPath: root.path) { result.issue("usage.error.unavailable") }
        }
        if enumerationFailed { result.issue("usage.error.unavailable") }
        if !foundRoot { result.quality = .failed; result.issues.insert("usage.error.unavailable") }
        var unique: [String: TokenRecord] = [:]
        for row in result.records {
            if let old = unique[row.id] {
                if row.revision > old.revision { unique[row.id] = row }
                else if row.revision == old.revision && row != old { result.issue("usage.error.invalid") }
            } else { unique[row.id] = row }
        }
        result.records = unique.values.sorted { $0.id < $1.id }
        return result
    }

    /// Long Codex transcripts contain large tool/context bodies. Stream a fixed
    /// snapshot and retain only accounting metadata, preserving native offsets.
    /// Memory is bounded by a 16 MiB row plus at most 100,000 metadata rows.
    private static func codexRows(_ url: URL, size: Int, result: inout TokenReadResult) throws -> [(Int64, [String: Any])] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var rows: [(Int64, [String: Any])] = []
        var remaining = size, line = Data(), oversized = false
        var offset: Int64 = 0, lineOffset: Int64 = 0
        while remaining > 0 {
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
            if chunk.isEmpty { result.issue("usage.error.partial"); break }
            remaining -= chunk.count
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let newline = chunk[start...].firstIndex(of: 10)
                let end = newline ?? chunk.endIndex
                let fragment = chunk[start..<end]
                if !oversized {
                    if line.count + fragment.count <= 16 * 1024 * 1024 { line.append(contentsOf: fragment) }
                    else { oversized = true; line.removeAll(keepingCapacity: false); result.issue("usage.error.corrupt") }
                }
                offset += Int64(fragment.count)
                guard let newline else { break }
                if !oversized && !line.isEmpty {
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        if let row = codexMetadata(object) {
                            guard rows.count < 100_000 else { result.issue("usage.error.limit"); return rows }
                            rows.append((lineOffset, row))
                        }
                    } else { result.issue("usage.error.corrupt") }
                }
                offset += 1; lineOffset = offset
                line.removeAll(keepingCapacity: true); oversized = false
                start = chunk.index(after: newline)
            }
        }
        if !line.isEmpty || oversized { result.issue("usage.error.partial") }
        return rows
    }

    private static func codexMetadata(_ row: [String: Any]) -> [String: Any]? {
        guard let type = row["type"] as? String, let payload = row["payload"] as? [String: Any] else { return nil }
        var value = row.filter { ["type", "ordinal", "timestamp"].contains($0.key) }
        switch type {
        case "session_meta":
            value["payload"] = payload.filter { ["id", "forked_from_id", "forked_from_ordinal_exclusive", "subagent_history_start_ordinal", "history_base"].contains($0.key) }
        case "turn_context": value["payload"] = payload.filter { $0.key == "model" }
        case "event_msg" where payload["type"] as? String == "token_count":
            value["payload"] = payload.filter { ["type", "info"].contains($0.key) }
        default: return nil
        }
        return value
    }
}
