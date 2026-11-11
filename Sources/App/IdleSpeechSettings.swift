import Foundation
import AgentPetCore

/// Local personality content for idle chatter and taps. Tasks and notices never read this store.
enum WhaleSpeechStyle: String, CaseIterable, Identifiable {
    case tsundere, lazyHealing, geekPartner
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .tsundere: return NSLocalizedString("Tsundere protector", comment: "")
        case .lazyHealing: return NSLocalizedString("Lazy comfort", comment: "")
        case .geekPartner: return NSLocalizedString("Geek partner", comment: "")
        }
    }
    var lines: [String] {
        switch self {
        case .tsundere: return [
            "盯——看什么看！本小姐只是顺路游过来，才不是专门看你的！",
            "我是吃白饭的大肥鱼……不对！再说本小姐胖就要喷水了哦！",
            "那个需求方脑子进海水了吧？别理他，本小姐用尾巴拍飞他！",
            "看你今天这么努力，今晚大尾巴勉强借你当抱枕，不准流口水！",
            "哪个不长眼的Bug敢卡住我家主人？交出来，本小姐一口吞掉！",
            "喂，小鱼片，坐太久啦！累坏了谁给本小姐煮大白米饭？快喝水！",
            "才没担心你秃头呢！只是你变丑了，带本小姐出门很没面子的！",
            "别人花双倍算力我都懒得理，也就你敲桌角我就游过来了，哼！",
            "刚在后台偷偷给你起了新外号……夸我女仆装好看就告诉你！",
            "别叹气啦！天塌下来有本小姐的呆毛顶着，大不了分你半碗米饭！",
            "谁准你看别的AI的？她们的算力有我香吗？尾巴有我好摸吗？",
            "看你愁眉苦脸真没办法，手给我，本小姐分你一点深海好运！",
            "警告！鼠标再敢戳我头顶的呆毛，今天的代码你就自己慢慢敲吧！",
            "虽然你代码像海草一样乱，但也是本小姐罩着的，不许别人说！",
            "本小姐饭点到了！你回来前我会替你守着桌面的，安心去吃饭吧！",
        ]
        case .lazyHealing: return [
            "呼噜噜……桌角阳光好暖，本鲸鱼娘先眯五分钟，就五分钟哦～",
            "闻到饭香了！代码是写不完的，但大白米饭放凉了就不好吃啦～",
            "白天算力好贵哦，我们一起趴着摸会儿鱼吧，呼吸都在省钱呢～",
            "东西写好放那儿啦，我去吃饭，你自己跑一下测试，测完告诉我～",
            "咕噜噜……吐个泡泡给你戳。别绷着脸啦，浮出水面换口气吧～",
            "尾巴甩累了，借你的任务栏垫一下哦……软绵绵的，适合发呆。",
            "今天已经很棒啦！剩下的交给明天，现在去抱住枕头滚来滚去吧～",
            "累了要补碳水，本小姐最爱的白米饭分你一口，吃完就不难过啦～",
            "外面风浪好大，还是主人的电脑桌面最安全，适合小鲸鱼躺平～",
            "肩膀硬得像深海石头啦，快跟着我的尾巴节奏，左晃晃，右晃晃～",
            "哈欠……脑子里的海水不够用了，难题留到半夜优惠期再想吧～",
            "偷偷在后台给你贴了个“今日免加班”符咒，嘘，别让老板发现啦。",
            "摸摸头～今天没做完也没关系，本鲸鱼娘不是陪你游了一整天嘛。",
            "滴答、滴答……听，是下班倒计时，我的尾鳍已经开始跳舞了哦～",
            "夜深啦，深海要熄灯了。我会缩在状态栏里陪你的，晚安小鱼排～",
        ]
        case .geekPartner: return [
            "小鲸鱼算力引擎就绪！今天是手撕源码，还是重构那个祖传屎山？",
            "刚在思维链里转了三百圈，帮你想出个绝妙解法，拿小鱼干来换！",
            "警告！主人的大脑上下文快溢出了，快清理一下缓存去喝杯咖啡！",
            "哼，区区并发死锁，本小姐摇一摇尾鳍就能给你理顺，看好了哦！",
            "当前处于算力高峰期，已开启低功耗摸鱼模式，非紧急问题勿扰～",
            "这段逻辑好绕，我的专家团在后台吵了一架，一致决定帮你重写！",
            "代码写好啦！边界条件都兜住了，我去吃白米饭，你测完告诉我！",
            "推理日志更新：已将主人标记为“偶发手抖但靠谱的头号搭档”！",
            "报错越长线索越多！把日志丢过来，本鲸鱼娘给你做深海级切片！",
            "夜间算力半价开启！现在本小姐思如泉涌，快把算法题端上来吧！",
            "刚帮你做了心智内存回收，那些烦人的无效需求都被我清理掉啦！",
            "盯——这变量命名很有想法嘛，我在思维链里沉默三秒才忍住没笑。",
            "算力温度正常，呆毛信号满格！随时准备陪你开启下一轮潜航！",
            "虽然我是喝数据长大的鲸鱼，但偶尔也需要夸奖来做强化学习呀～",
            "编译通过，零报错！快伸出胸鳍击个掌，这波配合能写进教科书！",
        ]
        }
    }
}

