import Foundation
import AgentPetCore

/// Persists only the tucked side per window key. The bottom-center anchor keeps
/// using `agentpet.petAnchors.v1`, so existing positions migrate without a
/// rewrite and old builds can still read the same anchor.
@MainActor
final class PetEdgeStateStore {
    static let sidesKey = "agentpet.petEdges.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func side(forKey key: String) -> PetEdgeSide? {
        guard let raw = sides()[key] else { return nil }
        return PetEdgeSide(rawValue: raw)
    }

    func save(_ side: PetEdgeSide, forKey key: String) {
        var all = sides()
        all[key] = side.rawValue
        write(all)
    }

    func clear(forKey key: String) {
        var all = sides()
        guard all.removeValue(forKey: key) != nil else { return }
        write(all)
    }

    private func sides() -> [String: String] {
        guard let data = defaults.data(forKey: Self.sidesKey),
              data.count <= 131_072,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        // Drop unknown/corrupt values instead of turning them into a side.
        return decoded.filter { PetEdgeSide(rawValue: $0.value) != nil }
    }

    private func write(_ value: [String: String]) {
        if value.isEmpty {
            defaults.removeObject(forKey: Self.sidesKey)
            return
        }
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.sidesKey)
    }
}
