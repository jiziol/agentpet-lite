import SwiftUI
import AgentPetCore

/// Retained by the pet body across drag presentation changes. Consumption of
/// task results/cues must survive reopening the video hierarchy at mouse-up.
@MainActor
final class PetAnimationViewState: ObservableObject {
    var playback = PetAnimationPlayback()
    var failedIDs = Set<String>()
    var packID: String?
    @Published private(set) var revision: UInt64 = 0
    func changed() { revision &+= 1 }
    func finish(_ token: UInt64) { playback.finished(token: token); changed() }
}

/// One independent animation sequence per pet/preview; session state remains owned by the model.
struct PetAnimatedView: View {
    let pack: ImagePetPack
    let mood: PetMood
    var size: CGFloat = 120
    var dragging = false
    var dragSession: UInt64 = 0
    var tapRevision = 0
    var context: PetAnimationContext? = nil
    @ObservedObject private var store = PetAnimationBindingsStore.shared
    @ObservedObject private var pet = PetController.shared
    @Environment(\.animationsEnabled) private var enabled
    @StateObject private var state: PetAnimationViewState

    init(pack: ImagePetPack, mood: PetMood, size: CGFloat = 120,
         dragging: Bool = false, dragSession: UInt64 = 0, tapRevision: Int = 0,
         context: PetAnimationContext? = nil, state: PetAnimationViewState? = nil) {
        self.pack = pack; self.mood = mood; self.size = size
        self.dragging = dragging; self.dragSession = dragSession
        self.tapRevision = tapRevision; self.context = context
        _state = StateObject(wrappedValue: state ?? PetAnimationViewState())
    }

    private var settings: PetAnimationBindings { store.bindings(for: pack) }
    private var width: CGFloat {
        guard let clip = pack.videoClips.first else { return size }
        return size * max(1, CGFloat(clip.width) / CGFloat(clip.height))
    }

    var body: some View {
        Group {
            if let selection = state.playback.selection,
               let index = pack.index(for: selection.clipID) {
                if let video = pack.video(for: selection.clipID) {
                    PetVideoSpriteView(clip: video, loop: selection.loop,
                                       playbackID: selection.token, animate: enabled,
                                       onFinished: finish,
                                       onFailure: {
                                           state.failedIDs.insert(video.id)
                                           update()
                                       }, selectionKey: selection.key,
                                       dragSession: dragging ? dragSession : 0)
                        .frame(width: width, height: size)
                } else {
                    ImageSpriteView(frames: pack.clip(index), mood: mood,
                                    fps: pet.spriteFPS(forMood: mood), size: size,
                                    loop: selection.loop, playbackID: selection.token,
                                    onFinished: finish)
                }
            } else {
                ImageSpriteView(frames: pack.clip(0), mood: mood,
                                fps: pet.spriteFPS(forMood: mood), size: size)
            }
        }
        .id(pack.animationRevision)
        .frame(width: width, height: size)
        .onAppear { update() }
        .onChange(of: mood) { _ in update() }
        .onChange(of: dragging) { _ in update() }
        .onChange(of: tapRevision) { _ in update() }
        .onChange(of: settings) { _ in update() }
        .onChange(of: context) { _ in update() }
        .onChange(of: enabled) { _ in update() }
        .onChange(of: pack.id) { _ in
            state.failedIDs.removeAll()
            state.playback = PetAnimationPlayback()
            update()
        }
        .onChange(of: pack.animationIDs) { _ in update() }
        .onChange(of: pack.animationRevision) { _ in
            state.failedIDs.removeAll()
            update()
        }
    }
    private func update() {
        if state.packID != pack.id {
            state.packID = pack.id
            state.playback = PetAnimationPlayback()
            state.failedIDs.removeAll()
        }
        state.playback.update(mood: mood, dragging: dragging, tapRevision: tapRevision,
                        bindings: settings, available: Set(pack.animationIDs).subtracting(state.failedIDs), context: context)
        if !enabled, let selection = state.playback.selection, !selection.loop {
            state.playback.finished(token: selection.token)
        }
        state.changed()
    }
    private func finish(_ token: UInt64) {
        guard !dragging else { return } // A held drag never settles on movie-end.
        state.finish(token)
    }
}
