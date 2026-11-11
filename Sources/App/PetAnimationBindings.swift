import Foundation
import AgentPetCore

enum PetAnimationMode: String, Codable { case fixed, rotate }

struct PetAnimationBinding: Codable, Equatable {
    var mode: PetAnimationMode = .fixed
    var clipIDs: [String]

    func validIDs(in available: Set<String>) -> [String] {
        var seen = Set<String>()
        let valid = clipIDs.filter { available.contains($0) && seen.insert($0).inserted }
        return mode == .fixed ? Array(valid.prefix(1)) : valid
    }
}

struct PetAnimationBindings: Codable, Equatable {
    var version = 2
    var byKey: [String: PetAnimationBinding]

    static let selectionKeys: Set<String> = ["idle", "working", "waiting", "success", "failure", "quota", "levelup", "tap", "drag"]
    static func allowsMultiple(_ key: String) -> Bool { selectionKeys.contains(key) }

    func applyingSelectionRules() -> Self {
        var result = self
        for key in Self.selectionKeys {
            guard var binding = result.byKey[key] else { continue }
            binding.mode = .rotate
            result.byKey[key] = binding
        }
        return result
    }

    static func legacy(_ map: [String: Int], spriteCount: Int) -> Self {
        let defaults = PetBindings.defaults(clipCount: spriteCount)
        var result: [String: PetAnimationBinding] = [:]
        for mood in PetMood.allCases {
            let index = min(max(map[mood.rawValue] ?? defaults.clipIndex(for: mood), 0), max(spriteCount - 1, 0))
            result[mood.rawValue] = .init(clipIDs: spriteCount > 0 ? ["sheet:\(index)"] : [])
        }
        result["tap"] = .init(clipIDs: [])
        result["drag"] = .init(clipIDs: [])
        return .init(byKey: result)
    }
}

@MainActor
final class PetAnimationBindingsStore: ObservableObject {
    static let shared = PetAnimationBindingsStore()
    private var cache: [String: PetAnimationBindings] = [:]
    @Published private var revision: UInt64 = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func bindings(for pack: ImagePetPack) -> PetAnimationBindings {
        if let cached = cache[pack.id] { return prepared(cached, for: pack) }
        let loaded: PetAnimationBindings
        if let data = defaults.data(forKey: key(pack.id)),
           data.count <= 131_072,
           let value = try? JSONDecoder().decode(PetAnimationBindings.self, from: data),
           value.version == 2 {
            loaded = value
        } else {
            let old = defaults.data(forKey: "agentpet.bindings.\(pack.id)")
                .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
            if old.isEmpty {
                // Explicit native purpose mappings seed new installs only.
                loaded = .init(byKey: [:])
            } else { loaded = .legacy(old, spriteCount: pack.clips.count) }
        }
        cache[pack.id] = loaded
        return prepared(loaded, for: pack)
    }

    private func prepared(_ stored: PetAnimationBindings, for pack: ImagePetPack) -> PetAnimationBindings {
        var value = stored
        if value.byKey["success"] == nil {
            let old = ["done", "celebrate"].flatMap { stored.byKey[$0]?.clipIDs ?? [] }
            if !old.isEmpty { value.byKey["success"] = .init(mode: .rotate, clipIDs: old) }
        }
        for key in PetAnimationBindings.selectionKeys {
            let available = Set(pack.animationIDs)
            let candidates = pack.candidateIDs(for: key)
            let existing = value.byKey[key]
            // Existing valid choices survive the first MOV and purpose changes.
            // Explicit library membership is authoritative after management.
            let allowed = pack.animationGroups[key] == nil ? available : Set(candidates)
            let valid = (existing?.clipIDs ?? []).filter { allowed.contains($0) }
            let seeded: [String]
            if !valid.isEmpty { seeded = valid }
            else if existing == nil {
                let mapped = candidates.filter { pack.video(for: $0)?.purposes.contains(key) == true }
                seeded = mapped.isEmpty ? pack.nativeFallbackID(for: key).map { [$0] } ?? [] : mapped
            } else {
                // Missing/empty/stale selections use a native default, never
                // silently re-enable every (possibly imported) candidate.
                seeded = pack.nativeFallbackID(for: key).map { [$0] } ?? []
            }
            value.byKey[key] = .init(mode: .rotate, clipIDs: seeded)
        }
        return value.applyingSelectionRules()
    }

    func set(_ binding: PetAnimationBinding, key animationKey: String, pack: ImagePetPack) {
        var value = bindings(for: pack)
        var normalized = binding
        normalized.mode = PetAnimationBindings.allowsMultiple(animationKey) ? .rotate : .fixed
        normalized.clipIDs = normalized.validIDs(in: Set(pack.animationGroups[animationKey] == nil ? pack.animationIDs : pack.candidateIDs(for: animationKey)))
        // Mood bindings always have a safe fallback; interaction bindings may be disabled.
        if normalized.clipIDs.isEmpty, PetAnimationBindings.selectionKeys.contains(animationKey),
           let first = pack.nativeFallbackID(for: animationKey) { normalized.clipIDs = [first] }
        value.byKey[animationKey] = normalized
        save(value, packID: pack.id)
    }

    func restoreLegacy(for pack: ImagePetPack) {
        let old = defaults.data(forKey: "agentpet.bindings.\(pack.id)")
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        save(.legacy(old, spriteCount: pack.clips.count), packID: pack.id)
    }

    private func key(_ id: String) -> String { "agentpet.animationBindings.v2.\(id)" }
    private func save(_ value: PetAnimationBindings, packID: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key(packID))
        cache[packID] = value
        revision &+= 1
    }
}
