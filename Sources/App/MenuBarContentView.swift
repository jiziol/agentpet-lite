import SwiftUI
import AppKit
import AgentPetCore

/// Rich menu bar popover: a theme-aware blurred card with an arrow pointing at the
/// status item, a live agent list, and a footer bar.
struct MenuContentView: View {
    @ObservedObject private var daemon = AppDaemon.shared
    @ObservedObject private var petWindow = PetWindowController.shared
    @ObservedObject private var statusBar = StatusBarController.shared
    @ObservedObject private var pet = PetController.shared
    @ObservedObject private var bubble = BubbleSettings.shared
    var dismiss: () -> Void
    var availableHeight: CGFloat = 700
    /// Isolated layout fixtures must never populate the live daemon.
    var sessionsOverride: [AgentSession]? = nil

    /// Show agents that are doing something or just finished. Idle and merely
    /// `registered` (open but not working) sessions are hidden, so an idle
    /// terminal doesn't sit in the list; they reappear the moment they work.
    private var agents: [AgentSession] {
        (sessionsOverride ?? daemon.sessions).filter { $0.state != .idle && $0.state != .registered }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            agentSection
            divider
            controls
            divider
            footer
        }
        .frame(width: 300)
        .background(.regularMaterial)
        .appAppearance()
        .noFocusRing()
    }

    private var divider: some View { Divider().overlay(Theme.cardStroke) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ApplicationIconView(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("AgentPet Lite").font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.5))
            }
            Spacer()
        }
        .padding(14)
    }

    private var subtitle: String {
        let total = agents.count
        if total == 0 { return "No agents running" }
        let running = agents.filter { $0.state == .working }.count
        let label = "\(total) agent\(total == 1 ? "" : "s")"
        return running > 0 ? "\(label) · \(running) running" : label
    }

    // MARK: Agents

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionLabel("Agents")
                Spacer()
                if !agents.isEmpty {
                    Button("Clear ended tasks") { daemon.clearEndedSessions() }
                        .disabled(!agents.contains(where: EndedTaskDismissalState.canClear))
                        .accessibilityIdentifier("menu-clear-ended")
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .padding(.trailing, 14).padding(.top, 12).padding(.bottom, 6)
                }
            }
            if agents.isEmpty {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nothing running right now.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.55))
                        Text(IdleBoost.line(at: context.date))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(agents) { session in
                            AgentRow(session: session, onClear: EndedTaskDismissalState.canClear(session) ? { daemon.clearEndedSessions(ids: [session.id]) } : nil)
                        }
                    }
                }
                // Only the rows scroll. The section's clear action and the
                // settings/footer stay reachable even after a day of results.
                .frame(height: min(CGFloat(agents.count) * 46, max(46, min(280, availableHeight - 470))))
                .accessibilityIdentifier("menu-agent-scroll")
                .padding(.bottom, 6)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(1.4)
            .foregroundStyle(Color.primary.opacity(0.35))
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            controlRow(label: "Show pet", isOn: $petWindow.isVisible)
            controlRow(label: "Hide AgentPet Lite menu bar icon", isOn: $statusBar.menuBarHidden)
            controlRow(label: "Show chat on menu bar", isOn: $statusBar.showChatOnMenuBar)
            controlRow(label: "Show idle message", isOn: $pet.showIdleMessage)
            controlRow(label: "Show Superchat", isOn: $bubble.superchatEnabled)
            HStack(spacing: 8) {
                Text("Bubble font size").font(.system(size: 13))
                Spacer()
                Picker("Bubble font size", selection: $bubble.fontSize) {
                    Text("S").tag(BubbleSettings.FontSize.small)
                    Text("M").tag(BubbleSettings.FontSize.medium)
                    Text("L").tag(BubbleSettings.FontSize.large)
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                .frame(width: 112).accessibilityIdentifier("menu-bubble-font-size")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            sliderRow(label: "Background opacity",
                      value: $bubble.opacity, range: BubbleSettings.opacityRange,
                      readout: "\(Int((bubble.opacity * 100).rounded()))%", id: "menu-bubble-opacity")
            sliderRow(label: "Text opacity",
                      value: $bubble.textOpacity, range: BubbleSettings.textOpacityRange,
                      readout: "\(Int((bubble.textOpacity * 100).rounded()))%", id: "menu-bubble-text-opacity")
            sliderRow(label: "Pet size",
                      value: $pet.petPoint, range: PetController.minPoint...PetController.maxPoint,
                      readout: "\(Int(pet.petPoint.rounded()))", id: "menu-pet-size")
        }
    }

    /// Equal label and readout columns keep every slider track aligned.
    private func sliderRow(label: LocalizedStringKey, value: Binding<Double>,
                           range: ClosedRange<Double>, readout: String, id: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 13)).foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.85).frame(width: 102, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini).tint(Color.systemAccent)
                .accessibilityLabel(label).accessibilityIdentifier(id)
            Text(readout).font(.system(size: 10, design: .monospaced))
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func controlRow(label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(label)).font(.system(size: 13)).foregroundStyle(.primary)
            Spacer()
            ColorSwitch(isOn: isOn)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            FooterButton(icon: "gearshape", label: "Settings") {
                // Use closeAndThen so the window appears only after the popover
                // animation fully completes — no race, no overlap.
                StatusBarController.shared.closeAndThen {
                    SettingsWindowController.shared.show()
                }
            }
            Spacer()
            FooterButton(icon: "power", label: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - Menu bar hanging bubble

/// Thin wrapper so the agent bubble shown below the menu bar icon
/// auto-refreshes via @ObservedObject without re-creating the NSPanel.
struct MenuBarBubbleView: View {
    @ObservedObject private var pet = PetController.shared

    var body: some View {
        AgentBubble(sessions: pet.activeAgentSessions, tailEdge: .top)
            .padding(TaskBubbleStyle.effectInset)
            .appAppearance()
    }
}

private struct FooterButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(LocalizedStringKey(label))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}

private struct AgentRow: View {
    let session: AgentSession
    var onClear: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(project).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if hovering, let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.primary.opacity(0.45))
                }
                .buttonStyle(.plain)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(timeString(now: context.date))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var project: String {
        session.project.map { ($0 as NSString).lastPathComponent } ?? session.id
    }

    /// The agent's context (waiting reason / running tool) when known, else its state.
    private var subtitle: String {
        if let message = session.message, !message.isEmpty { return message }
        return session.state.rawValue.capitalized
    }

    private var dotColor: Color {
        switch session.state {
        case .working, .registered: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .idle: return .gray
        }
    }

    private func timeString(now: Date) -> String {
        switch session.state {
        case .done, .idle:
            return session.updatedAt.formatted(date: .omitted, time: .shortened)
        default:
            let s = max(0, Int(now.timeIntervalSince(session.stateSince)))
            return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
        }
    }
}
