import AppKit
import SwiftUI
import XCTest
import AgentPetCore
@testable import agentpet

@MainActor
final class PetSpeechPanelTests: XCTestCase {
    func testSpeechTransitionsNeverCrossTaskPanel() throws {
        _ = NSApplication.shared
        let pet = PetController.shared, settings = BubbleSettings.shared
        let animation = pet.animationsEnabled, show = pet.showChat
        let enabled = settings.petBubbleEnabled, multi = settings.multiAgentBubbleEnabled
        defer {
            pet.animationsEnabled = animation; pet.showChat = show
            settings.petBubbleEnabled = enabled; settings.multiAgentBubbleEnabled = multi
        }
        pet.animationsEnabled = true; pet.showChat = true
        settings.petBubbleEnabled = true; settings.multiAgentBubbleEnabled = true
        let controller = PetWindowController()
        defer { controller.stop() }
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let now = Date()
        var session = AgentSession(id: "stack-transition", agentKind: .codex,
                                   state: .working, source: .hook, updatedAt: now)
        session.title = "窗口过渡回归"
        let specs = PetWindowPlanner.plan(sessions: [session], split: false,
                                         mappings: [], defaultPetID: "stack-transition")
        func sync(_ rows: [PetSpeechState.Row]) {
            controller.sync(specs: specs) { _ in
                .init(petID: "stack-transition", mood: .working, sessions: [session],
                      count: 1, chatLine: "", speechRows: rows)
            }
        }
        sync([])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let panels = NSApp.windows.filter { !existing.contains($0.windowNumber) }
        let body = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Body" })
        let speech = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Pet Messages" })
        let task = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Tasks" })
        let visible = try XCTUnwrap(body.screen?.visibleFrame)
        controller.moveWindow(forKey: "default", to: CGPoint(x: visible.midX, y: visible.minY + 50))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let originalBody = body.frame
        let rows = (0..<6).map { i in
            PetSpeechState.Row(id: UUID(), session: .init(session), label: "@Codex[\(i + 1)]",
                               itemID: "\(i)", text: "检查消息进出时的气泡位置", expiresAt: now.addingTimeInterval(3))
        }
        var checked = 0, overlaps = 0
        for count in [1, 3, 6, 2, 5, 0, 4, 1, 0] {
            sync(Array(rows.prefix(count)))
            for _ in 0..<20 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                XCTAssertEqual(body.frame, originalBody)
                if speech.isVisible && task.isVisible {
                    checked += 1
                    if task.frame.minY < speech.frame.maxY - 1 { overlaps += 1 }
                }
            }
        }
        print("STACK_TRANSITION checked=\(checked) overlapFrames=\(overlaps)")
        XCTAssertGreaterThan(checked, 50)
        XCTAssertEqual(overlaps, 0, "The speech panel must remain below the task panel throughout transitions")
    }

    func testIndependentNativePanelsKeepBodyFixedAndFollowVisibility() throws {
        _ = NSApplication.shared
        let settings = BubbleSettings.shared
        let old = settings.petBubbleEnabled
        let oldShow = PetController.shared.showChat
        defer { settings.petBubbleEnabled = old; PetController.shared.showChat = oldShow }
        settings.petBubbleEnabled = true; PetController.shared.showChat = true
        let controller = PetWindowController()
        defer { controller.stop() }
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let now = Date()
        let sessions = (1...7).map { i -> AgentSession in
            var s = AgentSession(id: "native-\(i)", agentKind: .codex, state: .working, source: .hook, updatedAt: now)
            s.title = "隔离演示任务 \(i)"; s.codexTurnID = "preview-turn"; s.turnStartedAt = now
            return s
        }
        let specs = PetWindowPlanner.plan(sessions: sessions, split: false, mappings: [], defaultPetID: "native-preview")
        var rows: [PetSpeechState.Row] = []
        func sync() {
            controller.sync(specs: specs) { _ in
                .init(petID: "native-preview", mood: .working, sessions: Array(sessions.prefix(2)), count: 2,
                      chatLine: "", speechRows: rows)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        sync()
        let panels = NSApp.windows.filter { !existing.contains($0.windowNumber) }
        let body = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Body" })
        let speech = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Pet Messages" })
        let task = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Tasks" })
        XCTAssertNotEqual(task.windowNumber, speech.windowNumber)
        XCTAssertTrue(speech.ignoresMouseEvents)
        // Give the stack room to grow on any display. A prior test may leave
        // the isolated fixture near the top edge, where screen clamping makes
        // the growth/visibility assertions depend on test order and resolution.
        let visible = try XCTUnwrap(body.screen?.visibleFrame)
        controller.moveWindow(forKey: "default", to: CGPoint(x: visible.midX, y: visible.minY + 50))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let original = body.frame
        let before = task.frame.minY
        for i in 0..<6 {
            rows.append(.init(id: UUID(), session: .init(sessions[i]), label: "@Codex[\(i + 1)]", itemID: "\(i)",
                text: i == 0 ? "正在检查认证逻辑" : "正在核对窗口布局与消息滚动是否正常…", expiresAt: now.addingTimeInterval(3)))
            sync()
            XCTAssertEqual(body.frame, original)
        }
        XCTAssertTrue(speech.isVisible)
        XCTAssertLessThanOrEqual(speech.frame.width, 293)
        XCTAssertGreaterThan(task.frame.minY, before + 100)
        XCTAssertGreaterThanOrEqual(task.frame.minY, speech.frame.maxY - 1)
        rows.removeFirst()
        rows.append(.init(id: UUID(), session: .init(sessions[6]), label: "@Codex[7]", itemID: "7",
                          text: "第七条进入，最旧条已移出", expiresAt: now.addingTimeInterval(3)))
        sync()
        XCTAssertEqual(body.frame, original)
        if let hold = ProcessInfo.processInfo.environment["AGENTPET_SPEECH_PREVIEW_SECONDS"].flatMap(Double.init) {
            RunLoop.main.run(until: Date().addingTimeInterval(min(hold, 45)))
        }
        controller.isVisible = false
        XCTAssertFalse(body.isVisible); XCTAssertFalse(task.isVisible); XCTAssertFalse(speech.isVisible)
        controller.isVisible = true
        XCTAssertTrue(body.isVisible); XCTAssertTrue(task.isVisible); XCTAssertTrue(speech.isVisible)
        rows = []; sync()
        XCTAssertFalse(speech.isVisible)
        XCTAssertEqual(body.frame, original)
        XCTAssertEqual(task.frame.minY, before, accuracy: 1)
    }

    func testIdleBubbleHugsTextAfterLengthChangesWithoutBlankViewport() throws {
        _ = NSApplication.shared
        let pet = PetController.shared, settings = BubbleSettings.shared
        let animation = pet.animationsEnabled, mode = settings.displayMode, hidden = settings.hiddenKinds
        defer { pet.animationsEnabled = animation; settings.displayMode = mode; settings.hiddenKinds = hidden }
        pet.animationsEnabled = false; settings.displayMode = .list; settings.hiddenKinds = []
        let controller = PetWindowController()
        defer { controller.stop() }
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let specs = PetWindowPlanner.plan(sessions: [], split: false, mappings: [], defaultPetID: "idle-layout")
        var sessions: [AgentSession] = [], line = "嗨"
        func sync() {
            controller.sync(specs: specs) { _ in
                .init(petID: "idle-layout", mood: sessions.isEmpty ? .idle : .working,
                      sessions: sessions, count: sessions.count, chatLine: "", idleText: sessions.isEmpty ? line : "")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        sync()
        let panels = NSApp.windows.filter { !existing.contains($0.windowNumber) }
        let body = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Body" })
        let task = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Tasks" })
        let speech = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Pet Messages" })
        let host = try XCTUnwrap(speech.contentView as? NSHostingView<PetSpeechView>)
        let original = body.frame
        var shortWidth: CGFloat = 0
        for text in ["嗨", "把咖啡变成代码 ☕", "认真检查气泡尺寸是否能够随不同文字长度正确变化", "好"] {
            line = text; sync()
            let natural = NSHostingView(rootView: PetSpeechView(model: host.rootView.model)).fittingSize
            XCTAssertTrue(speech.isVisible); XCTAssertFalse(task.isVisible)
            XCTAssertEqual(speech.frame.width, natural.width, accuracy: 1)
            XCTAssertEqual(speech.frame.height, natural.height, accuracy: 1)
            XCTAssertLessThanOrEqual(speech.frame.width, 292)
            XCTAssertLessThan(speech.frame.height, 80)
            if text == "嗨" { shortWidth = speech.frame.width }
            if text.count > 3 { XCTAssertGreaterThan(speech.frame.width, shortWidth) }
            XCTAssertEqual(body.frame, original)
        }
        sessions = (0..<6).map { i in
            var session = AgentSession(id: "task-\(i)", agentKind: .codex, state: .working, source: .hook, updatedAt: Date())
            session.title = "任务尺寸变化回归 \(i)"; return session
        }
        sync(); XCTAssertTrue(task.isVisible); XCTAssertFalse(speech.isVisible)
        sessions = []; line = "短句"; sync()
        XCTAssertFalse(task.isVisible); XCTAssertTrue(speech.isVisible)
        XCTAssertLessThan(speech.frame.height, 80); XCTAssertEqual(body.frame, original)
    }

    func testTallTaskViewportShrinksOnIdleAndOnlyScrollsAtScreenEdge() throws {
        _ = NSApplication.shared
        let pet = PetController.shared, settings = BubbleSettings.shared
        let show = pet.showChat, animation = pet.animationsEnabled
        let mode = settings.displayMode, hidden = settings.hiddenKinds, cap = settings.maxSessions
        let multi = settings.multiAgentBubbleEnabled
        defer {
            pet.showChat = show; pet.animationsEnabled = animation
            settings.displayMode = mode; settings.hiddenKinds = hidden; settings.maxSessions = cap
            settings.multiAgentBubbleEnabled = multi
        }
        pet.showChat = true; pet.animationsEnabled = false
        settings.displayMode = .list; settings.hiddenKinds = []; settings.maxSessions = 6
        settings.multiAgentBubbleEnabled = true
        let controller = PetWindowController()
        defer { controller.stop() }
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let specs = PetWindowPlanner.plan(sessions: [], split: false, mappings: [], defaultPetID: "layout-regression")
        var sessions = (0..<6).map { i in
            var s = AgentSession(id: "tall-\(i)", agentKind: .codex, state: .working, source: .hook, updatedAt: Date())
            s.title = "窗口尺寸变化检查 \(i)"; return s
        }
        func sync() {
            controller.sync(specs: specs) { _ in
                .init(petID: "layout-regression", mood: sessions.isEmpty ? .idle : .working,
                      sessions: sessions, count: sessions.count, chatLine: "", idleText: sessions.isEmpty ? "把咖啡变成代码 ☕" : "")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        sync()
        let panels = NSApp.windows.filter { !existing.contains($0.windowNumber) }
        let body = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Body" })
        let task = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Tasks" })
        let scroll = try XCTUnwrap(task.contentView as? NSScrollView)
        let host = try XCTUnwrap(scroll.documentView as? ClickThroughHostingView<PetTaskPanelView>)
        let model = host.rootView.model
        let originalBody = body.frame
        XCTAssertGreaterThan(task.frame.height, 100)
        sessions = []; sync()
        XCTAssertFalse(task.isVisible, "Idle chatter no longer leaves a visible task viewport")
        XCTAssertFalse(model.idleText.isEmpty)
        XCTAssertEqual(body.frame, originalBody)
        let visible = try XCTUnwrap(body.screen?.visibleFrame)
        controller.moveWindow(forKey: "default", to: CGPoint(x: body.frame.minX, y: visible.maxY - pet.petPoint - 65))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        sessions = (0..<6).map { i in
            var s = AgentSession(id: "edge-\(i)", agentKind: .codex, state: .working, source: .hook, updatedAt: Date())
            s.title = "顶部滚动检查 \(i)"; return s
        }
        sync()
        XCTAssertGreaterThan(host.frame.height, task.frame.height)
        XCTAssertLessThanOrEqual(task.frame.maxY, visible.maxY + 1)
        XCTAssertEqual(scroll.contentView.bounds.height, task.frame.height, accuracy: 1)
        sessions = []; sync()
        XCTAssertFalse(task.isVisible, "Leaving the tall task list hides its viewport")
    }

    func testHoverExpansionFitsFullTaskContentAndRestoresCollapsedWidth() throws {
        try checkHoverExpansion(side: nil)
    }

    func testRightPeekHoverKeepsTaskCollapsedAndDragOutRestoresExpansion() throws {
        try checkHoverExpansion(side: .right)
    }

    func testLeftPeekHoverKeepsTaskCollapsedAndDragOutRestoresExpansion() throws {
        try checkHoverExpansion(side: .left)
    }

    private func checkHoverExpansion(side: PetEdgeSide?) throws {
        try TestIsolation.require()
        _ = NSApplication.shared
        let pet = PetController.shared, settings = BubbleSettings.shared
        let show = pet.showChat, animation = pet.animationsEnabled
        let mode = settings.displayMode, hidden = settings.hiddenKinds, cap = settings.maxSessions
        let multi = settings.multiAgentBubbleEnabled
        let layout = settings.customLayout, filter = settings.minStateFilter
        defer {
            pet.showChat = show; pet.animationsEnabled = animation
            settings.displayMode = mode; settings.hiddenKinds = hidden; settings.maxSessions = cap
            settings.multiAgentBubbleEnabled = multi
            settings.customLayout = layout; settings.minStateFilter = filter
        }
        pet.showChat = true; pet.animationsEnabled = true
        settings.displayMode = .list; settings.hiddenKinds = []; settings.maxSessions = 6
        settings.multiAgentBubbleEnabled = true
        settings.customLayout = .detailed; settings.customLayout.tokens.removeAll { $0.token == .project }; settings.minStateFilter = .all
        let controller = PetWindowController()
        defer { controller.stop() }
        let existing = Set(NSApp.windows.map(\.windowNumber))
        var session = AgentSession(id: "hover-layout", agentKind: .dsh, state: .done, source: .hook, updatedAt: Date())
        session.title = "当前项目"; session.model = "deepseek-v4.1-flash"
        session.turnStartedAt = Date().addingTimeInterval(-15); session.turnEndedAt = Date()
        var codex = AgentSession(id: "hover-codex", agentKind: .codex, state: .working, source: .hook, updatedAt: Date())
        codex.title = "AgentPet 需求讨论"; codex.model = "gpt-6.1-sol"
        let specs = PetWindowPlanner.plan(sessions: [codex, session], split: false, mappings: [], defaultPetID: "hover-regression")
        controller.sync(specs: specs) { _ in
            .init(petID: "hover-regression", mood: .working,
                  sessions: side == nil ? [codex, session] : [session], count: side == nil ? 2 : 1, chatLine: "")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let panels = NSApp.windows.filter { !existing.contains($0.windowNumber) }
        let body = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Body" })
        let task = try XCTUnwrap(panels.first { $0.title == "AgentPet Lite Tasks" })
        let scroll = try XCTUnwrap(task.contentView as? NSScrollView)
        let host = try XCTUnwrap(scroll.documentView as? ClickThroughHostingView<PetTaskPanelView>)
        let model = host.rootView.model
        let visible = try XCTUnwrap(body.screen?.visibleFrame)
        controller.moveWindow(forKey: "default", to: CGPoint(x: visible.maxX - 140, y: visible.minY + 44))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if let side {
            let asset = try XCTUnwrap(EdgePeekAsset.load(directory: XCTUnwrap(BundledDefaultPet.resourceDirectory)))
            controller.peekAssetOverride = { _ in asset }
            model.hoverTask(true)
            XCTAssertTrue(model.messageListExpanded)
            XCTAssertTrue(controller.enterEdgePeekForTesting(key: "default", side: side))
            XCTAssertFalse(model.messageListExpanded, "Tucking clears any expansion already active")
            XCTAssertFalse(model.messageHoverExpansionEnabled)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let originalBody = body.frame
        func check(_ stage: String) throws {
            let marker = try XCTUnwrap(model.messageBubbleView)
            let frame = task.convertToScreen(marker.convert(marker.bounds, to: nil))
            let natural = NSHostingView(rootView: PetMessagesView(model: model, expanded: model.messageListExpanded)).fittingSize
            print("HOVER_LAYOUT stage=\(stage) panel=\(task.frame) content=\(host.frame) viewport=\(scroll.contentView.bounds) marker=\(frame) natural=\(natural)")
            XCTAssertTrue(task.isVisible)
            XCTAssertGreaterThan(natural.width, 100)
            XCTAssertEqual(task.frame.width, natural.width, accuracy: 1)
            XCTAssertEqual(task.frame.height, natural.height, accuracy: 1)
            XCTAssertEqual(frame.minX, task.frame.minX, accuracy: 1, "Hover content must not be shifted outside the viewport")
            XCTAssertEqual(frame.maxX, task.frame.maxX, accuracy: 1)
            XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1, "No retained horizontal scroll offset")
            XCTAssertEqual(body.frame, originalBody)
            if side != nil {
                XCTAssertGreaterThanOrEqual(task.frame.minX, visible.minX + 7)
                XCTAssertLessThanOrEqual(task.frame.maxX, visible.maxX - 7)
                XCTAssertTrue(controller.isEdgePeekedForTesting(key: "default"))
            }
        }
        try check("collapsed")
        for displayMode in [BubbleDisplayMode.list, .carousel, .compact] {
            settings.displayMode = displayMode
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let collapsedFrame = task.frame
            model.hoverTask(true)
            if side != nil {
                model.hoverBody(true)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                XCTAssertFalse(model.messageListExpanded)
                XCTAssertEqual(task.frame, collapsedFrame, "Peek hover must not resize its task viewport")
                try check("peek-hover-collapsed")
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                XCTAssertFalse(model.messageListExpanded)
                XCTAssertEqual(task.frame, collapsedFrame)
                model.hoverTask(false); model.hoverBody(false)
                continue
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try check("expanding")
            RunLoop.main.run(until: Date().addingTimeInterval(1.1))
            try check("expanded-after-one-second")
            XCTAssertTrue(model.messageListExpanded)
            model.hoverTask(false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            try check("collapsed-again")
        }
        if side != nil {
            let peek = try XCTUnwrap(controller.peekPanelForTesting(key: "default"))
            let point = NSPoint(x: peek.frame.width / 2, y: peek.frame.height / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged] {
                let location = NSPoint(x: point.x + (type == .leftMouseDragged ? (side == .right ? -8 : 8) : 0), y: point.y)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: peek.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                controller.handlePetClickEvent(event)
            }
            XCTAssertFalse(controller.isEdgePeekedForTesting(key: "default"))
            XCTAssertTrue(model.messageHoverExpansionEnabled)
            XCTAssertFalse(model.messageListExpanded, "Leaving peek must not replay stale hover")
            model.hoverTask(true)
            XCTAssertTrue(model.messageListExpanded, "A new normal hover works immediately after dragging out")
            model.hoverTask(false)
            return
        }
        model.sessions = (0..<(side == nil ? 10 : 30)).map { i in
            var item = AgentSession(id: "hover-long-\(i)", agentKind: .codex, state: .working,
                                    source: .hook, updatedAt: Date())
            item.title = String(repeating: "长标题需要两行展示与滚动验证", count: 4)
            return item
        }
        model.hoverTask(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertGreaterThan(host.frame.height, task.frame.height)
        if side == nil { XCTAssertLessThanOrEqual(task.frame.height, 293) }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: host.frame.height - task.frame.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "The bottom rows must remain reachable")
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)
        XCTAssertEqual(body.frame, originalBody)
    }

    func testRealControllerImportantTextEndsAtEightSecondsWhileAnimationRemains() throws {
        let settings = BubbleSettings.shared
        let enabled = settings.petBubbleEnabled
        defer { settings.petBubbleEnabled = enabled }
        settings.petBubbleEnabled = true
        let controller = PetController()
        defer { controller.clearLowQuota(); PetWindowController.shared.stop() }
        controller.showLowQuota(.init(id: "isolated-eight-second-notice", text: "隔离测试提醒"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "AgentPet Lite Pet Messages" && $0.isVisible })
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<PetSpeechView>)
        let model = host.rootView.model
        XCTAssertEqual(model.quotaText, "隔离测试提醒")
        XCTAssertEqual(model.animationContext.cue?.id, "isolated-eight-second-notice")
        controller.systemNotices.tick()
        RunLoop.main.run(until: Date().addingTimeInterval(8.25))
        print("NOTICE_EXPIRY current=\(String(describing: controller.systemNotices.current?.id)) fraction=\(controller.systemNotices.fractionRemaining) text=\(model.quotaText) visible=\(panel.isVisible)")
        XCTAssertTrue(model.quotaText.isEmpty)
        XCTAssertNotNil(model.animationContext.cue, "The existing 12-second quota animation must continue")
        XCTAssertFalse(panel.isVisible)
    }

    func testSpeechThemeRenderingAndTransparentBackgroundKeepBodyText() throws {
        let settings = BubbleSettings.shared
        let theme = settings.theme, opacity = settings.opacity, enabled = settings.petBubbleEnabled
        defer { settings.theme = theme; settings.opacity = opacity; settings.petBubbleEnabled = enabled }
        settings.petBubbleEnabled = true
        let model = PetWindowModel(key: "speech-render")
        let now = Date()
        let kinds: [AgentKind] = [.codex, .opencode, .antigravity, .codex, .codex, .codex]
        model.speechRows = kinds.enumerated().map { index, kind in
            let session = AgentSession(id: "render-\(index)", agentKind: kind, state: .working, source: .hook, updatedAt: now)
            let label = index == 1 ? "@OpenCode[1]" : index == 2 ? "@agy[1]" : "@Codex[\(index + 1)]"
            return .init(id: UUID(), session: .init(session), label: label, itemID: "\(index)",
                text: index == 0 ? "正在检查认证逻辑" : "正在核对窗口布局与消息滚动是否正…", expiresAt: now.addingTimeInterval(3))
        }
        var textCounts: [Int] = []
        for dark in [false, true] {
            settings.theme = dark ? .dark : .light
            for alpha in [1.0, 0.0] {
                settings.opacity = alpha
                let renderer = ImageRenderer(content: PetSpeechView(model: model)
                    .environment(\.colorScheme, dark ? .dark : .light))
                renderer.scale = 1
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                XCTAssertLessThanOrEqual(bitmap.pixelsWide, 293)
                var text = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 130..<bitmap.pixelsWide {
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        // Compare the same composited background; antialiased
                        // glyph edges have lower alpha on a transparent bitmap.
                        let red = dark ? c.redComponent * c.alphaComponent
                            : c.redComponent * c.alphaComponent + (1 - c.alphaComponent)
                        if dark ? red > 0.8 : red < 0.3 { text += 1 }
                    }
                }
                if !dark { textCounts.append(text) }
                if let path = ProcessInfo.processInfo.environment["AGENTPET_RENDER_EVIDENCE"],
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("speech-\(dark ? "dark" : "light")-\(Int(alpha * 100)).png"))
                }
            }
        }
        XCTAssertGreaterThan(textCounts[1], 100)
        XCTAssertGreaterThanOrEqual(textCounts[1], Int(Double(textCounts[0]) * 0.9))
    }

    func testSpeechPanelAtEveryScreenEdgeKeepsPetAnchorAndClipsHeight() {
        let visible = CGRect(x: -1200, y: 0, width: 1200, height: 800)
        for anchor in [CGPoint(x: -1190, y: 0), CGPoint(x: -10, y: 0), CGPoint(x: -600, y: 690)] {
            let frame = PetSpeechPanelGeometry.frame(anchor: anchor, petSize: 100,
                                                    content: CGSize(width: 292, height: 300), visible: visible)
            XCTAssertGreaterThanOrEqual(frame.minX, visible.minX)
            XCTAssertLessThanOrEqual(frame.maxX, visible.maxX)
            XCTAssertEqual(frame.minY, anchor.y + 104)
            XCTAssertLessThanOrEqual(frame.maxY, visible.maxY)
        }
    }
}
