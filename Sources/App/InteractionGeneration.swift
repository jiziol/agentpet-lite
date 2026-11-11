import Foundation

/// Shared by SwiftUI value copies; invalidation also fences already-enqueued callbacks.
@MainActor
final class InteractionGeneration {
    private(set) var token = UUID()
    @discardableResult func renew() -> UUID { token = UUID(); return token }
    func accepts(_ token: UUID) -> Bool { self.token == token }
}
