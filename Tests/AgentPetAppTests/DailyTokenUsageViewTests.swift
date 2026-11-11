import XCTest
import SwiftUI
import AppKit
import AgentPetCore
@testable import agentpet

@MainActor
final class DailyTokenUsageViewTests: XCTestCase {
    override nonisolated func setUpWithError() throws { try TestIsolation.require() }
    func testUnknownDoesNotDisplayZeroAndSelectionClamps() {
        let day = TokenUsageDay(date: Date(), coverage: .unknown)
        XCTAssertEqual(DailyTokenUsagePresentation.amount(day), "—")
        XCTAssertEqual(DailyTokenUsagePresentation.amount(.init(date: day.date, coverage: .complete)), "0")
        XCTAssertEqual(DailyTokenUsagePresentation.movedDate(day.date, by: -1, days: [day]), day.date)
        XCTAssertEqual(Set(TokenAgent.allCases.map(DailyTokenUsagePresentation.colorHex)).count, 5)
        let complete = TokenUsageDay(date: day.date, coverage: .complete)
        XCTAssertEqual(DailyTokenUsagePresentation.windowAmount([complete, day]), "—")
        XCTAssertEqual(DailyTokenUsagePresentation.windowAmount([complete]), "0")
        XCTAssertEqual(DailyTokenUsagePresentation.windowAmount([]), "—")
    }

