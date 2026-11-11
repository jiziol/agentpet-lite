import SwiftUI
import AppKit
import AVFoundation

struct PetVideoSpriteView: NSViewRepresentable {
    let clip: PetVideoClip
    var loop = true
    var playbackID: UInt64 = 0
    var animate = true
    var onFinished: ((UInt64) -> Void)? = nil
    var onFailure: (() -> Void)? = nil
    var selectionKey: String? = nil
    var dragSession: UInt64 = 0

    func makeNSView(context: Context) -> PetVideoNSView {
        let view = PetVideoNSView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: PetVideoNSView, context: Context) {
        view.configure(clip: clip, loop: loop, token: playbackID, animate: animate,
                       onFinished: onFinished, onFailure: onFailure,
                       selectionKey: selectionKey, dragSession: dragSession)
    }
    static func dismantleNSView(_ view: PetVideoNSView, coordinator: ()) { view.teardown() }
}

/// One current movie per visible view. No decoded-frame cache or per-frame SwiftUI updates.
struct PetVideoFrameIdentity: Equatable, Sendable {
    let url: URL
    let token: UInt64
    let selectionKey: String?
    let dragSession: UInt64
}

final class PetVideoNSView: NSView {
    private let videoLayer = AVPlayerLayer()
    private let posterLayer = CALayer()
    private var player: AVPlayer?
    private var url: URL?
    private var token: UInt64 = 0
    private var selectionKey: String?
    private var dragSession: UInt64 = 0
    private var movieSize: NSSize = .zero
    private(set) var posterImage: CGImage?
    private var epoch: UInt64 = 0
    private var loop = true
    private var animate = true
    private var observers: [NSObjectProtocol] = []
    private var readyObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var onFinished: ((UInt64) -> Void)?
    private var onFailure: (() -> Void)?
    private var failureReported = false
    private var reachedEnd = false
    /// Public AVFoundation frame sampler used by the edge transition.
    /// `cacheDisplay` does not reliably include AVPlayerLayer contents, and an
    /// item video output on this HEVC-alpha movie crashed during teardown in
    /// isolated tests. Sampling the same asset at the player's current time is
    /// public, teardown-safe and still a real frame rather than a poster.
    private var frameGenerator: AVAssetImageGenerator?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.clear.cgColor
        posterLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        layer?.addSublayer(posterLayer)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override var isOpaque: Bool { false }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        posterLayer.frame = bounds
        CATransaction.commit()
    }

    func configure(clip: PetVideoClip, loop: Bool, token: UInt64, animate: Bool,
                   onFinished: ((UInt64) -> Void)?, onFailure: (() -> Void)?,
                   selectionKey: String? = nil, dragSession: UInt64 = 0) {
        self.onFinished = onFinished
        self.onFailure = onFailure
        self.loop = loop
        let changed = url != clip.url || self.token != token || self.dragSession != dragSession
        let visibilityChanged = self.animate != animate
        self.animate = animate
        if changed {
            teardown()
            self.token = token
            self.dragSession = dragSession
            url = clip.url
            failureReported = false
            reachedEnd = false
            posterImage = clip.poster?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            posterLayer.contents = posterImage
            posterLayer.isHidden = false
            let item = AVPlayerItem(url: clip.url)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            frameGenerator = generator
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = true
            newPlayer.actionAtItemEnd = .pause
            player = newPlayer
            videoLayer.player = newPlayer
            let generation = epoch
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.ended(epoch: generation) }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.failed(epoch: generation) }
            })
            readyObservation = videoLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == generation, self.videoLayer.isReadyForDisplay else { return }
                    self.posterLayer.isHidden = true
                }
            }
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self] in self?.failed(epoch: generation) }
            }
        }
        self.selectionKey = selectionKey
        movieSize = NSSize(width: clip.width, height: clip.height)
        if changed || visibilityChanged {
            if animate {
                if reachedEnd { ended(epoch: epoch) } else { player?.play() }
            } else { player?.pause() }
        }
    }

    /// Payload for an off-main actual-frame sample. The view must have a ready
    /// movie layer; callers fall back to the visible poster otherwise.
    var frameIdentity: PetVideoFrameIdentity? {
        guard let url else { return nil }
        return PetVideoFrameIdentity(url: url, token: token, selectionKey: selectionKey,
                                     dragSession: dragSession)
    }

    var movieScreenFrame: NSRect? {
        guard let window, movieSize.width > 0, movieSize.height > 0 else { return nil }
        let rect = AVMakeRect(aspectRatio: movieSize, insideRect: bounds)
        let frame = window.convertToScreen(convert(rect, to: nil))
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    /// The configured clip's poster supplies geometry before decoding is ready.
    /// Callers validate its identity before using it as a drag expansion target.
    var isPosterVisible: Bool { !posterLayer.isHidden }

    func currentSamplingPayload() -> (identity: PetVideoFrameIdentity, time: CMTime, frame: NSRect)? {
        guard videoLayer.isReadyForDisplay, let player, player.currentItem?.status == .readyToPlay,
              let identity = frameIdentity, let frame = movieScreenFrame else { return nil }
        var time = player.currentTime()
        let duration = player.currentItem?.duration.seconds ?? .nan
        if duration.isFinite, duration > 0.05, time.seconds >= duration - 0.001 {
            time = CMTime(seconds: duration - 0.02, preferredTimescale: 600)
        }
        return (identity, time, frame)
    }

    /// The real movie frame at the player's current time (sampled from the same
    /// asset, not the poster). Returns nil while the poster is still showing or
    /// the generator is unavailable; this synchronous test/fallback API is not
    /// used on the production main-thread collapse path.
    func currentDisplayedFrame() -> CGImage? {
        guard videoLayer.isReadyForDisplay, let player, let frameGenerator else { return nil }
        var time = player.currentTime()
        let duration = player.currentItem?.duration.seconds ?? .nan
        if duration.isFinite, duration > 0.05, time.seconds >= duration - 0.001 {
            time = CMTime(seconds: duration - 0.02, preferredTimescale: 600)
        }
        return try? frameGenerator.copyCGImage(at: time, actualTime: nil)
    }

    private func ended(epoch generation: UInt64) {
        guard generation == epoch else { return }
        reachedEnd = true
        guard animate else { return }
        if loop {
            reachedEnd = false
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == generation, self.animate else { return }
                    if self.loop { self.player?.play() }
                    else { self.onFinished?(self.token) }
                }
            }
        } else { onFinished?(token) }
    }
    private func failed(epoch generation: UInt64) {
        guard generation == epoch, !failureReported else { return }
        failureReported = true
        player?.pause()
        NSLog("AgentPet: animation playback failed; selecting a safe fallback")
        onFailure?()
    }
    func teardown() {
        epoch &+= 1
        player?.pause()
        frameGenerator = nil
        posterImage = nil
        player?.replaceCurrentItem(with: nil)
        videoLayer.player = nil
        player = nil
        url = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        readyObservation?.invalidate(); readyObservation = nil
        statusObservation?.invalidate(); statusObservation = nil
    }
}
