import SwiftUI
import AgentPetCore

/// Rendering and selection are independent of collection, so previews cannot
/// open native transcripts or change the formal collection start.
enum DailyTokenUsagePresentation {
    static func compact(_ count: Int64) -> String {
        switch count {
        case 1_000_000_000...: String(format: "%.1fB", Double(count) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(count) / 1_000)
        default: String(count)
        }
    }

    static func amount(_ day: TokenUsageDay?) -> String {
        guard let day else { return "—" }
        return day.total > 0 || day.coverage == .complete ? compact(day.total) : "—"
    }
    static func windowAmount(_ days: [TokenUsageDay]) -> String {
        let total = days.reduce(0) { $0 + $1.total }
        if total > 0 { return compact(total) }
        let started = days.filter { $0.coverage != .notStarted }
        return !started.isEmpty && started.allSatisfy { $0.coverage == .complete } ? "0" : "—"
    }

    static func coverageKey(_ coverage: TokenDayCoverage) -> String {
        switch coverage {
        case .notStarted: "usage.notStarted"
        case .partial: "usage.partial"
        case .complete: "usage.recorded"
        case .unknown: "usage.unknown"
        }
    }

    static func movedDate(_ current: Date?, by offset: Int, days: [TokenUsageDay]) -> Date? {
        guard !days.isEmpty else { return nil }
        let index = current.flatMap { value in days.firstIndex { $0.date == value } } ?? days.count - 1
        return days[min(max(index + offset, 0), days.count - 1)].date
    }

    static func colorHex(_ agent: TokenAgent) -> UInt32 {
        switch agent {
        case .dsh: 0x5294EC
        case .codex: 0x39AD88
        case .opencode: 0xE5A24C
        case .claude: 0xA082D6
        case .agy: 0xD577AC
        }
    }

    static func color(_ agent: TokenAgent) -> Color {
        let hex = colorHex(agent)
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }

    static func sourceName(_ source: TokenSource) -> String {
        switch source { case .dsh: "DSH"; case .codex: "Codex"; case .opencode: "OpenCode"; case .claude: "CC" }
    }

    enum Window: Int, CaseIterable { case week = 7, month = 30 }
    static let windowPreferenceKey = "agentpet.usageChart.windowDays"

    static func days(_ days: [TokenUsageDay], in window: Window) -> [TokenUsageDay] {
        Array(days.suffix(window.rawValue))
    }
    static func columnCenter(_ index: Int, count: Int, width: CGFloat) -> CGFloat {
        let n = CGFloat(max(1, count)), gap: CGFloat = 2
        let column = max(0, (width - gap * (n - 1)) / n)
        return CGFloat(index) * (column + gap) + column / 2
    }

    /// One strictly linear scale, independent of legend, date or source count.
    struct ChartLayout {
        static let height: CGFloat = 112
        let heightPerToken: CGFloat
        init(days: [TokenUsageDay], width: CGFloat, agentCount: Int) {
            heightPerToken = Self.height / CGFloat(max(1, days.map(\.total).max() ?? 0))
        }
        func barHeight(_ total: Int64) -> CGFloat { total > 0 ? CGFloat(total) * heightPerToken : 0 }
    }
}

struct DailyTokenUsageView: View {
    let snapshot: TokenUsageSnapshot
    var isRefreshing = false
    var openSettings: () -> Void = {}
    var bundle: Bundle = .main
    @State private var window: DailyTokenUsagePresentation.Window = .month
    private let rangeDefaults: UserDefaults?
    @State private var selectedDate: Date?
    @State private var hoveredDate: Date?
    @State private var showingInfo = false
    @Environment(\.colorScheme) private var colorScheme

    init(snapshot: TokenUsageSnapshot, isRefreshing: Bool = false,
         openSettings: @escaping () -> Void = {}, bundle: Bundle = .main,
         window: DailyTokenUsagePresentation.Window? = nil, preferences: UserDefaults = .standard) {
        self.snapshot = snapshot; self.isRefreshing = isRefreshing
        self.openSettings = openSettings; self.bundle = bundle
        self.rangeDefaults = window == nil ? preferences : nil
        let saved = DailyTokenUsagePresentation.Window(rawValue: preferences.integer(forKey: DailyTokenUsagePresentation.windowPreferenceKey)) ?? .month
        self._window = State(initialValue: window ?? saved)
    }

