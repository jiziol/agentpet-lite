import Foundation
import CryptoKit
import CoreFoundation

public enum TokenAgent: String, Codable, CaseIterable, Sendable {
    case dsh, codex, opencode, claude, agy
    public var name: String {
        switch self { case .dsh: "DSH"; case .codex: "Codex"; case .opencode: "OpenCode"; case .claude: "CC"; case .agy: "agy" }
    }
}

public enum TokenSource: String, Codable, CaseIterable, Sendable { case dsh, codex, opencode, claude }
public enum TokenUsageError: Error, LocalizedError, Sendable {
    case invalid(String), storage, unsupported, unavailable, limit, corrupt
    public var errorDescription: String? {
        switch self {
        case .invalid: "usage.error.invalid"
        case .storage: "usage.error.storage"
        case .unsupported: "usage.error.unsupported"
        case .unavailable: "usage.error.unavailable"
        case .limit: "usage.error.limit"
        case .corrupt: "usage.error.corrupt"
        }
    }
}

/// All four buckets are disjoint. Output already contains reasoning.
public struct TokenBuckets: Codable, Equatable, Sendable {
    public let input: Int64
    public let cacheRead: Int64
    public let cacheWrite: Int64
    public let output: Int64
    public var total: Int64 { input + cacheRead + cacheWrite + output }
    public static let zero = try! TokenBuckets(input: 0, cacheRead: 0, cacheWrite: 0, output: 0)
    public init(input: Int64, cacheRead: Int64, cacheWrite: Int64, output: Int64) throws {
        let values = [input, cacheRead, cacheWrite, output]
        guard values.allSatisfy({ $0 >= 0 && $0 <= 9_007_199_254_740_991 }),
              values.reduce(0, +) <= 9_007_199_254_740_991 else { throw TokenUsageError.invalid("counts") }
        self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.output = output
    }
    public func adding(_ other: Self) throws -> Self {
        try .init(input: input + other.input, cacheRead: cacheRead + other.cacheRead,
                  cacheWrite: cacheWrite + other.cacheWrite, output: output + other.output)
    }
}

public struct TokenRecord: Codable, Equatable, Sendable {
    public let id: String
    public let occurredAt: Date
    public let revision: Int64
    public let agent: TokenAgent
    public let buckets: TokenBuckets
    public let model: String?
    public let provider: String?
    public init(id: String, occurredAt: Date, revision: Int64, agent: TokenAgent,
                buckets: TokenBuckets, model: String? = nil, provider: String? = nil) {
        self.id = id; self.occurredAt = occurredAt; self.revision = revision; self.agent = agent
        self.buckets = buckets; self.model = model; self.provider = provider
    }
}

public struct TokenUsageInstance: Codable, Equatable, Identifiable, Sendable {
    public let source: TokenSource
    public let root: URL
    public var id: String { source.rawValue + ":" + Self.digest(root.path) }
    public init(source: TokenSource, root: URL) {
        self.source = source; self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }
    public static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public enum TokenReadQuality: String, Codable, Sendable { case complete, partial, failed }
public struct TokenReadResult: Sendable {
    public var records: [TokenRecord] = []
    public var quality: TokenReadQuality = .complete
    /// Stable, localized diagnostic keys, never transcript content.
    public var issues: Set<String> = []
    public var files: Set<String> = []
    public init() {}
    public mutating func issue(_ key: String) { issues.insert(key); if quality == .complete { quality = .partial } }
}

public struct TokenCollectionInterval: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date?
    public init(start: Date, end: Date? = nil) { self.start = start; self.end = end }
    public func contains(_ date: Date) -> Bool { date >= start && (end == nil || date < end!) }
}
public enum TokenCollectionPauseReason: String, Codable, Sendable { case user, integrationRemoved }
public struct TokenCollectionState: Codable, Equatable, Sendable {
    public let instance: TokenUsageInstance
    public var intervals: [TokenCollectionInterval]
    public var checkedAt: Date?
    public var quality: TokenReadQuality?
    /// Historical pause provenance; current integration eligibility drives collection.
    public var pauseReason: TokenCollectionPauseReason?
    public var issues: Set<String> = []
    public var files: Set<String> = []
    public init(instance: TokenUsageInstance, intervals: [TokenCollectionInterval], checkedAt: Date? = nil,
                quality: TokenReadQuality? = nil, issues: Set<String> = [], files: Set<String> = []) {
        self.instance = instance; self.intervals = intervals; self.checkedAt = checkedAt
        self.quality = quality; self.issues = issues; self.files = files
    }
    public var startedAt: Date? { intervals.first?.start }
    public var enabled: Bool { intervals.last.map { $0.end == nil } ?? false }
    public func accepts(_ date: Date) -> Bool { intervals.contains { $0.contains(date) } }
}

public enum TokenDayCoverage: String, Sendable { case notStarted, partial, complete, unknown }
public struct TokenUsageDay: Identifiable, Sendable {
    public let date: Date
    public var byAgent: [TokenAgent: TokenBuckets]
    public var coverage: TokenDayCoverage
    public var id: Date { date }
    public var total: Int64 { byAgent.values.reduce(0) { $0 + $1.total } }
    public init(date: Date, byAgent: [TokenAgent: TokenBuckets] = [:], coverage: TokenDayCoverage) {
        self.date = date; self.byAgent = byAgent; self.coverage = coverage
    }
}
public struct TokenUsageSnapshot: Sendable {
    public var days: [TokenUsageDay]
    public var states: [TokenCollectionState]
    public var records: [TokenRecord]
    public var total: Int64 { days.reduce(0) { $0 + $1.total } }
    public var agents: [TokenAgent] { TokenAgent.allCases.filter { agent in days.contains { ($0.byAgent[agent]?.total ?? 0) > 0 } } }
    public init(days: [TokenUsageDay] = [], states: [TokenCollectionState] = [], records: [TokenRecord] = []) {
        self.days = days; self.states = states; self.records = records
    }
}

enum UsageJSON {
    static func count(_ value: Any?) throws -> Int64 {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991,
              n.doubleValue.rounded(.towardZero) == n.doubleValue else { throw TokenUsageError.invalid("count") }
        return n.int64Value
    }
    static func id(_ value: Any?) throws -> String {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 2048 else { throw TokenUsageError.invalid("identity") }
        return text
    }
    static func time(_ value: Any?) throws -> Date {
        if let text = value as? String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: text) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: text) { return date }
            throw TokenUsageError.invalid("time")
        }
        return Date(timeIntervalSince1970: Double(try count(value)) / 1000)
    }
}
