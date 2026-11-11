import SwiftUI
import AppKit
import AgentPetCore

// MARK: - Agent Bubble (structured rows for working/waiting)

/// Speech bubble listing one row per (agentKind, project) group.
/// Applies filter/sort/cap from `BubbleSettings` before rendering.
/// `tailEdge` controls whether the pointer arrow points down (pet) or up (menu bar).
struct AgentBubble: View {
    let sessions: [AgentSession]
    var tailEdge: Edge = .bottom
    var expanded = false
    /// Dedicated task panels already provide their own native scroll viewport.
    var usesExternalScrollViewport = false
    /// Preview consumers supply local callbacks rather than invoking the daemon.
    var interactionOverride: BubbleInteraction? = nil
    @ObservedObject private var settings = BubbleSettings.shared
    @ObservedObject private var daemon = AppDaemon.shared
    @Environment(\.bubbleTailOffset) private var tailOffset

    static func visible(_ sessions: [AgentSession], settings: BubbleSettings) -> [AgentSession] {
        BubblePresentation.visible(sessions, settings: settings.presentationConfiguration)
    }
    private var groupedSessions: [GroupedSession] {
        BubblePresentation.groups(sessions, settings: settings.presentationConfiguration, expanded: expanded)
    }

    private var totalSessionCount: Int {
        groupedSessions.reduce(0) { $0 + $1.count }
    }

    private var isPetChat: Bool { tailEdge == .bottom }
    // Capsule for single visible row; rounded rect when taller or carousel dots are shown.
    private var useCapsule: Bool {
        isPetChat && groupedSessions.count <= 1 && settings.displayMode != .compact && !showsClearEnded
    }

    var body: some View {
        let fill = bubbleFill
        let stroke = borderColor

        VStack(spacing: 0) {
            if tailEdge == .top {
                BubblePointerShape()
                    .fill(fill)
                    .frame(width: 12, height: 7)
                    .scaleEffect(x: 1, y: -1)
            }
            VStack(alignment: .leading, spacing: 6) {
                bubbleContent
                if showsClearEnded {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            interaction.clearEnded(clearableSessionIDs)
                        } label: {
                            Label("Clear ended tasks", systemImage: "xmark.circle")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(TaskBubbleStyle.foreground)
                                .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("task-bubble-clear-ended")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background { TaskBubbleScrim(backgroundOpacity: settings.opacity) }
            .background {
                if useCapsule {
                    Capsule().fill(fill)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
                }
            }
            .overlay {
                if useCapsule {
                    Capsule().strokeBorder(stroke, lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(stroke, lineWidth: 1)
                }
            }
            .compositingGroup()
            if tailEdge == .bottom {
                BubblePointerShape()
                    .fill(fill)
                    .frame(width: 12, height: 7)
                    .offset(x: tailOffset)
            }
        }
        .fixedSize(horizontal: isPetChat, vertical: true)
        .frame(maxWidth: 420, alignment: .leading)
        .appAppearance()
        .environmentObject(settings)
        .environment(\.bubbleInteraction, interaction)
        .contextMenu {
            if showsClearEnded {
                Button("Clear ended tasks") { interaction.clearEnded(clearableSessionIDs) }
            }
        }
    }

    /// Apply the same visibility policy as the rows, before grouping or caps.
    /// Expired/read history and hidden sources are not this bubble's backlog.
    private var eligibleSessions: [AgentSession] {
        Self.visible(sessions, settings: settings)
    }

    /// The cleanup entry is a fallback for eligible backlogs, including rows
    /// beyond the display cap and inside collapsed groups.
    private var showsClearEnded: Bool {
        eligibleSessions.count > 5 && !clearableSessionIDs.isEmpty
    }

    /// Include ended sessions beyond the display cap and inside collapsed
    /// groups; only the sessions belonging to this bubble are dismissed.
    private var clearableSessionIDs: Set<String> {
        Set(eligibleSessions.filter(EndedTaskDismissalState.canClear).map(\.id))
    }

    private var interaction: BubbleInteraction {
        interactionOverride ?? BubbleInteraction(navigationMessages: daemon.navigationMessages,
            focus: { daemon.focusTerminal(sessionId: $0) },
            focusAOProject: { daemon.focusTerminal(sessionId: $0, intent: .aoProject) },
            acknowledgeAO: { daemon.acknowledgeAO($0) },
            resolve: { daemon.resolveApproval(sessionId: $0, requestId: $1, decision: $2) },
            clearEnded: { daemon.clearEndedSessions(ids: $0) })
    }

    /// Inner content width cap (bubble max minus horizontal padding).
    static let contentMaxWidth: CGFloat = 396
    /// Pet chat bubble hugs content; still capped for very long lines.
    static let petContentMaxWidth: CGFloat = 320

    private var bubbleFill: Color {
        TaskBubbleStyle.fill.opacity(settings.opacity)
    }

    private var borderColor: Color {
        .white.opacity(0.08 * settings.opacity)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if expanded {
            if usesExternalScrollViewport {
                expandedRows.frame(width: Self.contentMaxWidth, alignment: .leading)
            } else {
                ScrollView { expandedRows }
                    .frame(width: Self.contentMaxWidth, height: min(CGFloat(groupedSessions.count) * 42, 260))
            }
        } else {
        switch settings.displayMode {
        case .list:
            ForEach(groupedSessions) { group in
                SessionBubbleRow(session: group.session, count: group.count, chatStyle: isPetChat, team: group.team)
            }
        case .carousel:
            BubbleCarousel(groups: groupedSessions, chatStyle: isPetChat)
        case .compact:
            BubbleCompactLayout(
                groups: groupedSessions,
                totalCount: totalSessionCount,
                chatStyle: isPetChat
            )
        }
        }
    }

    private var expandedRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groupedSessions) { group in
                SessionBubbleRow(session: group.session, count: group.count, chatStyle: false, team: group.team)
            }
        }
    }

}
