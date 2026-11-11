import SwiftUI
import AppKit
import AgentPetCore

/// One row per agent session. Iterates `BubbleSettings.effectiveLayout` tokens
/// in order on a single line; project/title shrink before the message does.
struct SessionBubbleRow: View {
    let session: AgentSession
    var count: Int = 1
    var chatStyle: Bool = false
    /// Set for an aggregated AionUI Team row: the title becomes the team name
    /// and a lead-less Team keeps an explicit unknown state.
    var team: GroupedSession.TeamInfo? = nil
    @EnvironmentObject private var settings: BubbleSettings
    @Environment(\.bubbleInteraction) private var interaction
    @Environment(\.animationsEnabled) private var animationsEnabled

    private var primaryPt: CGFloat { settings.fontSize.primaryPt }
    private var secondaryPt: CGFloat { settings.fontSize.secondaryPt }
    private var iconPt: CGFloat { settings.fontSize.iconPt }
    private var rowMaxWidth: CGFloat {
        chatStyle ? AgentBubble.petContentMaxWidth : AgentBubble.contentMaxWidth
    }

    private var isWaiting: Bool { presentation.isWaitingDisplay }
    private var presentation: BubblePresentation.Row {
        .init(session: session, team: team)
    }
    private var usesTaskDetails: Bool { presentation.usesTaskDetails }
    private var canFocusTerminal: Bool { presentation.canFocusTerminal }