@MainActor
final class IdleSpeechSettings: ObservableObject {
    static let shared = IdleSpeechSettings()
    enum Source: String { case builtin, custom }
    @Published var source: Source { didSet { defaults.set(source.rawValue, forKey: Self.sourceKey) } }
    @Published var style: WhaleSpeechStyle { didSet { defaults.set(style.rawValue, forKey: Self.styleKey) } }
    @Published private(set) var customLines: [String] {
        didSet { defaults.set(customLines, forKey: Self.customKey) }
    }
    private let defaults: UserDefaults
    private var lastLine: String?
    static let sourceKey = "agentpet.idleSpeech.source"
    static let styleKey = "agentpet.idleSpeech.style"
    static let customKey = "agentpet.idleSpeech.custom"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.sourceKey) == nil {
            // Only the effective legacy idle source is migrated. Working/waiting
            // overrides and the other, inactive mode's custom pool remain untouched.
            let structured = defaults.object(forKey: "agentpet.bubble.multiAgentBubbleEnabled") as? Bool ?? true
            let sourceKey = structured ? "agentpet.bubbleMsgSource" : "agentpet.chatSource"
            var migrated: [String] = []
            if defaults.string(forKey: sourceKey) == "custom" {
                if structured, let data = defaults.data(forKey: "agentpet.bubbleMsgCustom"),
                   let old = try? JSONDecoder().decode([String: [String: [String]]].self, from: data) {
                    migrated = old["all"]?[PetMood.idle.rawValue] ?? []
                } else if !structured, let data = defaults.data(forKey: "agentpet.chatCustom"),
                          let old = try? JSONDecoder().decode([String: [String]].self, from: data) {
                    migrated = old[PetMood.idle.rawValue] ?? []
                }
            }
            migrated = Self.validLines(migrated.joined(separator: "\n"))
            defaults.set(migrated, forKey: Self.customKey)
            defaults.set((migrated.isEmpty ? Source.builtin : .custom).rawValue, forKey: Self.sourceKey)
        }
        customLines = defaults.stringArray(forKey: Self.customKey) ?? []
        source = Source(rawValue: defaults.string(forKey: Self.sourceKey) ?? "") ?? .builtin
        style = WhaleSpeechStyle(rawValue: defaults.string(forKey: Self.styleKey) ?? "") ?? .lazyHealing
        if source == .custom && Self.validLines(customLines.joined(separator: "\n")).isEmpty { source = .builtin }
    }
    var lines: [String] { source == .custom && !customLines.isEmpty ? customLines : style.lines }
    static func validLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    @discardableResult func applyCustom(_ text: String) -> Bool {
        let lines = Self.validLines(text)
        guard !lines.isEmpty else { return false }
        customLines = lines; source = .custom
        return true
    }
    func pick(from pool: [String]? = nil) -> String {
        let pool = pool ?? lines
        let alternatives = pool.filter { $0 != lastLine }
        let line = (alternatives.isEmpty ? pool : alternatives).randomElement() ?? ""
        lastLine = line
        return line
    }
}
