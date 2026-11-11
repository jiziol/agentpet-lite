import AppKit
import AgentPetCore

/// Persist the pet's bottom-center, independent of the current bubble width.
@MainActor
final class PetWindowPositionStore {
    static let anchorsKey = "agentpet.petAnchors.v1"
    static let legacyKey = "agentpet.petPositions"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func anchor(forKey key: String, legacyWindowWidth: CGFloat) -> NSPoint? {
        if let anchor = point(in: Self.anchorsKey, key: key) { return anchor }
        // Older versions did not record their panel width. Without live upgrade
        // geometry, retain the old startup placement once, then save an anchor.
        guard let origin = point(in: Self.legacyKey, key: key),
              legacyWindowWidth.isFinite, legacyWindowWidth > 0 else { return nil }
        return NSPoint(x: origin.x + legacyWindowWidth / 2, y: origin.y)
    }

    func save(_ anchor: NSPoint, forKey key: String) {
        guard anchor.x.isFinite, anchor.y.isFinite else { return }
        var all = positions(in: Self.anchorsKey)
        all[key] = [Double(anchor.x), Double(anchor.y)]
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.anchorsKey) }
    }

    private func positions(in name: String) -> [String: [Double]] {
        guard let data = defaults.data(forKey: name),
              let decoded = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
        return decoded
    }

    private func point(in name: String, key: String) -> NSPoint? {
        guard let xy = positions(in: name)[key], xy.count == 2,
              xy.allSatisfy(\.isFinite) else { return nil }
        return NSPoint(x: xy[0], y: xy[1])
    }
}

/// Requested placement survives temporary bubble growth and screen-edge fitting.
struct PetWindowPlacement {
    var anchor: NSPoint?
    private(set) var programmaticFrame: NSRect?

    /// Ignore notifications for our own layout, including deferred notifications.
    mutating func recordUserMove(frame: NSRect, petOffset: CGFloat) -> Bool {
        guard frame != programmaticFrame else { return false }
        anchor = NSPoint(x: frame.midX + petOffset, y: frame.minY)
        return true
    }

    mutating func fitAnchor(petSize: CGSize, visible: NSRect) {
        guard let anchor else { return }
        let origin = PetWindowGeometry.clampOrigin(
            NSPoint(x: anchor.x - petSize.width / 2, y: anchor.y), size: petSize, into: visible)
        self.anchor = NSPoint(x: origin.x + petSize.width / 2, y: origin.y)
    }

    mutating func layout(size: CGSize, petWidth: CGFloat, visible: NSRect?)
        -> (frame: NSRect, petOffset: CGFloat)? {
        guard let anchor else { return nil }
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y)
        var offset: CGFloat = 0
        if let visible {
            let horizontal = PetWindowGeometry.horizontalLayout(
                anchorX: anchor.x, width: size.width, petWidth: petWidth,
                visibleMinX: visible.minX, visibleMaxX: visible.maxX)
            origin.x = horizontal.originX
            offset = horizontal.petOffset
            // Temporary vertical fitting must not overwrite the user's anchor.
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        let frame = NSRect(origin: origin, size: size)
        programmaticFrame = frame
        return (frame, offset)
    }
}
