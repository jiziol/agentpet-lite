import AppKit
import QuartzCore
import SwiftUI

struct PetBubbleSnapshot {
    let image: CGImage
    let frame: NSRect

    @MainActor static func capture(view: NSView, rect: NSRect, frame: NSRect) -> Self? {
        guard rect.width > 0, rect.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: rect, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        return Self(image: image, frame: frame)
    }
    @MainActor static func messages(model: PetWindowModel, frame: NSRect) -> Self? {
        let host = NSHostingView(rootView: PetMessagesView(model: model, expanded: model.messageListExpanded)
            .environment(\.locale, AppLanguage.shared.locale)
            .environment(\.animationsEnabled, false))
        host.setFrameSize(frame.size)
        host.layoutSubtreeIfNeeded()
        return capture(view: host, rect: host.bounds, frame: frame)
    }

}

/// One transient snapshot animation, shared by status and message bubbles.
@MainActor
final class PetGenieTransition {
    private var transitionPanel: NSPanel?
    private var transitionToken = UUID()
    /// A horizontal mesh follows the curved sides of a funnel. First the
    /// near edge bends towards the pet, then the far edge is pulled into it.
    /// Only the snapshot is deformed; the live status window stays fixed.
    static func genieStrips(card: NSRect, pet: NSRect?, progress: CGFloat, count: Int = 256) -> [NSRect] {
        guard count > 0, card.width > 0, card.height > 0 else { return [] }
        let target = pet.map { NSPoint(x: $0.midX, y: $0.midY) }
            ?? NSPoint(x: card.midX, y: card.minY)
        let p = min(max(progress, 0), 1)
        func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
        let bend = ease(min(p / 0.45, 1))
        let pull = ease(max((p - 0.45) / 0.55, 0))
        let towardsTop = target.y > card.midY
        let originalNear = towardsTop ? card.maxY : card.minY
        let originalFar = towardsTop ? card.minY : card.maxY
        let nearY = originalNear + (target.y - originalNear) * bend
        let farY = originalFar + (target.y - originalFar) * pull
        let nearX = card.midX + (target.x - card.midX) * bend
        let farX = card.midX + (target.x - card.midX) * pull
        let farWidth = card.width * max(1 - pull, 0.002)
        let nearWidth = card.width * max((1 - bend + bend * 0.025) * (1 - pull), 0.002)
        return (0..<count).map { index in
            // Source slices are always bottom to top, even with a pet above.
            let low = CGFloat(index) / CGFloat(count)
            let high = CGFloat(index + 1) / CGFloat(count)
            let v = towardsTop ? 1 - (low + high) / 2 : (low + high) / 2
            let curve = ease(v)
            let width = nearWidth + (farWidth - nearWidth) * curve
            let centerX = nearX + (farX - nearX) * curve
            let y0 = nearY + (farY - nearY) * (towardsTop ? 1 - low : low)
            let y1 = nearY + (farY - nearY) * (towardsTop ? 1 - high : high)
            return NSRect(x: centerX - width / 2, y: min(y0, y1),
                          width: width, height: max(abs(y1 - y0), 0.01))
        }
    }

    static func snapshotLayers(image: CGImage, cardSize: NSSize, frames: [NSRect], origin: NSPoint) -> [CALayer] {
        guard !frames.isEmpty else { return [] }
        let count = frames.count
        let sourceHeight = cardSize.height / CGFloat(count)
        return frames.enumerated().map { index, frame in
            let strip = CALayer()
            strip.contents = image
            strip.contentsRect = CGRect(x: 0, y: CGFloat(index) / CGFloat(count),
                                        width: 1, height: 1 / CGFloat(count))
            strip.bounds = NSRect(x: 0, y: 0, width: cardSize.width, height: sourceHeight)
            strip.contentsGravity = .resize
            strip.contentsScale = CGFloat(image.width) / cardSize.width
            strip.allowsEdgeAntialiasing = true
            strip.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge]
            strip.position = NSPoint(x: frame.midX - origin.x, y: frame.midY - origin.y)
            // Subpixel overlap avoids cracks between adjacent snapshot strips.
            strip.transform = CATransform3DMakeScale(frame.width / cardSize.width,
                                                     (frame.height + 0.4) / sourceHeight, 1)
            return strip
        }
    }

    func cancel() {
        transitionToken = UUID()
        transitionPanel?.orderOut(nil)
        transitionPanel = nil
    }

    func animate(_ snapshot: PetBubbleSnapshot, pet: NSRect?, opening: Bool, duration: TimeInterval = 0.5, completion: @escaping () -> Void) {
        cancel()
        let steps = 24
        let meshFrames = (0...steps).map { step in
            Self.genieStrips(card: snapshot.frame, pet: pet,
                             progress: opening ? 1 - CGFloat(step) / CGFloat(steps) : CGFloat(step) / CGFloat(steps))
        }
        let canvasFrame = meshFrames.flatMap { $0 }.reduce(snapshot.frame) { $0.union($1) }.insetBy(dx: -8, dy: -8)
        let overlay = NSPanel(contentRect: canvasFrame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.level = .floating
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let canvas = NSView(frame: NSRect(origin: .zero, size: canvasFrame.size))
        canvas.wantsLayer = true
        overlay.contentView = canvas
        let sliceCount = meshFrames[0].count
        let sourceHeight = snapshot.frame.height / CGFloat(sliceCount)
        let token = transitionToken
        transitionPanel = overlay
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak overlay] in
            Task { @MainActor in
                guard let self, self.transitionToken == token else { return }
                overlay?.orderOut(nil)
                self.transitionPanel = nil
                completion()
            }
        }
        let strips = Self.snapshotLayers(image: snapshot.image, cardSize: snapshot.frame.size,
                                          frames: meshFrames.last!, origin: canvasFrame.origin)
        let keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        for (index, strip) in strips.enumerated() {
            let frames = meshFrames.map { $0[index] }
            let positions = frames.map { NSValue(point: NSPoint(x: $0.midX - canvasFrame.minX,
                                                                y: $0.midY - canvasFrame.minY)) }
            let xs = frames.map { NSNumber(value: Double($0.width / snapshot.frame.width)) }
            // Subpixel overlap avoids cracks between the snapshot strips.
            let ys = frames.map { NSNumber(value: Double(($0.height + 0.4) / sourceHeight)) }
            strip.opacity = opening ? 1 : 0
            canvas.layer?.addSublayer(strip)
            let opacity = (0...steps).map { step -> NSNumber in
                let p = opening ? 1 - CGFloat(step) / CGFloat(steps) : CGFloat(step) / CGFloat(steps)
                return NSNumber(value: Double(min((1 - p) / 0.05, 1)))
            }
            let animations = [("position", positions as [Any]), ("transform.scale.x", xs as [Any]),
                              ("transform.scale.y", ys as [Any]), ("opacity", opacity as [Any])].map { key, values -> CAKeyframeAnimation in
                let animation = CAKeyframeAnimation(keyPath: key)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.calculationMode = .linear
                return animation
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = duration
            strip.add(group, forKey: "petStatusGenie")
        }
        overlay.orderFront(nil)
        CATransaction.commit()
    }

}
