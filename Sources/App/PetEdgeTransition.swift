import AppKit
import AVFoundation
import QuartzCore
import AgentPetCore

/// Snapshot of the visible pet content. For a movie pet the controller uses an
/// off-main actual-frame sample; a short drag or not-ready movie falls back to
/// the visible poster/static capture. `frame` is alpha-cropped screen content,
/// not the full movie canvas.
struct PetEdgeSnapshot: @unchecked Sendable {
    let image: CGImage
    var frame: NSRect
    struct VideoSource: Sendable {
        let identity: PetVideoFrameIdentity
        /// Alpha crop expressed in the movie canvas, independent of its screen.
        let unitRect: NSRect
        let mediaTime: Double
    }
    var videoSource: VideoSource? = nil
}

enum PetEdgeSnapshotter {
    /// Synchronous fallback for a short drag or a movie whose frame is not
    /// ready: captures the visible poster/static sprite from the body panel.
    /// It never samples a movie synchronously on the main thread.
    @MainActor
    static func captureStatic(model: PetWindowModel, dragSession: UInt64? = nil) -> PetEdgeSnapshot? {
        if let video = videoView(model: model) {
            guard matches(video, dragSession: dragSession) else { return nil }
            if video.isPosterVisible, let image = video.posterImage, let frame = video.movieScreenFrame {
                return crop(image: image, frame: frame)
            }
        }
        guard let body = model.petBodyView, let window = body.window,
              let content = window.contentView else { return nil }
        let rectInWindow = body.convert(body.bounds, to: nil)
        let rectInContent = content.convert(rectInWindow, from: nil)
        let frame = window.convertToScreen(rectInWindow)
        guard let snapshot = PetBubbleSnapshot.capture(view: content, rect: rectInContent, frame: frame) else {
            return nil
        }
        return Self.crop(image: snapshot.image, frame: frame)
    }

    /// Validate the actual configured movie, not the model's requested state:
    /// SwiftUI may not yet have applied a drag selection in this run-loop turn.
    @MainActor
    static func matches(_ video: PetVideoNSView, dragSession: UInt64?) -> Bool {
        guard let dragSession else { return true }
        return video.frameIdentity?.selectionKey == "drag"
            && video.frameIdentity?.dragSession == dragSession
    }

    @MainActor
    static func videoView(model: PetWindowModel) -> PetVideoNSView? {
        guard let body = model.petBodyView else { return nil }
        return findVideoView(in: body) ?? body.window?.contentView.flatMap(findVideoView)
    }

    /// A sample can survive window movement, but never a clip/token/session
    /// change. Re-evaluate the canvas and crop at consumption time (mouse-up).
    @MainActor
    static func rebased(_ snapshot: PetEdgeSnapshot?, model: PetWindowModel,
                        dragSession: UInt64) -> PetEdgeSnapshot? {
        guard let snapshot, let source = snapshot.videoSource,
              let video = videoView(model: model), matches(video, dragSession: dragSession),
              let current = video.currentSamplingPayload(), current.identity == source.identity,
              abs(current.time.seconds - source.mediaTime) <= 0.35 else { return nil }
        let u = source.unitRect, canvas = current.frame
        var result = snapshot
        result.frame = NSRect(x: canvas.minX + u.minX * canvas.width,
                              y: canvas.minY + u.minY * canvas.height,
                              width: u.width * canvas.width, height: u.height * canvas.height)
        return result
    }

    /// Off-main sampling is serialized and reuses the asset generator. A late
    /// decode from an old selection is rejected again when it reaches the UI.
    @MainActor
    static func sampleAsync(model: PetWindowModel, dragSession: UInt64? = nil,
                            completion: @escaping (PetEdgeSnapshot?) -> Void) -> Task<Void, Never>? {
        guard let video = videoView(model: model), matches(video, dragSession: dragSession),
              let payload = video.currentSamplingPayload() else {
            completion(nil)
            return nil
        }
        return Task { @MainActor [weak video] in
            let snapshot = await movieSampler.sample(identity: payload.identity,
                                                       time: payload.time, canvas: payload.frame)
            guard !Task.isCancelled, video?.frameIdentity == payload.identity else {
                completion(nil)
                return
            }
            completion(snapshot)
        }
    }

