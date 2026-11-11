import Foundation
import OSLog
import AgentPetCore

struct SystemNotice: Equatable {
    enum Kind {
        case lowQuota, quotaRecovered, pomodoro
        case clickThroughOn, clickThroughOff, clickThroughPaused

        var isClickThroughFeedback: Bool {
            switch self {
            case .clickThroughOn, .clickThroughOff, .clickThroughPaused: return true
            default: return false
            }
        }
        var isPriority: Bool { !isClickThroughFeedback }
    }
    let id: String
    let kind: Kind
    let title: String
    let body: String
    let legacyText: String
    var shortBody: String? = nil
    var confirmationLabel: String? = nil
    var requiresAcknowledgment: Bool { kind == .pomodoro }

    static func text(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "system notice")
    }
    static func format(_ key: String, _ fallback: String, _ values: Int...) -> String {
        String(format: text(key, fallback), arguments: values)
    }
    var shortTitle: String {
        switch kind {
        case .pomodoro: return Self.text("Timer: ", "番茄：")
        case .clickThroughPaused: return ""
        case .clickThroughOn, .clickThroughOff: return Self.text("Click-through: ", "穿透：")
        default: return Self.text("Codex: ", "Codex：")
        }
    }

    /// Shared accent palette for the existing notice renderer. The click-through
    /// feedback is green when active, orange when blocked, and
    /// neutral gray when off; no user-facing color setting is added.
    var accentRGB: (Double, Double, Double) {
        switch kind {
        case .lowQuota: return (0.91, 0.54, 0.21)
        case .quotaRecovered: return (0.25, 0.62, 0.40)
        case .pomodoro: return (0.50, 0.44, 0.74)
        case .clickThroughOn: return (0.25, 0.62, 0.40)
        case .clickThroughPaused: return (0.91, 0.54, 0.21)
        case .clickThroughOff: return (0.56, 0.59, 0.64)
        }
    }

    static func lowQuota(_ notice: CodexLowQuotaReminder.Notice) -> Self {
        .init(id: notice.id, kind: .lowQuota, title: text("Codex quota: ", "Codex额度提醒："),
              body: notice.percent.map { format("5h quota: %d%% left", "5小时额度剩余 %d%%", $0) } ?? notice.text,
              legacyText: notice.text, shortBody: notice.percent.map { format("5h quota: %d%% left", "5小时额度剩余 %d%%", $0) })
    }
    static func recovered(_ notice: CodexQuotaRecovery.Notice) -> Self {
        .init(id: notice.id, kind: .quotaRecovered, title: text("Codex restored: ", "Codex额度恢复："),
              body: format("5h quota restored, %d%% left", "5小时额度已恢复，剩余 %d%%", notice.percent),
              legacyText: "Codex 五小时额度已恢复，剩余 \(notice.percent)%。",
              shortBody: format("Quota restored, %d%% left", "额度已恢复，剩余 %d%%", notice.percent))
    }

    static let clickThroughFeedbackID = "agentpet.clickThroughFeedback"

    static func clickThrough(enabled: Bool, suspended: Bool = false) -> Self {
        let kind: Kind = !enabled ? .clickThroughOff : suspended ? .clickThroughPaused : .clickThroughOn
        let body: String
        let short: String
        switch kind {
        case .clickThroughOn:
            body = text("On", "已开启")
            short = text("On", "已开启")
        case .clickThroughPaused:
            body = text("Could not enable. Handle waiting tasks first", "开启失败，请优先处理等待任务")
            short = body
        default:
            body = text("Off", "已关闭")
            short = text("Off", "已关闭")
        }
        let title = kind == .clickThroughPaused ? "" : text("Bubble click-through: ", "气泡点击穿透：")
        return .init(id: clickThroughFeedbackID, kind: kind, title: title, body: body,
                     legacyText: title + body, shortBody: short)
    }
}

/// A current notice and at most one deferred timer notice. No offline queue.
struct SystemNoticeClock {
    struct Entry: Equatable { let notice: SystemNotice; var remaining: TimeInterval = 8 }
    private(set) var current: Entry?
    private(set) var pending: Entry?
    private var sampledAt: Date?
    private var wasVisible = false