    private var focusedDay: TokenUsageDay? {
        let date = hoveredDate ?? selectedDate
        return date.flatMap { value in snapshot.days.first { $0.date == value } }
    }
    private var days: [TokenUsageDay] { DailyTokenUsagePresentation.days(snapshot.days, in: window) }
    private var agents: [TokenAgent] { TokenAgent.allCases.filter { agent in days.contains { ($0.byAgent[agent]?.total ?? 0) > 0 } } }
    private var windowAmount: String { DailyTokenUsagePresentation.windowAmount(days) }
    private var maximum: Int64 { days.map(\.total).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            heading
            HStack(spacing: 8) {
                metric("status.todayUsage", amount: DailyTokenUsagePresentation.amount(snapshot.days.last))
                metric(nil, amount: windowAmount)
            }
            chart
            if !agents.isEmpty {
                legend
            }
        }
        .statusHUDSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("daily-token-usage")
        .onDisappear { dismissDetail() }
    }

    private func localized(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
    private var heading: some View {
        HStack(spacing: 4) {
            Text("usage.title", bundle: bundle).font(.system(size: 12, weight: .semibold))
            Button { dismissDetail(); showingInfo = true } label: {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(StatusHUDStyle.tertiary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("usage.about", bundle: bundle))
            .accessibilityIdentifier("usage-info")
            Spacer(minLength: 2)
            ZStack {
                Color.clear
                if isRefreshing { ProgressView().controlSize(.mini).scaleEffect(0.6) }
            }.frame(width: 10, height: 10).accessibilityHidden(!isRefreshing)
            HStack(spacing: 0) {
                ForEach(DailyTokenUsagePresentation.Window.allCases, id: \.rawValue) { value in
                    Button {
                        dismissDetail(); window = value
                        rangeDefaults?.set(value.rawValue, forKey: DailyTokenUsagePresentation.windowPreferenceKey)
                    } label: {
                        Text(String(format: localized("status.rangeDays"), value.rawValue))
                            .font(.system(size: 10, weight: window == value ? .semibold : .regular))
                            .foregroundStyle(window == value ? Color.primary : StatusHUDStyle.secondary)
                            .frame(width: 37, height: 18)
                            .background(RoundedRectangle(cornerRadius: 6).fill(window == value ? StatusHUDStyle.card : Color.clear))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(window == value ? .isSelected : [])
                    .accessibilityIdentifier("usage-range-\(value.rawValue)")
                }
            }.padding(2).background(RoundedRectangle(cornerRadius: 8).fill(StatusHUDStyle.inset))
        }
        .popover(isPresented: $showingInfo, arrowEdge: .trailing) { information }
    }

    private func metric(_ label: LocalizedStringKey?, amount: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let label { Text(label, bundle: bundle) }
                else { Text(String(format: localized("status.windowUsage"), window.rawValue)) }
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(StatusHUDStyle.tertiary)
            .lineLimit(1).minimumScaleFactor(0.9)
            Text(verbatim: amount).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(StatusHUDStyle.inset))
    }

    private var chart: some View {
        HStack(alignment: .top, spacing: 5) {
            VStack(spacing: 3) {
                GeometryReader { geometry in
                    let layout = DailyTokenUsagePresentation.ChartLayout(days: days, width: geometry.size.width, agentCount: agents.count)
                    ZStack(alignment: .topLeading) {
                        Path { path in
                            for y in [CGFloat(0), geometry.size.height / 2, geometry.size.height] {
                                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                        }.stroke(StatusHUDStyle.line, style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                        HStack(alignment: .bottom, spacing: 2) {
                            ForEach(days) { day in
                                dayColumn(day, height: geometry.size.height, barHeight: layout.barHeight(day.total))
                                    .frame(maxWidth: .infinity)
                            }
                        }

                    }
                    .overlay {
                        DailyTokenUsagePointer(days: days, focusedDay: showingInfo ? nil : focusedDay,
                            pinned: selectedDate != nil && (hoveredDate == nil || hoveredDate == selectedDate),
                            bundle: bundle, scheme: colorScheme,
                            onHover: { index in hoveredDate = index.map { days[$0].date } },
                            onSelect: { index in togglePin(days[index].date) }, onCommand: handleCommand)
                    }
                }.frame(height: DailyTokenUsagePresentation.ChartLayout.height)
                GeometryReader { geometry in
                    ForEach(Array(Set([0, days.count / 2, days.count - 1])).filter { days.indices.contains($0) }.sorted(), id: \.self) { index in
                        Group {
                            if index == days.count - 1 { Text("usage.today", bundle: bundle) }
                            else { Text(days[index].date, format: .dateTime.month(.twoDigits).day(.twoDigits)) }
                        }.font(.system(size: 9)).foregroundStyle(StatusHUDStyle.tertiary).monospacedDigit()
                            .position(x: DailyTokenUsagePresentation.columnCenter(index, count: days.count, width: geometry.size.width), y: 6)
                    }
                }.frame(height: 13)
            }
            // Thirty narrow columns need space for the centered edge labels.
            // The plot, labels and pointer share the same inset geometry; 7 days is unchanged.
            .padding(.horizontal, window == .month ? 14 : 0)
            VStack {
                Text(verbatim: maximum > 0 ? axisAmount(maximum) : "—")
                Spacer()
                Text(verbatim: maximum > 0 ? axisAmount(maximum / 2) : "—")
                Spacer()
                Text(verbatim: "0")
            }.font(.system(size: 9)).foregroundStyle(StatusHUDStyle.tertiary).monospacedDigit()
                .frame(width: 30, height: DailyTokenUsagePresentation.ChartLayout.height + 8).offset(y: -4)
        }
        .accessibilityLabel(Text("usage.chart", bundle: bundle))
        .accessibilityAdjustableAction { direction in moveSelection(direction == .increment ? 1 : -1) }
    }
    private func axisAmount(_ value: Int64) -> String { DailyTokenUsagePresentation.compact(value).replacingOccurrences(of: ".0", with: "") }

    private func dayColumn(_ day: TokenUsageDay, height: CGFloat, barHeight: CGFloat) -> some View {
        let selected = focusedDay?.id == day.id && (selectedDate != nil || hoveredDate != nil)
        let agents = TokenAgent.allCases.filter { (day.byAgent[$0]?.total ?? 0) > 0 }
        return Button {
            togglePin(day.date)
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(selected ? Color.primary.opacity(0.055) : Color.clear)
                if day.total > 0 {
                    VStack(spacing: 0) {
                        ForEach(agents.reversed(), id: \.rawValue) { agent in
                            let value = day.byAgent[agent]?.total ?? 0
                            Rectangle().fill(DailyTokenUsagePresentation.color(agent))
                                .frame(height: barHeight * Double(value) / Double(day.total))
                        }
                    }
                    .frame(height: barHeight)
                    .frame(maxWidth: window == .week ? 18 : .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .opacity(selectedDate != nil || hoveredDate != nil ? (selected ? 1 : 0.55) : 1)
                } else if day.coverage == .complete {
                    RoundedRectangle(cornerRadius: 0.5).fill(StatusHUDStyle.tertiary.opacity(0.6)).frame(height: 1.5)
                } else if day.coverage != .notStarted {
                    Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: 8, y: 0)) }
                        .stroke(day.coverage == .unknown ? StatusHUDStyle.amber : StatusHUDStyle.tertiary,
                                style: StrokeStyle(lineWidth: 1, dash: [1, 2])).frame(width: 8, height: 1)
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if selected { Capsule().fill(Color.primary).frame(width: 1.5, height: 3).offset(y: 4) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(day.date.formatted(date: .abbreviated, time: .omitted)))
        .accessibilityValue(Text(DailyTokenUsagePresentation.amount(day) + " · " + NSLocalizedString(DailyTokenUsagePresentation.coverageKey(day.coverage), comment: "usage coverage")))
        .accessibilityHint(Text("usage.dayHint", bundle: bundle))
        .accessibilityIdentifier("usage-day-" + String(Int(day.date.timeIntervalSince1970)))
        .onMoveCommand { direction in
            switch direction { case .left: moveSelection(-1); case .right: moveSelection(1); default: break }
        }
    }

    private func moveSelection(_ amount: Int) {
        let current = hoveredDate ?? selectedDate
        hoveredDate = nil
        selectedDate = DailyTokenUsagePresentation.movedDate(current, by: amount, days: days)
    }

    private func togglePin(_ date: Date) {
        hoveredDate = nil
        selectedDate = selectedDate == date ? nil : date
    }

    private func dismissDetail() { hoveredDate = nil; selectedDate = nil }

    private func handleCommand(_ command: DailyTokenUsagePointer.Command) {
        switch command {
        case .left: moveSelection(-1)
        case .right: moveSelection(1)
        case .first: hoveredDate = nil; selectedDate = days.first?.date
        case .last: hoveredDate = nil; selectedDate = days.last?.date
        case .activate: if let day = focusedDay { togglePin(day.date) }
        case .dismiss: dismissDetail()
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach(agents, id: \.rawValue) { agent in
                HStack(spacing: 4) {
                    Circle().fill(DailyTokenUsagePresentation.color(agent)).frame(width: 5, height: 5)
                    Text(verbatim: agent.name).lineLimit(1)
                }
            }
        }
        .font(.system(size: 9)).foregroundStyle(StatusHUDStyle.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage-legend")
    }

    var information: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("usage.about", bundle: bundle).font(.system(size: 13, weight: .semibold))
                Text("usage.autoRefresh", bundle: bundle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Button {
                    showingInfo = false
                    // Dismiss the nested popover before activating Settings.
                    DispatchQueue.main.async { openSettings() }
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 13)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(Text("usage.configure", bundle: bundle))
                .help(Text("usage.configure", bundle: bundle))
                .accessibilityIdentifier("usage-open-settings")
            }
            .padding(.bottom, 8)
            Divider().opacity(0.5).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 6) {
                informationRow("usage.label.tokens", "usage.countingScope")
                informationRow("usage.label.data", "usage.dataScope")
                informationRow("usage.label.integration", "usage.collectionScope")
                informationRow("usage.label.dsh", "usage.dshScope")
                informationRow("usage.label.agy", "usage.agyScope")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func informationRow(_ label: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label, bundle: bundle)
                .fontWeight(.bold).foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: true)
                .frame(width: 56, alignment: .leading)
            Text(value, bundle: bundle)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5)).lineSpacing(2)
        .accessibilityElement(children: .combine)
    }

}
