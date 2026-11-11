import CoreGraphics
import Foundation

/// The screen edge a pet can tuck into. Persisted as a stable string so an
/// installed side survives relaunches without depending on display indices.
public enum PetEdgeSide: String, Codable, CaseIterable, Sendable {
    case left
    case right
}

/// AppKit-free snapshot of one display. `frame` is the full display rectangle
/// (used for seam detection); `visibleFrame` excludes the menu bar and Dock
/// (used for the tuck line and vertical clamping).
public struct PetEdgeScreen: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Result of a release near an outer display edge.
public struct PetEdgeSnap: Equatable, Sendable {
    public var side: PetEdgeSide
    public var screenIndex: Int
    public var visibleFrame: CGRect

    public init(side: PetEdgeSide, screenIndex: Int, visibleFrame: CGRect) {
        self.side = side
        self.screenIndex = screenIndex
        self.visibleFrame = visibleFrame
    }
}

/// Result of restoring a persisted side onto the current display layout.
public struct PetEdgeRestoration: Equatable, Sendable {
    public var side: PetEdgeSide
    public var screenIndex: Int
    public var visibleFrame: CGRect
    /// Bottom-center anchor of the full pet after vertical clamping.
    public var anchor: CGPoint

    public init(side: PetEdgeSide, screenIndex: Int, visibleFrame: CGRect, anchor: CGPoint) {
        self.side = side
        self.screenIndex = screenIndex
        self.visibleFrame = visibleFrame
        self.anchor = anchor
    }
}

/// Placement of the cropped, non-transparent peek content. The panel is exactly
/// this frame; there is no transparent canvas padding.
public struct PetEdgePeekLayout: Equatable, Sendable {
    public var frame: CGRect
    /// True when the content is wider than the allowed exposed width and the
    /// view must crop its inner side instead of stretching.
    public var cropsInnerSide: Bool
    public var side: PetEdgeSide

    public init(frame: CGRect, cropsInnerSide: Bool, side: PetEdgeSide) {
        self.frame = frame
        self.cropsInnerSide = cropsInnerSide
        self.side = side
    }
}

/// Speech and task bubble placement for the peek state. Either frame may be
/// nil when its content does not fit; a visible panel is never zero-height.
public struct PetEdgeBubbleStack: Equatable, Sendable {
    public var speechFrame: CGRect?
    public var taskFrame: CGRect?
    public var below: Bool

    public init(speechFrame: CGRect?, taskFrame: CGRect?, below: Bool) {
        self.speechFrame = speechFrame
        self.taskFrame = taskFrame
        self.below = below
    }
}

public enum PetEdgeGeometry {
    /// Default content height at pet size 70 is about 50pt.
    public static let contentHeightRatio: CGFloat = 50.0 / 70.0
    /// Default exposed width at pet size 70 is at most about 44pt.
    public static let maxContentWidthRatio: CGFloat = 44.0 / 70.0
    /// Tolerance for matching adjacent display frames in points.
    public static let seamTolerance: CGFloat = 0.75

    /// Release near or through an outer edge tucks while part of the pet still
    /// overlaps usable screen space. `snapDistance` limits attraction from the
    /// inside, not outward drag distance. Fully outside pets (or a centre outside
    /// vertically) still use nearest-screen recovery rather than hiding.
    public static func snap(petFrame: CGRect, screens: [PetEdgeScreen],
                            snapDistance: CGFloat) -> PetEdgeSnap? {
        guard !screens.isEmpty, snapDistance.isFinite, snapDistance >= 0,
              petFrame.width > 0, petFrame.height > 0 else { return nil }
        guard let index = nearestScreenIndex(for: petFrame, screens: screens) else { return nil }
        let screen = screens[index]
        let centerY = petFrame.midY
        guard centerY >= screen.visibleFrame.minY - 0.5,
              centerY <= screen.visibleFrame.maxY + 0.5 else { return nil }
        // Bound outward intent by a positive overlap, including a tiny visible
        // remainder. Dock-only strips and completely off-screen releases keep
        // the existing recovery path; they cannot become unbounded tuck zones.
        guard !petFrame.intersection(screen.visibleFrame).isEmpty else { return nil }

        // A seam is still a valid place to release the pet (it may cross to the
        // neighbouring display), but it is never a place to hide it.
        let leftDistance = petFrame.minX - screen.visibleFrame.minX
        let rightDistance = screen.visibleFrame.maxX - petFrame.maxX
        let candidates: [(PetEdgeSide, CGFloat)] = [
            (.left, leftDistance), (.right, rightDistance),
        ].filter { $0.1 <= snapDistance }
        guard let candidate = candidates.min(by: { abs($0.1) < abs($1.1) }) else { return nil }
        guard isOuterEdge(candidate.0, screenIndex: index, verticalBand: petFrame,
                          screens: screens) else { return nil }
        return PetEdgeSnap(side: candidate.0, screenIndex: index,
                           visibleFrame: screen.visibleFrame)
    }