    mutating func post(_ notice: SystemNotice, now: Date) {
        let entry = Entry(notice: notice)

        // Click-through feedback is a low-priority operation result. It may
        // replace an earlier feedback in place (latest state wins) but never
        // displaces a current priority notice. It is not queued, so an old
        // toggle cannot replay after the current notice expires.
        if notice.kind.isClickThroughFeedback {
            // Never delay a deferred priority notice behind operation feedback.
            guard pending == nil,
                  current == nil || current?.notice.kind.isClickThroughFeedback == true else { return }
            current = entry; sampledAt = now; wasVisible = false
            return
        }

        // A priority notice preempts click-through feedback immediately.
        if current?.notice.kind.isClickThroughFeedback == true {
            current = entry; sampledAt = now; wasVisible = false
            return
        }

        guard current?.notice.id != notice.id, pending?.notice.id != notice.id else { return }
        if notice.kind == .pomodoro, current?.notice.kind != .pomodoro, current != nil {
            pending = entry; return
        }
        if notice.kind != .pomodoro, current?.notice.kind == .pomodoro { pending = current }
        current = entry; sampledAt = now; wasVisible = false
    }
    mutating func advance(now: Date, visible: Bool) {
        if let at = sampledAt, wasVisible {
            let remaining = max(0, (current?.remaining ?? 0) - max(0, now.timeIntervalSince(at)))
            current?.remaining = remaining
        }
        if current?.remaining == 0, current?.notice.requiresAcknowledgment != true {
            current = pending; pending = nil; wasVisible = false
        } else { wasVisible = visible }
        sampledAt = now
    }
    mutating func dismissPomodoro(id: String? = nil) {
        if pending?.notice.kind == .pomodoro, id == nil || pending?.notice.id == id { pending = nil }
        if current?.notice.kind == .pomodoro, id == nil || current?.notice.id == id {
            current = pending; pending = nil; sampledAt = nil; wasVisible = false
        }
    }
    mutating func clear() { self = Self() }
}

@MainActor
final class SystemNoticeCenter: ObservableObject {
    @Published private(set) var current: SystemNotice?
    @Published private(set) var fractionRemaining: Double = 1
    private var clock = SystemNoticeClock()
    private var timer: Timer?
    private let visible: (String) -> Bool
    private let changed: () -> Void
    private var confirmation: (id: String, action: () -> Void)?

    init(visible: @escaping (String) -> Bool, changed: @escaping () -> Void) {
        self.visible = visible; self.changed = changed
    }
    func post(_ notice: SystemNotice, onConfirmed: (() -> Void)? = nil) {
        #if AGENTPET_LOCAL
        Logger(subsystem: AgentPetPaths.bundleIdentifier, category: "pomodoro-notice").notice("post kind=\(String(describing: notice.kind), privacy: .public)")
        #endif
        tick()
        if clock.current?.notice.id == notice.id || clock.pending?.notice.id == notice.id {
            // The click-through operation feedback uses one stable key and
            // updates in place; every other notice keeps its duplicate guard.
            guard notice.kind.isClickThroughFeedback else { return }
        }
        if notice.kind == .pomodoro { confirmation = onConfirmed.map { (notice.id, $0) } }
        clock.post(notice, now: Date()); publish(); schedule()
    }
    func clear() {
        #if AGENTPET_LOCAL
        Logger(subsystem: AgentPetPaths.bundleIdentifier, category: "pomodoro-notice").notice("clear all notices")
        #endif
        clock.clear(); publish(); schedule()
    }
    func dismissPomodoro(id: String? = nil) {
        #if AGENTPET_LOCAL
        Logger(subsystem: AgentPetPaths.bundleIdentifier, category: "pomodoro-notice").notice("dismiss timer notice explicit=\(id != nil, privacy: .public)")
        #endif
        clock.dismissPomodoro(id: id); publish(); schedule()
    }
    func confirmPomodoro(id: String) {
        guard current?.kind == .pomodoro, current?.id == id else { return }
        let action = confirmation?.id == id ? confirmation?.action : nil
        dismissPomodoro(id: id)
        action?()
    }
    func tick(now: Date = Date()) {
        clock.advance(now: now, visible: current.map { visible($0.id) } ?? false)
        publish()
        if current == nil || (current?.requiresAcknowledgment == true && fractionRemaining == 0) {
            timer?.invalidate(); timer = nil
        }
    }
    private func publish() {
        if let id = confirmation?.id, clock.current?.notice.id != id, clock.pending?.notice.id != id {
            confirmation = nil
        }
        let next = clock.current?.notice
        let fraction = (clock.current?.remaining ?? 8) / 8
        if fractionRemaining != fraction { fractionRemaining = fraction }
        if current != next {
            #if AGENTPET_LOCAL
            Logger(subsystem: AgentPetPaths.bundleIdentifier, category: "pomodoro-notice").notice("current kind=\(next.map { String(describing: $0.kind) } ?? "none", privacy: .public)")
            #endif
            current = next; changed()
        }
    }
    private func schedule() {
        guard current != nil, !(current?.requiresAcknowledgment == true && fractionRemaining == 0)
        else { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor [weak self] in self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
}