    func testExternalLegendPreservesFullHeightAndLinearScaleAcrossDates() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        var days = (0..<30).map { TokenUsageDay(date: day.addingTimeInterval(Double($0) * 86_400), coverage: .complete) }
        let equal = try TokenBuckets(input: 18_000, cacheRead: 0, cacheWrite: 0, output: 0)
        days[0].byAgent = [.dsh: equal]
        days[20].byAgent = [.dsh: equal]
        days[29].byAgent = [.dsh: try .init(input: 36_000, cacheRead: 0, cacheWrite: 0, output: 0)]
        for count in [4, 5] {
            let layout = DailyTokenUsagePresentation.ChartLayout(days: days, width: 272, agentCount: count)
            XCTAssertEqual(layout.barHeight(days[0].total), layout.barHeight(days[20].total), accuracy: 0.001,
                           "Legend avoidance must not shrink only the left dates")
            XCTAssertEqual(layout.barHeight(days[29].total), layout.barHeight(days[0].total) * 2, accuracy: 0.001)
            XCTAssertEqual(layout.barHeight(days[29].total), 112, accuracy: 0.001, "An external legend must not consume plot height")
            XCTAssertEqual(layout.barHeight(360), 1.12, accuracy: 0.001, "Small values must keep the same linear scale")
            XCTAssertLessThanOrEqual(layout.barHeight(days[29].total), 112)
            XCTAssertEqual(layout.barHeight(0), 0)
        }
        days[0].byAgent = [.dsh: try .init(input: 36_000, cacheRead: 0, cacheWrite: 0, output: 0)]
        let emptyLeft = DailyTokenUsagePresentation.ChartLayout(days: days, width: 272, agentCount: 4)
        XCTAssertEqual(emptyLeft.barHeight(36_000), 112, accuracy: 0.001,
                       "A first-day peak fills the same height as a last-day peak")
    }
    func testWindowTotalsCoverageMetricsAndColumnCenters() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let days = try (0..<30).map { n in
            TokenUsageDay(date: start.addingTimeInterval(Double(n) * 86_400),
                byAgent: [.codex: try .init(input: Int64((n + 1) * 100), cacheRead: 0, cacheWrite: 0, output: 0)], coverage: .complete)
        }
        let week = DailyTokenUsagePresentation.days(days, in: .week)
        XCTAssertEqual(week.count, 7); XCTAssertEqual(week.first?.date, days[23].date)
        XCTAssertEqual(DailyTokenUsagePresentation.days(days, in: .month).count, 30)
        XCTAssertEqual(DailyTokenUsagePresentation.windowAmount(week), "18.9k")
        for count in [7, 30] {
            let width: CGFloat = 230, column = (width - CGFloat(count - 1) * 2) / CGFloat(count)
            let center = DailyTokenUsagePresentation.columnCenter
            XCTAssertEqual(center(0, count, width), column / 2, accuracy: 0.001)
            XCTAssertEqual(center(count - 1, count, width), width - column / 2, accuracy: 0.001)
            XCTAssertEqual(center(count / 2, count, width), CGFloat(count / 2) * (column + 2) + column / 2, accuracy: 0.001)
        }
    }

    func testNativeThirtyDayViewFitsHUDAndRendersAllSources() throws {
        _ = NSApplication.shared
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        var days: [TokenUsageDay] = []
        for n in 0..<30 {
            var agents: [TokenAgent: TokenBuckets] = [:]
            if n >= 10 {
                for (i, agent) in TokenAgent.allCases.enumerated() { agents[agent] = try .init(input: Int64((n * 41 + i * 79) % 3000 + 10), cacheRead: 400, cacheWrite: 10, output: 500) }
            }
            days.append(.init(date: calendar.date(byAdding: .day, value: n - 29, to: today)!, byAgent: agents, coverage: n < 10 ? .notStarted : n == 10 ? .partial : .complete))
        }
        let bundle = ProcessInfo.processInfo.environment["AGENTPET_USAGE_LPROJ"].flatMap(Bundle.init(path:)) ?? .main
        let state = TokenCollectionState(instance: .init(source: .dsh, root: URL(fileURLWithPath: "/fixture/dsh")),
            intervals: [.init(start: days[10].date)], checkedAt: Date(), quality: .complete)
        let host = NSHostingView(rootView: DailyTokenUsageView(snapshot: .init(days: days, states: [state]), bundle: bundle).padding(14).frame(width: 300).background(Color(nsColor: .windowBackgroundColor)))
        host.setFrameSize(host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 300, accuracy: 1); XCTAssertLessThan(host.fittingSize.height, 280, "Keep the compact height budget while fitting tiles and legend within the original 300pt HUD")
        if let directory = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"] {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("token-30day.png"))
            let empty = DailyTokenUsageView(snapshot: .init(days: days.map { .init(date: $0.date, coverage: .notStarted) }), bundle: bundle)
            let emptyHost = NSHostingView(rootView: empty.padding(14).frame(width: 300).background(Color(nsColor: .windowBackgroundColor)))
            let infoHost = NSHostingView(rootView: DailyTokenUsageView(snapshot: .init(days: days, states: [state]), bundle: bundle).information.background(Color(nsColor: .windowBackgroundColor)))
            var previews: [(String, NSView)] = [("token-empty", emptyHost), ("token-info", infoHost)]
            // Full history and five-source fixtures cover the external legend;
            // neither fixture touches the real ledger or integration state.
            let fullDays = try (0..<30).map { n -> TokenUsageDay in
                var agents: [TokenAgent: TokenBuckets] = [:]
                for (i, agent) in TokenAgent.allCases.enumerated() {
                    agents[agent] = try .init(input: Int64(1500 + (n * 1319 + i * 727) % 5000), cacheRead: 400, cacheWrite: 10, output: 500)
                }
                if n == 23 || n == 26 { agents = [:] }
                return .init(date: days[n].date, byAgent: agents,
                             coverage: n == 23 ? .unknown : n == 29 ? .partial : .complete)
            }
            let fourDays = fullDays.map { day -> TokenUsageDay in
                var day = day; day.byAgent.removeValue(forKey: .claude); return day
            }
            let full = DailyTokenUsageView(snapshot: .init(days: fourDays), bundle: bundle)
            previews.append(("token-full", NSHostingView(rootView: full.padding(14).frame(width: 300).background(Color(nsColor: .windowBackgroundColor)))))
            previews.append(("token-full-dark", NSHostingView(rootView: full.environment(\.colorScheme, .dark).padding(14).frame(width: 300).background(Color(nsColor: .windowBackgroundColor)))))
            previews.append(("token-five-sources", NSHostingView(rootView: DailyTokenUsageView(snapshot: .init(days: fullDays), bundle: bundle).padding(14).frame(width: 300).background(Color(nsColor: .windowBackgroundColor)))))
            if let lproj = ProcessInfo.processInfo.environment["AGENTPET_USAGE_LPROJ"] {
                let root = URL(fileURLWithPath: lproj).deletingLastPathComponent()
                for language in ["en", "zh-Hant", "vi"] {
                    let localization = try XCTUnwrap(Bundle(path: root.appendingPathComponent(language + ".lproj").path))
                    previews.append(("token-info-" + language, NSHostingView(rootView: DailyTokenUsageView(snapshot: .init(), bundle: localization).information.background(Color(nsColor: .windowBackgroundColor)))))
                }
            }
            previews.append(("token-info-dark", NSHostingView(rootView: DailyTokenUsageView(snapshot: .init(), bundle: bundle).information.environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))))
            previews.append(("token-week", NSHostingView(rootView: DailyTokenUsageView(snapshot: .init(days: fullDays), bundle: bundle, window: .week).padding(14).frame(width: 300).background(StatusHUDStyle.background))))
            var spike = fullDays
            spike[28].byAgent = [.dsh: try .init(input: 354_000_000, cacheRead: 0, cacheWrite: 0, output: 0)]
            let sparse = spike.enumerated().map { index, day -> TokenUsageDay in
                index < 28 ? .init(date: day.date, coverage: .notStarted) : day
            }
            previews.append(("token-sparse-spike", NSHostingView(rootView: DailyTokenUsageView(snapshot: .init(days: sparse), bundle: bundle).padding(14).frame(width: 300).background(StatusHUDStyle.background))))
            let provider = OpenUsageClient.Provider(id: "codex", displayName: "Codex", plan: nil, fractionLeft: 0.56, todayLabel: nil,
                windows: [.init(id: "primary", fractionLeft: 0.79, durationMinutes: 300, resetsAt: Date().addingTimeInterval(3600)),
                          .init(id: "secondary", fractionLeft: 0.56, durationMinutes: 10080, resetsAt: Date().addingTimeInterval(5 * 86400))])
            for scheme in [ColorScheme.light, .dark] {
                let quota = VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("status.quotaTitle", bundle: bundle).font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                    UsageQuotaView(provider: provider, compact: true, statusPresentation: true, bundle: bundle)
                }.statusHUDSection().padding(14).frame(width: 300).background(StatusHUDStyle.background).environment(\.colorScheme, scheme)
                previews.append((scheme == .dark ? "quota-dark" : "quota-light", NSHostingView(rootView: quota)))
            }
            var layouts: [String: [String: Double]] = [:]
            for (name, view) in previews {
                view.setFrameSize(view.fittingSize)
                let preview = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                if name.hasSuffix("-dark") { preview.appearance = NSAppearance(named: .darkAqua) }
                preview.isReleasedWhenClosed = false; preview.contentView = view; preview.orderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2)); view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
                layouts[name] = ["width": view.frame.width, "height": view.frame.height]
                preview.close()
            }
            try JSONEncoder().encode(layouts).write(to: URL(fileURLWithPath: directory).appendingPathComponent("layout-sizes.json"))
        }
    }
}
