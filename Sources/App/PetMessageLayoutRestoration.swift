import AppKit

/// Owns the SwiftUI-layout to AppKit snapshot handoff. Every begin/cancel gets
/// a new generation, even when a status card reopens for the same model.
@MainActor
final class PetMessageLayoutRestoration {
    private let generation = InteractionGeneration()
    private var fallback: DispatchWorkItem?
    private weak var model: PetWindowModel?
    func begin(model: PetWindowModel, hasContent: Bool, timeout: TimeInterval = 0.15,
               capture: @escaping () -> PetBubbleSnapshot?, completion: @escaping (PetBubbleSnapshot?) -> Void) {
        cancel()
        self.model = model
        guard hasContent else { model.isShowingStats = false; completion(nil); return }
        let token = generation.token
        var delivered = false
        let finish: (PetBubbleSnapshot?) -> Void = { [weak self, weak model] snapshot in
            guard let self, self.generation.accepts(token), !delivered else { return }
            delivered = true; self.fallback?.cancel(); self.fallback = nil
            model?.onMessageLayoutReady = nil
            completion(snapshot)
        }
        let deliver: () -> Void = { [weak self] in
            guard let self, self.generation.accepts(token), !delivered,
                  let snapshot = capture() else { return }
            finish(snapshot)
        }
        model.onMessageLayoutReady = deliver
        model.messagesTransitionHidden = true; model.isShowingStats = false
        DispatchQueue.main.async { deliver() }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation.accepts(token) else { return }
            finish(nil)
        }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }
    func cancel() {
        generation.renew(); fallback?.cancel(); fallback = nil
        model?.onMessageLayoutReady = nil; model = nil
    }
}