    @ViewBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let notice = presentation.associationNotice {
                Text(notice)
                    .help("AO 会话：" + (session.aoObservation?.sessionID ?? session.id))
                    .font(.system(size: secondaryPt, weight: .semibold))
                    .foregroundStyle(TaskBubbleStyle.secondary)
                    .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: rowMaxWidth, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if presentation.showsPendingApproval, let pending = session.pendingApproval {
                        PendingApprovalRow(session: session, pending: pending, chatStyle: chatStyle, team: team)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            if usesTaskDetails,
                               settings.effectiveLayout.tokens.contains(where: { $0.token == .title && $0.isVisible }) {
                                Text(presentation.titleText)
                                    .font(.system(size: primaryPt, weight: .semibold))
                                    .foregroundStyle(TaskBubbleStyle.foreground)
                                    .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                                    .lineLimit(chatStyle ? 1 : 2)
                                    .frame(maxWidth: rowMaxWidth, alignment: .leading)
                            }
                            rowBody
                            if let message = interaction.navigationMessages[presentation.navigationSessionID] {
                                Text(message).font(.system(size: 10)).foregroundStyle(TaskBubbleStyle.secondary)
                                    .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity).lineLimit(2)
                            }
                        }
                    }
                }
                .modifier(RowInteraction(sessionId: presentation.navigationSessionID, canFocus: canFocusTerminal,
                                           projectEntry: presentation.isAOProjectEntry))
                .help(interaction.navigationMessages[presentation.navigationSessionID] ?? presentation.navigationHint)
                // A sibling of the main hit region: selecting an unread member
                // must not also dispatch the primary project navigation gesture.
                if presentation.isAOProjectEntry, presentation.unreadNativeCount > 0 {
                    Button {
                    if let id = presentation.unreadNavigationSessionID { interaction.focus(id) }
                } label: {
                    Text(String(format: NSLocalizedString("ao.project.unread.button", comment: ""), presentation.unreadNativeCount))
                        .font(.system(size: secondaryPt, weight: .semibold))
                        .foregroundStyle(TaskBubbleStyle.foreground)
                        .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .disabled(presentation.unreadNavigationSessionID == nil)
                .help(presentation.unreadNavigationHint)
              }
            }
            if let id = presentation.unreadNavigationSessionID, id != presentation.navigationSessionID,
               let message = interaction.navigationMessages[id] {
                Text(message).font(.system(size: 10)).foregroundStyle(TaskBubbleStyle.secondary)
                    .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity).lineLimit(2)
            }
            ForEach(presentation.aoAttentionReceipts.filter(\.hasUnread)) { receipt in
                AOAttentionReminderView(receipt: receipt, fontSize: secondaryPt,
                    backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity,
                    acknowledge: { interaction.acknowledgeAO(receipt) })
                .frame(maxWidth: rowMaxWidth, alignment: .leading)
            }
        }

    }

    private var rowBody: some View {
        let visible = presentation.visibleTokens(settings.effectiveLayout)

        return HStack(alignment: .center, spacing: 4) {
            if visible.contains(where: { $0.token == .dot }) {
                tokenView(for: .dot)
            }
            HStack(alignment: .center, spacing: 4) {
                ForEach(visible.filter { $0.token != .dot }) { item in
                    tokenView(for: item.token)
                }
                if count > 1 {
                    Text("×\(count)")
                        .font(.system(size: settings.fontSize.secondaryPt, weight: .semibold))
                        .foregroundStyle(TaskBubbleStyle.secondary)
                        .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )
                }
            }
        }
        .frame(maxWidth: rowMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private func tokenView(for token: BubbleToken) -> some View {
        switch token {
        case .dot:
            StateDot(color: stateDotColor, spins: dotSpins, style: settings.dotStyle, isLit: presentation.dotIsLit)
                .accessibilityLabel(presentation.indicatorLabel)
        case .icon:
            if team?.host == .aionUI {
                AionUiTeamIcon(size: iconPt)
            } else if team?.host == .agentOrchestrator {
                AOProjectIcon(size: iconPt)
            } else if session.agentKind == .unknown, let name = session.agentName {
                CustomAgentIcon(name: name, size: iconPt)
            } else {
                ResolvedIconView(
                    choice: settings.iconChoice(for: session.agentKind),
                    size: iconPt
                )
            }
        case .title:
            // The layout gate already hides a missing ordinary title; Team rows
            // resolve to the team name here.
            Text(presentation.titleText)
                    .font(.system(size: primaryPt, weight: .semibold))
                    .foregroundStyle(TaskBubbleStyle.foreground)
                    .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
        case .project:
            Text(projectName)
                .font(.system(size: primaryPt, weight: .medium))
                .foregroundStyle(TaskBubbleStyle.foreground)
                .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        case .separator:
            Text(settings.separatorChar)
                .font(.system(size: primaryPt, weight: .regular))
                .foregroundStyle(TaskBubbleStyle.secondary)
                .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
        case .message:
            AnimatedStatusText(
                message: messageText,
                font: .system(size: primaryPt, weight: isWaiting ? .semibold : .medium),
                color: isWaiting ? TaskBubbleStyle.waiting : TaskBubbleStyle.foreground,
                animated: animationsEnabled && session.state != .done && !usesTaskDetails
            )
            .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
            .modifier(WaitingTextFlash(active: isWaiting && animationsEnabled))
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
            .fixedSize(horizontal: false, vertical: true)
        case .stateLabel:
            Text(stateLabel)
                .font(.system(size: secondaryPt, weight: .medium))
                .foregroundStyle(TaskBubbleStyle.secondary)
                .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
        case .model:
            if let model = session.model {
                TaskBubbleModelTag(text: model, kind: session.agentKind, fontSize: secondaryPt,
                    backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                    .layoutPriority(-1)
            }
        case .elapsed:
            if animationsEnabled && session.turnEndedAt == nil {
                // Tick live, but only as often as the label can change: every
                // second under a minute, then on minute boundaries ("3m",
                // "1h 5m"), instead of a 1 Hz re-render per row forever.
                TimelineView(ElapsedSchedule(since: elapsedStart)) { context in
                    Text(elapsedText(since: elapsedStart, now: session.turnEndedAt ?? context.date))
                        .font(.system(size: secondaryPt, weight: .medium))
                        .foregroundStyle(TaskBubbleStyle.secondary)
                        .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                        .monospacedDigit()
                }
            } else {
                Text(elapsedText(since: elapsedStart, now: session.turnEndedAt ?? Date()))
                    .font(.system(size: secondaryPt, weight: .medium))
                    .foregroundStyle(TaskBubbleStyle.secondary)
                    .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                    .monospacedDigit()
            }
        }
    }

    private var projectName: String { presentation.projectName }
    private var elapsedStart: Date { presentation.elapsedStart }
    private var stateLabel: String { presentation.stateLabel }
    private var messageText: String { presentation.messageText }
    private func elapsedText(since date: Date, now: Date) -> String {
        presentation.elapsedText(since: date, now: now)
    }
    private var dotSpins: Bool { presentation.dotSpins }
    private var stateDotColor: Color {
        let rgb = presentation.indicatorRGB
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
    private func elapsedString(since date: Date, now: Date) -> String {
        presentation.elapsedString(since: date, now: now)
    }

}

// MARK: - Pending approval row

/// Row shown instead of the normal status line when a session has a gated
/// tool call awaiting the user's allow/deny decision.
private struct PendingApprovalRow: View {
    let session: AgentSession
    let pending: PendingApproval
    var chatStyle: Bool = false
    /// Set when this approval belongs to a verified Team lead: the row keeps the
    /// Team title/identity instead of presenting as a bare member prompt.
    var team: GroupedSession.TeamInfo? = nil
    @EnvironmentObject private var settings: BubbleSettings

    @Environment(\.bubbleInteraction) private var interaction

    private static let allowColor = Color(red: 0.13, green: 0.77, blue: 0.37)
    private static let denyColor = Color(red: 0.86, green: 0.23, blue: 0.23)

    private var rowMaxWidth: CGFloat {
        chatStyle ? AgentBubble.petContentMaxWidth : AgentBubble.contentMaxWidth
    }

    var body: some View {
        let presentation = BubblePresentation.Row(session: session, team: team)
        let rgb = presentation.indicatorRGB
        VStack(alignment: .leading, spacing: 3) {
            if let team {
                Text(team.name)
                    .font(.system(size: settings.fontSize.primaryPt, weight: .semibold))
                    .foregroundStyle(TaskBubbleStyle.foreground)
                    .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                    .lineLimit(1)
            }
            HStack(alignment: .center, spacing: 6) {
                StateDot(color: Color(red: rgb.0, green: rgb.1, blue: rgb.2), spins: presentation.dotSpins,
                         style: settings.dotStyle, isLit: presentation.dotIsLit)
                    .accessibilityLabel(presentation.indicatorLabel)
                Text("\(pending.toolName): \(pending.summary)")
                    .font(.system(size: settings.fontSize.primaryPt, weight: .medium))
                    .foregroundStyle(TaskBubbleStyle.foreground)
                    .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                    .lineLimit(1)
                    .truncationMode(.tail)
                decisionButton(title: NSLocalizedString("Allow", comment: "Approve a pending tool call"),
                                tint: Self.allowColor, decision: .allow)
                decisionButton(title: NSLocalizedString("Deny", comment: "Reject a pending tool call"),
                                tint: Self.denyColor, decision: .deny)
            }
        }
        .frame(maxWidth: rowMaxWidth, alignment: .leading)
    }

    private func decisionButton(title: String, tint: Color, decision: ApprovalDecision) -> some View {
        Button {
            interaction.resolve(session.id, pending.requestId, decision)
        } label: {
            Text(title)
                .font(.system(size: settings.fontSize.secondaryPt, weight: .semibold))
                .foregroundStyle(tint)
                .taskBubbleText(backgroundOpacity: settings.opacity, textOpacity: settings.textOpacity)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

}

/// Row-level interaction for a live session: a subtle hover highlight so it's
/// clear which row is under the pointer, plus a tap that focuses the session's
/// terminal. The highlight is drawn with a negative inset so it doesn't shift
/// the row's layout. Applied to normal and pending-approval rows alike; the
/// Allow/Deny buttons inside a pending row keep their own taps.
private struct RowInteraction: ViewModifier {
    let sessionId: String
    let canFocus: Bool
    var projectEntry = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(highlight)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .modifier(TapToFocus(sessionId: sessionId, enabled: canFocus, projectEntry: projectEntry))
    }

    @ViewBuilder
    private var highlight: some View {
        if canFocus && hovering {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(0.10))
                .padding(.horizontal, -5)
                .padding(.vertical, -2)
        }
    }
}

private struct TapToFocus: ViewModifier {
    @Environment(\.bubbleInteraction) private var interaction
    let sessionId: String
    let enabled: Bool
    var projectEntry = false
    private func focus() {
        if projectEntry { interaction.focusAOProject(sessionId) }
        else { interaction.focus(sessionId) }
    }
    func body(content: Content) -> some View {
        if enabled {
            content
                .onTapGesture { focus() }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { focus() }
        } else {
            content
        }
    }
}