    /// The current drag's poster gives an immediate content target without
    /// sampling an idle player or synchronously decoding a movie.
    @MainActor
    static func dragTarget(model: PetWindowModel, dragSession: UInt64) -> NSRect? {
        guard let video = videoView(model: model), matches(video, dragSession: dragSession),
              let image = video.posterImage, let frame = video.movieScreenFrame else { return nil }
        return crop(image: image, frame: frame)?.frame
    }

    @MainActor
    static func dragPoster(model: PetWindowModel, dragSession: UInt64) -> PetEdgeSnapshot? {
        guard let video = videoView(model: model), matches(video, dragSession: dragSession),
              let image = video.posterImage, let frame = video.movieScreenFrame else { return nil }
        return crop(image: image, frame: frame)
    }

    nonisolated static func orientedPeek(_ image: CGImage, side: PetEdgeSide) -> CGImage? {
        guard side == .left else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: CGFloat(image.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static let movieSampler = PetEdgeMovieSampler()

    /// Crops to the non-transparent content and converts the top-left alpha
    /// bounds into a bottom-left screen rectangle. Both collapse source and
    /// peek target then share the same visible content geometry.
    nonisolated static func crop(image: CGImage, frame: NSRect) -> PetEdgeSnapshot? {
        guard image.width > 0, image.height > 0, frame.width > 0, frame.height > 0,
              let bounds = EdgePeekAsset.alphaBounds(image),
              let cropped = image.cropping(to: bounds) else { return nil }
        let scaleX = frame.width / CGFloat(image.width)
        let scaleY = frame.height / CGFloat(image.height)
        let contentFrame = NSRect(
            x: frame.minX + bounds.minX * scaleX,
            y: frame.maxY - bounds.maxY * scaleY,
            width: bounds.width * scaleX,
            height: bounds.height * scaleY)
        return PetEdgeSnapshot(image: cropped, frame: contentFrame)
    }

    @MainActor
    private static func findVideoView(in view: NSView) -> PetVideoNSView? {
        if let video = view as? PetVideoNSView { return video }
        for child in view.subviews {
            if let found = findVideoView(in: child) { return found }
        }
        return nil
    }
}

/// A short, interruptible edge funnel. The mesh is a continuous set of vertical
/// source slices whose boundaries are pulled towards the peek rectangle, with
/// the display-edge side retaining its height/position slightly longer than the
/// inner side. It intentionally does not reuse the bubble Genie's vertical
/// pull-to-a-point shape.
@MainActor
final class PetEdgeTransition {
    static let collapseDuration: TimeInterval = 0.22
    static let expandDuration: TimeInterval = 0.16

    private var panel: NSPanel?
    private var collapseStartSnapshot: PetEdgeSnapshot?
    private var childPanel: NSPanel?
    private var expansionStartSnapshot: PetEdgeSnapshot?
    private var expansionStartPanelOrigin: NSPoint = .zero
    private weak var expansionBodyProxy: CALayer?
    private var isCrossfading = false
    private var isHandingOff = false
    private var liveSnapshotProvider: (() -> PetEdgeSnapshot?)?
    private weak var expandingParent: NSPanel?
    private weak var expandingBodyLayer: CALayer?
    private var token = UUID()
    private var expandToken = UUID()

    var interactivePanel: NSPanel? { panel }
    var expandPanel: NSPanel? { childPanel }

    private static func meshColumns(from: NSRect, to: NSRect, scale: CGFloat) -> Int {
        // Subpixel-wide clipped/antialiased layers lose coverage when rendered,
        // especially at a narrow peek on a 1x display. Keep each endpoint's
        // source columns at least one device pixel wide, up to the usual 64.
        let pixels = min(from.width, to.width) * max(1, scale)
        guard pixels.isFinite, pixels > 0 else { return 1 }
        return max(1, Int(min(64, pixels.rounded(.down))))
    }

    static func edgeFrames(from: NSRect, to: NSRect, side: PetEdgeSide,
                           progress: CGFloat, count: Int = 64) -> [NSRect] {
        guard count > 0, from.width > 0, from.height > 0,
              to.width > 0, to.height > 0 else { return [] }
        let p = min(max(progress, 0), 1)
        func edgeWeight(_ u: CGFloat) -> CGFloat { side == .right ? u : 1 - u }
        func eased(_ value: CGFloat, weight: CGFloat, innerLag: CGFloat) -> CGFloat {
            guard value > 0 else { return 0 }
            guard value < 1 else { return 1 }
            // All slices reach the target at progress 1; the inner side starts
            // moving earlier, so the body-cut edge stays anchored longer.
            let exponent = 1 + innerLag * (1 - weight)
            return 1 - pow(1 - value, exponent)
        }

        var boundaries: [CGFloat] = []
        boundaries.reserveCapacity(count + 1)
        for index in 0...count {
            let u = CGFloat(index) / CGFloat(count)
            let weight = edgeWeight(u)
            let horizontal = eased(p, weight: weight, innerLag: 0.60)
            let sourceX = from.minX + u * from.width
            let targetX = to.minX + u * to.width
            boundaries.append(sourceX + (targetX - sourceX) * horizontal)
        }
        // Floating-point round-off must not reorder slices.
        for index in 1...count where boundaries[index] < boundaries[index - 1] {
            boundaries[index] = boundaries[index - 1]
        }
        var frames: [NSRect] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let x0 = boundaries[index], x1 = boundaries[index + 1]
            let u = (CGFloat(index) + 0.5) / CGFloat(count)
            let weight = edgeWeight(u)
            let vertical = eased(p, weight: weight, innerLag: 0.35)
            let y0 = from.minY + (to.minY - from.minY) * vertical
            let y1 = from.maxY + (to.maxY - from.maxY) * vertical
            frames.append(NSRect(x: min(x0, x1), y: min(y0, y1),
                                 width: max(abs(x1 - x0), 0.01),
                                 height: max(abs(y1 - y0) + 0.4, 0.01)))
        }
        return frames
    }

    /// Collapse (`collapsing == true`) runs 0→1; expand runs 1→0. A collapse
    /// overlay can accept mouse events so a click/drag on the visible funnel
    /// cancels it. `holdAtEnd` lets the controller crossfade the final mesh into
    /// the static peek before the overlay is removed.
    func animate(snapshot: PetEdgeSnapshot, to target: NSRect, side: PetEdgeSide,
                 collapsing: Bool, duration: TimeInterval,
                 interactive: Bool = false, holdAtEnd: Bool = false,
                 completion: @escaping () -> Void) {
        guard duration > 0.001 else {
            completion()
            return
        }
        cancel()
        let steps = 20
        let scale = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: target.midX, y: target.midY))
        }?.backingScaleFactor ?? 1
        let columns = Self.meshColumns(from: snapshot.frame, to: target, scale: scale)
        let meshFrames = (0...steps).map { step -> [NSRect] in
            let p = CGFloat(step) / CGFloat(steps)
            return Self.edgeFrames(from: snapshot.frame, to: target, side: side,
                                   progress: collapsing ? p : 1 - p, count: columns)
        }
        guard let finalFrames = meshFrames.last, !finalFrames.isEmpty else {
            completion()
            return
        }
        let canvasFrame = meshFrames.flatMap { $0 }.reduce(snapshot.frame) { $0.union($1) }
            .insetBy(dx: -8, dy: -8)
        let overlay = NSPanel(contentRect: canvasFrame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.level = .floating
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.ignoresMouseEvents = !interactive
        overlay.hasShadow = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let canvas = NSView(frame: NSRect(origin: .zero, size: canvasFrame.size))
        canvas.wantsLayer = true
        overlay.contentView = canvas
        let count = finalFrames.count
        let sourceColumnWidth = snapshot.frame.width / CGFloat(count)
        let sourceColumnHeight = snapshot.frame.height
        let currentToken = token
        panel = overlay
        collapseStartSnapshot = snapshot

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak overlay] in
            Task { @MainActor in
                guard let self, self.token == currentToken else { return }
                if holdAtEnd {
                    completion()
                    return
                }
                overlay?.orderOut(nil)
                self.panel = nil
                completion()
            }
        }
        let keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        for index in 0..<count {
            let strip = CALayer()
            strip.contents = snapshot.image
            strip.contentsRect = CGRect(x: CGFloat(index) / CGFloat(count), y: 0,
                                        width: 1 / CGFloat(count), height: 1)
            strip.bounds = NSRect(x: 0, y: 0, width: sourceColumnWidth, height: sourceColumnHeight)
            strip.contentsGravity = .resize
            strip.contentsScale = CGFloat(snapshot.image.width) / max(1, snapshot.frame.width)
            strip.allowsEdgeAntialiasing = true
            strip.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge]
            strip.masksToBounds = true
            let frames = meshFrames.map { $0[index] }
            strip.position = NSPoint(x: frames.last!.midX - canvasFrame.minX,
                                     y: frames.last!.midY - canvasFrame.minY)
            strip.transform = CATransform3DMakeScale(
                frames.last!.width / max(0.01, sourceColumnWidth),
                (frames.last!.height + 0.5) / max(0.01, sourceColumnHeight), 1)
            canvas.layer?.addSublayer(strip)

            let positions = frames.map {
                NSValue(point: NSPoint(x: $0.midX - canvasFrame.minX,
                                       y: $0.midY - canvasFrame.minY))
            }
            let xs = frames.map { NSNumber(value: Double($0.width / max(0.01, sourceColumnWidth))) }
            let ys = frames.map {
                NSNumber(value: Double(($0.height + 0.5) / max(0.01, sourceColumnHeight)))
            }
            let animations = [("position", positions as [Any]),
                              ("transform.scale.x", xs as [Any]),
                              ("transform.scale.y", ys as [Any])].map { key, values -> CAKeyframeAnimation in
                let animation = CAKeyframeAnimation(keyPath: key)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.calculationMode = .linear
                return animation
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: collapsing ? .easeIn : .easeOut)
            strip.add(group, forKey: "petEdgeFunnel")
        }
        overlay.orderFront(nil)
        CATransaction.commit()
    }

    /// Until SwiftUI configures the requested drag, retain only the visible
    /// peek on a child panel. Movement never waits for rendering or decoding.
    func holdExpansion(snapshot: PetEdgeSnapshot, in parent: NSPanel) {
        cancelExpand()
        let overlay = NSPanel(contentRect: snapshot.frame,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSView(frame: NSRect(origin: .zero, size: snapshot.frame.size))
        content.wantsLayer = true
        content.layer?.contents = snapshot.image
        content.layer?.contentsGravity = .resize
        overlay.contentView = content
        parent.contentView?.wantsLayer = true
        expandingBodyLayer = parent.contentView?.layer
        CATransaction.begin(); CATransaction.setDisableActions(true)
        expandingBodyLayer?.opacity = 0
        CATransaction.commit()
        parent.addChildWindow(overlay, ordered: .above)
        childPanel = overlay
        expansionStartSnapshot = snapshot
        expansionStartPanelOrigin = overlay.frame.origin
        overlay.orderFront(nil)
    }

    func visibleCollapseSnapshot() -> PetEdgeSnapshot? {
        guard let panel else { return nil }
        // Before the first display transaction, model layers already contain
        // their final positions. Use the real start image, never that endpoint.
        guard let presentation = panel.contentView?.layer?.presentation() else {
            return collapseStartSnapshot
        }
        return Self.capture(presentation, in: panel)
    }

    /// Capture the currently visible funnel before a fast mouse-up cancels it.
    /// Small presentation layers are rendered directly; no movie decode occurs.
    func visibleExpansionSnapshot() -> PetEdgeSnapshot? {
        guard let panel = childPanel, let layer = panel.contentView?.layer else { return nil }
        guard let presentation = layer.presentation() else {
            guard var source = expansionStartSnapshot else { return nil }
            source.frame = source.frame.offsetBy(dx: panel.frame.minX - expansionStartPanelOrigin.x,
                                                dy: panel.frame.minY - expansionStartPanelOrigin.y)
            return source
        }
        let overlay = Self.capture(presentation, in: panel)
        guard isHandingOff, let parent = expandingParent,
              let bodyLayer = expandingBodyLayer else { return overlay }
        let opacity = CGFloat(bodyLayer.presentation()?.opacity ?? bodyLayer.opacity)
        let live: PetEdgeSnapshot?
        if let provider = liveSnapshotProvider {
            // AVPlayerLayer is not in a normal CALayer render. Reuse the newest
            // identity-validated decoded sample, rebased to the current window.
            live = provider().flatMap { Self.applyingAlpha(opacity, to: $0) }
                ?? Self.capture(bodyLayer.presentation() ?? bodyLayer, in: parent)
        } else {
            live = Self.capture(bodyLayer.presentation() ?? bodyLayer, in: parent)
        }
        // Never label a faint overlay as the complete visible scene when the
        // running movie cannot be sampled. The controller then declines edge
        // collapse and keeps the ordinary pet visible instead of collapsing a
        // mesh-only source. This is the same safe missing-snapshot contract as
        // normal video release.
        guard let live else { return nil }
        return Self.composite(live, overlay, scale: panel.backingScaleFactor)
    }

    private static func applyingAlpha(_ alpha: CGFloat, to snapshot: PetEdgeSnapshot) -> PetEdgeSnapshot? {
        guard let context = CGContext(data: nil, width: snapshot.image.width, height: snapshot.image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setAlpha(alpha)
        context.draw(snapshot.image, in: CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height))
        guard let image = context.makeImage() else { return nil }
        return PetEdgeSnapshot(image: image, frame: snapshot.frame)
    }

    private static func composite(_ back: PetEdgeSnapshot?, _ front: PetEdgeSnapshot?, scale: CGFloat) -> PetEdgeSnapshot? {
        guard let back else { return front }
        guard let front else { return back }
        let frame = back.frame.union(front.frame)
        guard let context = CGContext(data: nil, width: Int(ceil(frame.width * scale)),
            height: Int(ceil(frame.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        for snapshot in [back, front] {
            context.draw(snapshot.image, in: snapshot.frame.offsetBy(dx: -frame.minX, dy: -frame.minY))
        }
        guard let image = context.makeImage() else { return nil }
        return PetEdgeSnapshotter.crop(image: image, frame: frame)
    }

    /// The rendered transition is the source of truth. A new decoded drag
    /// sample replaces the body proxy while both fade layers stay in one panel.
    func updateExpansionBody(_ snapshot: PetEdgeSnapshot) {
        guard let panel = childPanel, let layer = expansionBodyProxy else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contents = snapshot.image
        layer.frame = snapshot.frame.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        CATransaction.commit()
    }

    private static func capture(_ layer: CALayer, in panel: NSPanel) -> PetEdgeSnapshot? {
        let frame = panel.frame, scale = panel.backingScaleFactor
        guard frame.width > 0, frame.height > 0,
              let context = CGContext(data: nil, width: Int(ceil(frame.width * scale)),
                height: Int(ceil(frame.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setAlpha(panel.alphaValue)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return PetEdgeSnapshotter.crop(image: image, frame: frame)
    }

    static func expansionBodyOpacity(progress: CGFloat) -> CGFloat {
        min(1, max(0, (progress - 0.75) / 0.25))
    }

    /// Expand uses a child overlay of the body window, so it moves with the
    /// cursor while the underlying movie plays from frame 0. During the short
    /// transition all visible pixels (body proxy and mesh) share this one panel,
    /// so an interruption captures exactly what was shown. The proxy starts at
    /// the configured drag poster and receives validated asynchronous frames.
    func animateExpand(snapshot: PetEdgeSnapshot, to target: NSRect, side: PetEdgeSide,
                       in parent: NSPanel, duration: TimeInterval,
                       body: PetEdgeSnapshot? = nil, liveSnapshot: (() -> PetEdgeSnapshot?)? = nil,
                       completion: @escaping () -> Void) {
        guard duration > 0.001 else {
            completion()
            return
        }
        cancelExpand()
        // Capture static test/sprite layers only while the parent is unmasked.
        // Movie callers provide the configured clip's poster/decoded frame;
        // CALayer.render does not reliably include AVPlayerLayer pixels.
        let body = body ?? parent.contentView?.layer.flatMap { Self.capture($0, in: parent) }

        let steps = 16
        let columns = Self.meshColumns(from: snapshot.frame, to: target, scale: parent.backingScaleFactor)
        let meshFrames = (0...steps).map { step -> [NSRect] in
            Self.edgeFrames(from: snapshot.frame, to: target, side: side,
                            progress: CGFloat(step) / CGFloat(steps), count: columns)
        }
        guard let finalFrames = meshFrames.last, !finalFrames.isEmpty else {
            completion()
            return
        }
        let canvasFrame = meshFrames.flatMap { $0 }.reduce(snapshot.frame) { $0.union($1) }
            .union(parent.frame).union(body?.frame ?? target).insetBy(dx: -8, dy: -8)
        let overlay = NSPanel(contentRect: canvasFrame,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.level = .floating
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.ignoresMouseEvents = true
        overlay.hasShadow = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let canvas = NSView(frame: NSRect(origin: .zero, size: canvasFrame.size))
        canvas.wantsLayer = true
        overlay.contentView = canvas
        parent.addChildWindow(overlay, ordered: .above)
        childPanel = overlay
        expansionStartSnapshot = snapshot
        expansionStartPanelOrigin = overlay.frame.origin
        let count = finalFrames.count
        let sourceColumnWidth = snapshot.frame.width / CGFloat(count)
        let sourceColumnHeight = snapshot.frame.height
        expandingBodyLayer = parent.contentView?.layer
        expandingParent = parent
        liveSnapshotProvider = liveSnapshot
        let currentToken = expandToken
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak overlay] in
            Task { @MainActor in
                guard let self, self.expandToken == currentToken else { return }
                self.beginLiveHandoff(parent: parent, overlay: overlay,
                                      currentToken: currentToken, completion: completion)
            }
        }
        let keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        // The live movie's clock keeps running behind this visual compositor.
        // Reveal its sampled body inside the same panel as the mesh, rather
        // than revealing an uncapturable AVPlayerLayer in another window.
        expandingBodyLayer?.opacity = 0
        if let body {
            let bodyLayer = CALayer()
            bodyLayer.name = "petEdgeBodyProxy"
            bodyLayer.contents = body.image
            bodyLayer.contentsGravity = .resize
            bodyLayer.frame = body.frame.offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY)
            bodyLayer.opacity = 1
            canvas.layer?.addSublayer(bodyLayer)
            expansionBodyProxy = bodyLayer
            let reveal = CAKeyframeAnimation(keyPath: "opacity")
            reveal.values = (0...steps).map {
                NSNumber(value: Double(Self.expansionBodyOpacity(progress: CGFloat($0) / CGFloat(steps))))
            }
            reveal.keyTimes = keyTimes
            reveal.duration = duration
            reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bodyLayer.add(reveal, forKey: "petEdgeBodyReveal")
        }
        for index in 0..<count {
            let strip = CALayer()
            strip.contents = snapshot.image
            strip.contentsRect = CGRect(x: CGFloat(index) / CGFloat(count), y: 0,
                                        width: 1 / CGFloat(count), height: 1)
            strip.bounds = NSRect(x: 0, y: 0, width: sourceColumnWidth, height: sourceColumnHeight)
            strip.contentsGravity = .resize
            strip.contentsScale = CGFloat(snapshot.image.width) / max(1, snapshot.frame.width)
            strip.allowsEdgeAntialiasing = true
            strip.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge]
            strip.masksToBounds = true
            let frames = meshFrames.map { $0[index] }
            strip.position = NSPoint(x: frames.last!.midX - canvasFrame.minX,
                                     y: frames.last!.midY - canvasFrame.minY)
            strip.opacity = 0
            strip.transform = CATransform3DMakeScale(
                frames.last!.width / max(0.01, sourceColumnWidth),
                (frames.last!.height + 0.5) / max(0.01, sourceColumnHeight), 1)
            canvas.layer?.addSublayer(strip)
            let positions = frames.map {
                NSValue(point: NSPoint(x: $0.midX - canvasFrame.minX,
                                       y: $0.midY - canvasFrame.minY))
            }
            let xs = frames.map { NSNumber(value: Double($0.width / max(0.01, sourceColumnWidth))) }
            let ys = frames.map {
                NSNumber(value: Double(($0.height + 0.5) / max(0.01, sourceColumnHeight)))
            }
            let opacity = (0...steps).map { step -> NSNumber in
                let p = CGFloat(step) / CGFloat(steps)
                // Stay on the peek-derived mesh until the last quarter, then
                // crossfade to the live body only at the matching target size.
                let fade = body == nil ? 0 : Self.expansionBodyOpacity(progress: p)
                return NSNumber(value: Double(1 - fade))
            }
            let animations = [("position", positions as [Any]),
                              ("transform.scale.x", xs as [Any]),
                              ("transform.scale.y", ys as [Any]),
                              ("opacity", opacity as [Any])].map { key, values -> CAKeyframeAnimation in
                let animation = CAKeyframeAnimation(keyPath: key)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.calculationMode = .linear
                return animation
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            strip.add(group, forKey: "petEdgeExpand")
        }
        overlay.orderFront(nil)
        CATransaction.commit()
    }

    /// A distinct, cancellable handoff gives the real running movie time to
    /// replace a poster/older decoded proxy without a hard frame swap. The same
    /// path handles no-proxy timeouts: expanded peek mesh fades into live body.
    private func beginLiveHandoff(parent: NSPanel, overlay: NSPanel?, currentToken: UUID,
                                  completion: @escaping () -> Void) {
        guard let overlay, childPanel === overlay, let root = overlay.contentView?.layer,
              let body = expandingBodyLayer else { restoreExpandingBody(); completion(); return }
        isHandingOff = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak overlay] in
            Task { @MainActor in
                guard let self, self.expandToken == currentToken else { return }
                self.restoreExpandingBody()
                if let overlay { parent.removeChildWindow(overlay); overlay.orderOut(nil) }
                self.childPanel = nil
                self.expansionBodyProxy = nil
                self.expansionStartSnapshot = nil
                self.liveSnapshotProvider = nil
                self.expandingParent = nil
                self.isHandingOff = false
                completion()
            }
        }
        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = 0; reveal.toValue = 1; reveal.duration = 0.08
        body.opacity = 1
        body.add(reveal, forKey: "petEdgeLiveHandoff")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.08
        root.opacity = 0
        root.add(fade, forKey: "petEdgeProxyHandoff")
        CATransaction.commit()
    }

    /// Both sides of the collapse crossfade live in this panel. Capturing its
    /// presentation tree therefore includes the peek, mesh, and their opacities.
    func crossfade(to peek: PetEdgeSnapshot, duration: TimeInterval, completion: @escaping () -> Void) {
        guard !isCrossfading else { return }
        guard let panel, let root = panel.contentView?.layer else { completion(); return }
        isCrossfading = true
        collapseStartSnapshot = Self.capture(root.presentation() ?? root, in: panel)
        let mesh = root.sublayers ?? []
        let peekLayer = CALayer()
        peekLayer.contents = peek.image
        peekLayer.contentsGravity = .resize
        peekLayer.frame = peek.frame.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        let currentToken = token
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, self.token == currentToken else { return }
                completion() // Show the identical static peek before removing this panel.
                panel?.orderOut(nil)
                if self.panel === panel { self.panel = nil }
                self.isCrossfading = false
            }
        }
        for layer in mesh {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = 0
            fade.duration = max(0.01, duration)
            layer.opacity = 0
            layer.add(fade, forKey: "petEdgePeekOut")
        }
        root.addSublayer(peekLayer)
        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = 0; reveal.toValue = 1
        reveal.duration = max(0.01, duration)
        peekLayer.opacity = 1
        peekLayer.add(reveal, forKey: "petEdgePeekIn")
        CATransaction.commit()
    }

    /// Fades the final collapse mesh into the peek panel, removing the overlay
    /// only after the visible content has been replaced continuously.
    func fadeOut(duration: TimeInterval, completion: @escaping () -> Void) {
        guard let panel else {
            completion()
            return
        }
        let currentToken = token
        let box = EdgeCompletionBox(completion)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = max(0.01, duration)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, self.token == currentToken else { return }
                panel?.orderOut(nil)
                if self.panel === panel { self.panel = nil }
                box.run()
            }
        }
    }

    private func restoreExpandingBody() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        expandingBodyLayer?.removeAnimation(forKey: "petEdgeBodyReveal")
        expandingBodyLayer?.removeAnimation(forKey: "petEdgeLiveHandoff")
        expandingBodyLayer?.opacity = 1
        CATransaction.commit()
        expandingBodyLayer = nil
    }

    private func cancelExpand() {
        isHandingOff = false
        liveSnapshotProvider = nil
        expandingParent = nil
        restoreExpandingBody()
        expansionBodyProxy = nil
        expansionStartSnapshot = nil
        expandToken = UUID()
        guard let childPanel else { return }
        childPanel.parent?.removeChildWindow(childPanel)
        childPanel.orderOut(nil)
        self.childPanel = nil
    }

    func cancel() {
        isHandingOff = false
        liveSnapshotProvider = nil
        expandingParent = nil
        restoreExpandingBody()
        isCrossfading = false
        expansionBodyProxy = nil
        expansionStartSnapshot = nil
        token = UUID()
        expandToken = UUID()
        panel?.orderOut(nil)
        panel = nil
        collapseStartSnapshot = nil
        if let childPanel {
            childPanel.parent?.removeChildWindow(childPanel)
            childPanel.orderOut(nil)
        }
        childPanel = nil
    }
}

/// Carries a main-actor completion through AppKit's @Sendable animation callback.
private final class EdgeCompletionBox: @unchecked Sendable {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// AVAssetImageGenerator stays on this serial background executor. The one-entry
/// cache bounds decoded-media lifetime even when several pets are dragged.
private actor PetEdgeMovieSampler {
    private var url: URL?
    private var generator: AVAssetImageGenerator?
    func sample(identity: PetVideoFrameIdentity, time: CMTime, canvas: NSRect) -> PetEdgeSnapshot? {
        let url = identity.url
        if self.url != url {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            self.generator = generator
            self.url = url
        }
        guard !Task.isCancelled, let image = try? generator?.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        guard var snapshot = PetEdgeSnapshotter.crop(image: image, frame: canvas) else { return nil }
        let frame = snapshot.frame
        snapshot.videoSource = .init(identity: identity,
            unitRect: NSRect(x: (frame.minX - canvas.minX) / canvas.width,
                             y: (frame.minY - canvas.minY) / canvas.height,
                             width: frame.width / canvas.width, height: frame.height / canvas.height),
            mediaTime: time.seconds)
        return snapshot
    }
}
