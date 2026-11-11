import Foundation

/// Removal selection is deliberately independent of playback preferences.
struct PetAnimationRemovalSelection {
    private(set) var active = false
    private(set) var ids = Set<String>()
    private var rangeAnchor: String?
    private var rangeBase = Set<String>()
    private var marqueeBase: Set<String>?

    mutating func enter() { active = true; clear() }
    mutating func exit() { active = false; clear() }
    private mutating func clear() {
        ids.removeAll(); rangeAnchor = nil; rangeBase.removeAll(); marqueeBase = nil
    }
    mutating func toggle(_ id: String) {
        guard active else { return }
        if !ids.insert(id).inserted { ids.remove(id) }
        rangeAnchor = id
        rangeBase = ids
    }
    mutating func select(_ id: String, extendingRange: Bool, orderedIDs: [String]) {
        guard active, let end = orderedIDs.firstIndex(of: id) else { return }
        if extendingRange, let anchor = rangeAnchor, let start = orderedIDs.firstIndex(of: anchor) {
            ids = rangeBase.union(orderedIDs[min(start, end)...max(start, end)])
        } else { toggle(id) }
    }
    mutating func beginMarquee(additive: Bool) {
        guard active else { return }
        marqueeBase = additive ? ids : []
        rangeAnchor = nil; rangeBase.removeAll()
    }
    mutating func updateMarquee(intersecting hitIDs: Set<String>) {
        guard active, let base = marqueeBase else { return }
        ids = base.union(hitIDs)
    }
    mutating func endMarquee() { marqueeBase = nil }

    static func intersectingIDs(rect: CGRect, frames: [String: CGRect]) -> Set<String> {
        Set(frames.compactMap { id, frame in
            // Borders that merely touch are not a selected card.
            let intersection = rect.standardized.intersection(frame)
            return !intersection.isNull && intersection.width > 0 && intersection.height > 0 ? id : nil
        })
    }
}

struct PetAnimationRemovalPlan {
    let groups: [String: [String]]
    let binding: PetAnimationBinding
    let unreferencedImportedIDs: Set<String>
}

enum PetAnimationRemoval {
    static func groups(pack: ImagePetPack, bindings: PetAnimationBindings) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: PetAnimationBindings.selectionKeys.map { key in
            var ids = pack.candidateIDs(for: key)
            // Preserve old valid choices when first creating membership. Once
            // present, explicit group lists must never resurrect removed items.
            if pack.animationGroups[key] == nil {
                for id in bindings.byKey[key]?.clipIDs ?? [] where pack.animationIDs.contains(id) && !ids.contains(id) { ids.append(id) }
            }
            return (key, ids)
        })
    }

    static func plan(ids: Set<String>, key: String, pack: ImagePetPack,
                     bindings: PetAnimationBindings) throws -> PetAnimationRemovalPlan {
        func invalid(_ message: String) -> PetAnimationImportError { .init(reason: message) }
        guard PetAnimationBindings.selectionKeys.contains(key), !ids.isEmpty else { throw invalid(NSLocalizedString("Select animations to remove.", comment: "")) }
        var groups = groups(pack: pack, bindings: bindings)
        guard let current = groups[key], ids.isSubset(of: Set(current)) else { throw invalid(NSLocalizedString("The animation group changed. Review your selection and try again.", comment: "")) }
        let nativeIDs = Set(pack.animationIDs.filter { $0.hasPrefix("sheet:") || pack.video(for: $0)?.source == .native })
        groups[key] = current.filter { !ids.contains($0) }
        guard groups.values.allSatisfy({ !nativeIDs.intersection($0).isEmpty }) else {
            throw invalid(NSLocalizedString("Each group must keep at least one valid native animation from this pet. Imported animations do not replace this protection.", comment: ""))
        }
        let remaining = groups[key]!
        var selected = bindings.byKey[key]?.clipIDs.filter { remaining.contains($0) } ?? []
        if selected.isEmpty {
            let fallback = pack.nativeDefaultID.flatMap { remaining.contains($0) ? $0 : nil }
                ?? remaining.first { nativeIDs.contains($0) }
            selected = fallback.map { [$0] } ?? []
        }
        var references = Set(groups.values.flatMap { $0 })
        for (otherKey, binding) in bindings.byKey where otherKey != key {
            let allowed = groups[otherKey].map(Set.init) ?? Set(pack.animationIDs)
            references.formUnion(binding.validIDs(in: allowed))
        }
        let referencedPaths = Set(pack.videoClips.filter { references.contains($0.id) }.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
        let unused = Set(pack.videoClips.filter {
            $0.source == .imported && ids.contains($0.id) && !references.contains($0.id)
                && !referencedPaths.contains($0.url.resolvingSymlinksInPath().standardizedFileURL.path)
        }.map(\.id))
        return .init(groups: groups, binding: .init(mode: .rotate, clipIDs: selected), unreferencedImportedIDs: unused)
    }
}
