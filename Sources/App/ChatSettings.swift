import Foundation
import AgentPetCore

/// Legacy single-mode message storage retained for downgrade compatibility.
/// The new UI uses IdleSpeechSettings; these old keys are preserved, not merged
/// with inactive per-Agent custom content or used to override task messages.
@MainActor
final class ChatSettings: ObservableObject {
    static let shared = ChatSettings()

    enum Source: String { case system, custom }

    @Published var source: Source {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey) }
    }
    /// moodRawValue -> custom lines.
    @Published var custom: [String: [String]] {
        didSet { save() }
    }

    private static let sourceKey = "agentpet.chatSource"
    private static let customKey = "agentpet.chatCustom"

    /// Moods the user can write messages for (idle = the "doing nothing" line).
    static let editableMoods: [PetMood] = [.working, .waiting, .done, .celebrate, .idle]

    /// Built-in defaults per mood; idle borrows the IdleBoost one-liners.
    /// Localized so the system message set follows the user's language.
    private func defaults(_ mood: PetMood) -> [String] {
        let base = mood == .idle ? IdleBoost.lines : (PetChat.lines[mood] ?? [])
        return base.map { NSLocalizedString($0, comment: "pet message") }
    }

    init() {
        source = (UserDefaults.standard.string(forKey: Self.sourceKey)).flatMap(Source.init(rawValue:)) ?? .system
        if let data = UserDefaults.standard.data(forKey: Self.customKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            custom = decoded
        } else {
            custom = [:]
        }
    }

    /// Lines for a mood, honouring the chosen source. Falls back to the system
    /// set when a custom mood is left empty so the bubble is never blank.
    func lines(for mood: PetMood) -> [String] {
        switch source {
        case .system:
            return defaults(mood)
        case .custom:
            let lines = (custom[mood.rawValue] ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return lines.isEmpty ? defaults(mood) : lines
        }
    }

    /// One message per line, for binding to a multiline text field.
    func text(for mood: PetMood) -> String {
        (custom[mood.rawValue] ?? defaults(mood)).joined(separator: "\n")
    }

    func setText(_ text: String, for mood: PetMood) {
        custom[mood.rawValue] = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
    }

    /// Refills the custom messages with the app's built-in defaults.
    func resetToDefaults() {
        var updated = custom
        for mood in Self.editableMoods {
            updated[mood.rawValue] = defaults(mood)
        }
        custom = updated
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.customKey)
        }
    }
}
