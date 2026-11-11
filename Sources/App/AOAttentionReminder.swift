import SwiftUI
import AgentPetCore

/// A saved attention event, not a claim about the session's current activity.
struct AOAttentionReminder {
    let receipt: AOAttentionReceipt

    var sourceID: String { receipt.observation.sessionID }
    var sourceLabel: String {
        let name = receipt.observation.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, name != sourceID else { return sourceID }
        return sourceID + " · " + name
    }
    var occurredAt: Date {
        receipt.waitingAt ?? receipt.observation.activityAt ?? receipt.observation.updatedAt
    }
    var message: String {
        receipt.observation.activity == .waitingInput
            ? NSLocalizedString("ao.attention.previousInput", value: "此前等待用户输入", comment: "")
            : NSLocalizedString("ao.attention.previousAttention", value: "此前等待人工处理", comment: "")
    }
}

struct AOAttentionReminderView: View {
    let receipt: AOAttentionReceipt
    let fontSize: CGFloat
    let backgroundOpacity: Double
    let textOpacity: Double
    var acknowledge: () -> Void

    private var reminder: AOAttentionReminder { .init(receipt: receipt) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: NSLocalizedString("ao.attention.title", value: "AO 提醒 · %@", comment: ""), reminder.sourceLabel))
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(TaskBubbleStyle.waiting)
                    .lineLimit(1)
                Text(reminder.message + " · " + reminder.occurredAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.system(size: fontSize))
                    .foregroundStyle(TaskBubbleStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .taskBubbleText(backgroundOpacity: backgroundOpacity, textOpacity: textOpacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(reminder.sourceLabel + "\n" + NSLocalizedString("ao.attention.historyHint",
                value: "这是此前保存的等待提醒，不代表会话仍在等待。当前状态以任务状态行为准。", comment: ""))
            Button(action: acknowledge) {
                Text(NSLocalizedString("ao.attention.acknowledge", value: "知道了", comment: ""))
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(TaskBubbleStyle.foreground)
                    .taskBubbleText(backgroundOpacity: backgroundOpacity, textOpacity: textOpacity)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(TaskBubbleStyle.ink.opacity(0.75 * textOpacity)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(NSLocalizedString("ao.attention.acknowledgeHint",
                value: "仅收起这一条提醒；不会批准操作，也不会标记会话回复已读。", comment: ""))
            .accessibilityLabel(NSLocalizedString("ao.attention.acknowledge", value: "知道了", comment: "") + " · " + reminder.sourceLabel)
        }
    }
}