    /// True when no other display shares this side of `screenIndex` in the
    /// pet's local vertical band. A display merely touching at a different
    /// height must not make the whole side non-outer.
    public static func isOuterEdge(_ side: PetEdgeSide, screenIndex: Int,
                                   verticalBand band: CGRect,
                                   screens: [PetEdgeScreen]) -> Bool {
        guard screens.indices.contains(screenIndex) else { return false }
        let screen = screens[screenIndex]
        let bandMinY = max(band.minY, screen.frame.minY)
        let bandMaxY = min(band.maxY, screen.frame.maxY)
        guard bandMaxY > bandMinY else { return false }
        for (index, other) in screens.enumerated() where index != screenIndex {
            let overlap = min(bandMaxY, other.frame.maxY) - max(bandMinY, other.frame.minY)
            guard overlap > 0.5 else { continue }
            switch side {
            case .left:
                if abs(other.frame.maxX - screen.frame.minX) <= seamTolerance { return false }
            case .right:
                if abs(other.frame.minX - screen.frame.maxX) <= seamTolerance { return false }
            }
        }
        return true
    }

    /// Nearest display by rectangle distance. Unlike `NSScreen.main`, this keeps
    /// a pet on the display it was actually next to after a monitor disappears.
    public static func nearestScreenIndex(for rect: CGRect,
                                          screens: [PetEdgeScreen]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let dx = max(0, max(screen.frame.minX - rect.maxX, rect.minX - screen.frame.maxX))
            let dy = max(0, max(screen.frame.minY - rect.maxY, rect.minY - screen.frame.maxY))
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    public static func nearestScreenIndex(for point: CGPoint,
                                          screens: [PetEdgeScreen]) -> Int? {
        nearestScreenIndex(for: CGRect(x: point.x, y: point.y, width: 0, height: 0),
                           screens: screens)
    }

    /// Restores a persisted side after relaunch or a display change.
    ///
    /// - A side that is still an outer edge on the anchor's display is kept.
    /// - A display that disappeared falls back to the nearest display.
    /// - A side that became a seam (a new display was placed there) is refused,
    ///   so the caller restores an ordinary visible pet instead of hiding it at
    ///   a seam.
    public static func restoration(side: PetEdgeSide, anchor: CGPoint,
                                   petSize: CGFloat,
                                   screens: [PetEdgeScreen]) -> PetEdgeRestoration? {
        guard !screens.isEmpty, petSize > 0, petSize.isFinite,
              anchor.x.isFinite, anchor.y.isFinite else { return nil }
        let probe = CGRect(x: anchor.x - petSize / 2, y: anchor.y,
                           width: petSize, height: petSize)
        guard let index = nearestScreenIndex(for: probe, screens: screens) else { return nil }
        let screen = screens[index]
        let maxY = max(screen.visibleFrame.minY, screen.visibleFrame.maxY - petSize)
        let y = min(max(anchor.y, screen.visibleFrame.minY), maxY)
        let restoredBand = CGRect(x: probe.minX, y: y, width: petSize, height: petSize)
        guard isOuterEdge(side, screenIndex: index, verticalBand: restoredBand,
                          screens: screens) else { return nil }
        let x = side == .left ? screen.visibleFrame.minX : screen.visibleFrame.maxX
        return PetEdgeRestoration(side: side, screenIndex: index,
                                  visibleFrame: screen.visibleFrame,
                                  anchor: CGPoint(x: x, y: y))
    }

    /// Cropped peek placement. `contentSize` is the pixel size of the alpha
    /// bounding box (not the source canvas). The result is sized in points and
    /// aligned so the body-cut edge is flush with the display edge.
    public static func peekLayout(anchor: CGPoint, petSize: CGFloat,
                                  contentSize: CGSize, visible: CGRect,
                                  side: PetEdgeSide,
                                  heightRatio: CGFloat = contentHeightRatio,
                                  maxWidthRatio: CGFloat = maxContentWidthRatio)
        -> PetEdgePeekLayout? {
        guard petSize > 0, petSize.isFinite,
              contentSize.width > 0, contentSize.height > 0,
              contentSize.width.isFinite, contentSize.height.isFinite,
              visible.width > 0, visible.height > 0 else { return nil }
        let margin: CGFloat = 4
        let availableHeight = max(1, visible.height - margin * 2)
        let height = min(petSize * max(0.1, heightRatio), availableHeight)
        let naturalWidth = height * contentSize.width / contentSize.height
        let maxWidth = max(1, petSize * max(0.1, maxWidthRatio))
        let width = min(naturalWidth, maxWidth)
        let cropsInnerSide = naturalWidth > maxWidth + 0.01
        let centerY = anchor.y + petSize / 2
        let maxY = max(visible.minY + margin, visible.maxY - margin - height)
        let y = min(max(centerY - height / 2, visible.minY + margin), maxY)
        let x = side == .left ? visible.minX : visible.maxX - width
        return PetEdgePeekLayout(frame: CGRect(x: x, y: y, width: width, height: height),
                                 cropsInnerSide: cropsInnerSide, side: side)
    }

    /// Places the speech bubble and task list as one stack, above or below the
    /// pet. Only the peek path uses this; the ordinary pet layout is untouched.
    public static func bubbleStack(petFrame: CGRect,
                                   speechSize: CGSize,
                                   taskSize: CGSize,
                                   visible: CGRect,
                                   margin: CGFloat = 8,
                                   gap: CGFloat = 6,
                                   stackGap: CGFloat = 4) -> PetEdgeBubbleStack {
        let hasSpeech = speechSize.width > 0.5 && speechSize.height > 0.5
        let hasTask = taskSize.width > 0.5 && taskSize.height > 0.5
        guard hasSpeech || hasTask else {
            return PetEdgeBubbleStack(speechFrame: nil, taskFrame: nil, below: false)
        }
        let speechHeight = hasSpeech ? max(1, speechSize.height) : 0
        let taskHeight = hasTask ? max(1, taskSize.height) : 0
        let total = speechHeight + (hasTask ? stackGap + taskHeight : 0)
        let above = max(0, visible.maxY - margin - (petFrame.maxY + gap))
        let below = max(0, (petFrame.minY - gap) - (visible.minY + margin))
        let placeBelow = above < total && (below >= total || below > above)
        let available = placeBelow ? below : above

        // Keep the speech bubble first; the scrollable task list takes the
        // remaining height. If even the speech text cannot fit naturally, clip
        // it to the available strip rather than producing a zero-height panel.
        var speechHeightUsed = min(speechHeight, max(1, available))
        var taskHeightUsed: CGFloat = 0
        if hasTask {
            taskHeightUsed = min(taskHeight, max(0, available - speechHeightUsed - stackGap))
            if taskHeightUsed < 1 {
                taskHeightUsed = 0
                // Give speech the whole strip when the task cannot be shown.
                speechHeightUsed = min(speechHeight, max(1, available))
            }
        }
        let speechWidth = hasSpeech ? min(speechSize.width, max(1, visible.width - margin * 2)) : 0
        let taskWidth = hasTask ? min(taskSize.width, max(1, visible.width - margin * 2)) : 0

        func x(for width: CGFloat) -> CGFloat {
            let maxX = max(visible.minX + margin, visible.maxX - margin - width)
            return min(max(petFrame.midX - width / 2, visible.minX + margin), maxX)
        }

        var speechFrame: CGRect?
        var taskFrame: CGRect?
        if placeBelow {
            let speechTop = petFrame.minY - gap
            let speechY = speechTop - speechHeightUsed
            if hasSpeech {
                speechFrame = CGRect(x: x(for: speechWidth), y: speechY,
                                     width: speechWidth, height: speechHeightUsed)
            }
            if hasTask, taskHeightUsed > 0 {
                let taskY = speechY - stackGap - taskHeightUsed
                taskFrame = CGRect(x: x(for: taskWidth), y: taskY,
                                   width: taskWidth, height: taskHeightUsed)
            }
        } else {
            let speechY = petFrame.maxY + gap
            let taskY = speechY + speechHeightUsed + stackGap
            if hasSpeech {
                speechFrame = CGRect(x: x(for: speechWidth), y: speechY,
                                     width: speechWidth, height: speechHeightUsed)
            }
            if hasTask, taskHeightUsed > 0 {
                let maxTaskY = visible.maxY - margin - taskHeightUsed
                taskFrame = CGRect(x: x(for: taskWidth), y: min(taskY, maxTaskY),
                                   width: taskWidth, height: taskHeightUsed)
            }
        }
        return PetEdgeBubbleStack(speechFrame: speechFrame, taskFrame: taskFrame,
                                  below: placeBelow)
    }
}
