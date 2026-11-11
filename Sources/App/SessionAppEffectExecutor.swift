import Foundation
import AgentPetCore

/// Executes on the daemon's main actor, in the existing observable order.
@MainActor
enum SessionAppEffectExecutor {
    static func execute(_ effects: [SessionCompletionEffect], session: AgentSession, petID: String?) {
        for effect in effects {
            switch effect {
            case .notification(let title, let body): NotificationManager.shared.notify(title: title, body: body)
            case .waitingSound: SoundSettings.shared.play(.waiting)
            case .completionSound: SoundSettings.shared.play(.done)
            case .completionMeal: PetCareController.shared.recordMeal(petID: petID)
            case .completedSessionUsage: ProjectUsageStore.shared.recordSession(project: session.project, agent: session.agentKind.rawValue)
            }
        }
    }

    static func consume(_ receipt: SessionUsageReceipt, petID: String?) {
        PetCareController.shared.feedTokens(receipt.tokens, petID: petID)
        ProjectUsageStore.shared.recordTokens(receipt.tokens, project: receipt.project,
                                              agent: receipt.agent, costUSD: receipt.costUSD)
    }
}
