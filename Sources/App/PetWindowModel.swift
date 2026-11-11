import Foundation
import AppKit
import AgentPetCore

/// Per-window pet state. One instance backs each pet window (single window for
/// now; the registry in later tasks owns one per active project). Holds only
/// the fields that vary per window — global toggles (showChat, petPoint…) still
/// live on `PetController.shared`.
@MainActor
final class PetWindowModel: ObservableObject {
    /// Stable grouping key: a project path or `"default"` for the home pet.
    let key: String

    @Published var petID: String?
    @Published var mood: PetMood
    @Published var projectName: String?
    @Published var sessions: [AgentSession]
    @Published var animationContext = PetAnimationContext()
    @Published var quotaText = ""
    var noticeSource: SystemNoticeCenter?
    @Published var noticeWidth: CGFloat = 380
    weak var statusNoticeMarker: SystemNoticeMarkerView?
    @Published var idleText = ""
    @Published var speechRows: [PetSpeechState.Row] = []
    @Published var speechHeight: CGFloat = 0
    @Published var count: Int
    @Published var chatLine: String
    /// False while this pet's panel is fully occluded or the displays are
    /// asleep/locked. Views pause every animation and timer while false so an
    /// unseen pet costs ~no CPU. Driven by `PetWindowController`.
    @Published var isOnScreen = true
    /// Horizontal shift of the pet inside its window. Non-zero when the window
    /// was pushed back onto the pet's screen (wide bubble near an edge), so the
    /// pet stays put on screen. Driven by `PetWindowController`.
    @Published var petOffset: CGFloat = 0
    /// Current width of this pet's window (content is centred in it).
    @Published var windowWidth: CGFloat = 0

    /// A passive layout marker used to restrict the stats shortcut to the pet.
    /// The hosting hierarchy owns it; no view/model retain cycle is introduced.
    weak var petBodyView: NSView?
    /// Status and message bubbles are mutually exclusive for this pet.
    @Published var isShowingStats = false
    @Published var messagesTransitionHidden = false
    weak var messageBubbleView: NSView?
    @Published var messageListExpanded = false
    /// Tucked pets keep task bubbles in their compact presentation. Clear both
    /// hover owners so dragging back out cannot restore a stale expansion.
    var messageHoverExpansionEnabled = true {
        didSet {
            guard oldValue != messageHoverExpansionEnabled else { return }
            collapseMessagesTask?.cancel(); collapseMessagesTask = nil
            bodyHovered = false; taskHovered = false
            if !messageHoverExpansionEnabled { messageListExpanded = false }
        }
    }
    @Published var taskContentSize: CGSize = .zero
    @Published var taskHeightLimit: CGFloat = 10000
    @Published var taskWindowWidth: CGFloat = 0
    @Published var taskPetOffset: CGFloat = 0
    /// Effective click-through state of this window's task bubble. Derived by
    /// `PetWindowController` from the saved preference plus displayed
    /// human-handling rows; the badge reads this, never the saved preference.
    @Published var taskBubbleClickThroughStatus: TaskBubbleClickThroughStatus = .off
    var onMessageLayoutReady: (() -> Void)?

    init(
        key: String,
        petID: String? = nil,
        mood: PetMood = .idle,
        projectName: String? = nil,
        sessions: [AgentSession] = [],
        count: Int = 0,
        chatLine: String = ""
    ) {
        self.key = key
        self.petID = petID
        self.mood = mood
        self.projectName = projectName
        self.sessions = sessions
        self.count = count
        self.chatLine = chatLine
    }

    // MARK: - Pet tap interaction (per window)
    // Lives here, not on the shared controller, so tapping one pet in split
    // mode only bounces THAT pet (a shared state flickered every window).

    @Published private(set) var isPetted = false
    @Published private(set) var petReactionLine: String = ""
    @Published private(set) var petTapCount: Int = 0
    @Published var isAnimationDragging = false
    /// A new physical drag must not reuse a movie still configured by the last
    /// SwiftUI update (including a very quick release/drag sequence).
    @Published var animationDragSession: UInt64 = 0

    private lazy var reaction = PetReactionController { [weak self] state in
        self?.isPetted = state.isPetted
        self?.petReactionLine = state.line
        self?.petTapCount = state.tapCount
    }
    private var bodyHovered = false
    private var taskHovered = false
    private var collapseMessagesTask: Task<Void, Never>?
    func hoverBody(_ inside: Bool) {
        guard messageHoverExpansionEnabled else { return }
        bodyHovered = inside; updateMessageHover()
    }
    func hoverTask(_ inside: Bool) {
        guard messageHoverExpansionEnabled else { return }
        taskHovered = inside; updateMessageHover()
    }
    private func updateMessageHover() {
        collapseMessagesTask?.cancel()
        if bodyHovered || taskHovered { messageListExpanded = true; return }
        collapseMessagesTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, !self.bodyHovered, !self.taskHovered else { return }
            self.messageListExpanded = false
        }
    }
    func petTap() { reaction.tap() }
    func stopInteraction() {
        isAnimationDragging = false
        collapseMessagesTask?.cancel(); collapseMessagesTask = nil
        bodyHovered = false; taskHovered = false
        reaction.stop()
        onMessageLayoutReady = nil
        messagesTransitionHidden = false
        isShowingStats = false
    }
}
