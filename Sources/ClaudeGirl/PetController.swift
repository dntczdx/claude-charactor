import AppKit

/// 状态中枢：对话状态表、姿态、气泡队列、事件服务器、与 Claude 桌面版的桥接
final class PetController: NSObject {
    static let version = "0.2.0"

    private(set) var conversations: [Conversation] = []   // 最近活动在前
    /// 大小姐 ↔ Claude 桌面版
    let bridge = ClaudeBridge(agent: .claude)
    /// 龙娘 ↔ Codex 桌面版
    let codexBridge = ClaudeBridge(agent: .codex)

    private var windowController: PetWindowController!
    private var codexWindow: PetWindowController!
    private var codexWatcher: CodexWatcher?
    private var codexSignature = ""

    private func window(for agent: Agent) -> PetWindowController { agent == .claude ? windowController : codexWindow }
    private func bridgeFor(_ agent: Agent) -> ClaudeBridge { agent == .claude ? bridge : codexBridge }
    private var statusItem: StatusItemController!
    private var panel: ConversationPanel!
    private var server: EventServer?

    /// 还挂着的 /wait 长轮询：requestId → (回调, 超时计时器)
    private var waiters: [String: (completion: (String?) -> Void, timer: Timer)] = [:]
    /// 用户先答了、MCP 还没来取的答案
    private var pendingAnswers: [String: String] = [:]
    private var currentBubble: Conversation?
    /// 每条「完成」气泡自己的收起计时
    private var hideTimers: [ObjectIdentifier: Timer] = [:]
    /// 面板里点选、要展开显示的那条（即使已读）
    private var pinnedBubble: Conversation?
    /// 刚回答完、还要留 3 秒显示「✓ 已回复」的
    private var lingering: [ObjectIdentifier: Conversation] = [:]
    private var shownSignature = ""
    private var forceRebuild = false
    private var axThinkTimer: Timer?
    private var axFallbackTimer: Timer?
    private var axConversation: Conversation?

    // MARK: 生命周期

    func start() {
        windowController = PetWindowController(agent: .claude)
        windowController.onSpriteClick = { [weak self] in self?.togglePanel() }
        codexWindow = PetWindowController(agent: .codex)
        codexWindow.onSpriteClick = { [weak self] in self?.togglePanel(.codex) }

        panel = ConversationPanel()
        panel.conversations = { [weak self] in self?.conversations ?? [] }
        panel.onOpen = { [weak self] c in
            self?.windowController.closePanel()
            self?.focusBubble(c)
        }
        panel.onMarkAllRead = { [weak self] in self?.markAllRead() }

        statusItem = StatusItemController(controller: self)
        startServer()
        bridge.startObserving(onChange: { [weak self] generating, title, chatID in
            self?.axUpdate(generating: generating, title: title, chatID: chatID)
        }, onSidebar: { [weak self] rows in
            self?.sidebarUpdate(rows)
        })
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        startRegistryPolling()
        startCodexWatcher()
        Updater.shared.start()
        NotificationCenter.default.addObserver(forName: .updaterBuilding, object: nil, queue: .main) { [weak self] n in
            self?.windowController.showWhisper((n.object as? String) ?? "正在更新…")
        }

        if !bridge.isTrusted {
            // 第一次启动顺手要一下权限；拒绝也不影响看通知
            bridge.requestTrust()
        }
        recompute()
    }

    func stop() {
        server?.stop()
        bridge.stopObserving()
        registryTimer?.invalidate()
        codexWatcher?.stop()
    }

    private func startCodexWatcher() {
        guard Settings.shared.watchCodex, codexWatcher == nil else { return }
        let w = CodexWatcher()
        w.onTurnStarted = { [weak self] t in self?.codexTurnStarted(t) }
        w.onTurnComplete = { [weak self] t, last, err in self?.codexTurnComplete(t, lastMessage: last, error: err) }
        w.onTurnAborted = { [weak self] t in self?.codexTurnAborted(t) }
        w.start()
        codexWatcher = w
    }

    private func startServer() {
        let s = EventServer(port: Settings.shared.port) { [weak self] req, respond in
            guard let self else { respond(HTTPResponse(status: 500, json: ["error": "gone"])); return }
            self.handle(req, respond: respond)
        }
        do {
            try s.start()
            server = s
            Log.info("启动 v\(Self.version) 端口 \(Settings.shared.port) 辅助功能=\(bridge.isTrusted)")
        } catch {
            NSLog("[ClaudeGirl] 事件服务器启动失败: %@", String(describing: error))
        }
    }

    @objc private func settingsChanged() {
        windowController.setVisible(Settings.shared.showPet(.claude))
        windowController.walkingSettingChanged()
        codexWindow.setVisible(Settings.shared.showPet(.codex))
        codexWindow.walkingSettingChanged()
        if Settings.shared.watchCodex { startCodexWatcher() } else { codexWatcher?.stop(); codexWatcher = nil }
        Updater.shared.schedule()
        recompute()
    }

    // MARK: HTTP 路由

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/health"):
            return HTTPResponse(json: ["ok": true, "version": Self.version, "accessibility": bridge.isTrusted, "conversations": conversations.count])

        case ("GET", "/debug"):
            let sessions = SessionRegistry.snapshot().map { ["id": $0.chatID, "name": $0.name, "busy": $0.busy, "pid": Int($0.pid)] as [String: Any] }
            let convs = conversations.map { ["topic": $0.topic, "sidebar": $0.sidebarTitle ?? "", "chat": $0.chatID ?? "", "state": $0.state.label] }
            return HTTPResponse(json: ["accessibility": bridge.isTrusted, "foregroundTitle": bridge.currentTitle ?? "", "foregroundChat": bridge.currentChatID ?? "",
                                       "bubble": windowController.bubbleTopic ?? "", "bubbleBusy": windowController.bubbleBusy, "bubbles": windowController.visibleBubbleCount, "bubbleFrames": windowController.bubbleFrames,
                                       "sessions": sessions, "conversations": convs, "registry": Settings.shared.chatRegistry])

        case ("POST", "/open"):
            // 诊断：按 topic / chat id 跳转，等同于点气泡里的「打开对话」
            let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            let c: Conversation
            if let id = obj["id"] as? String, !id.isEmpty {
                c = conversations.first { $0.chatID == id } ?? { let n = Conversation(topic: (obj["topic"] as? String) ?? id, agent: .claude); n.chatID = id; return n }()
            } else if let t = obj["topic"] as? String, !t.isEmpty {
                c = conversation(forTopic: t)
            } else {
                return HTTPResponse(status: 400, json: ["error": "需要 id 或 topic"])
            }
            openConversation(c)
            return HTTPResponse(json: ["ok": true, "chat": c.chatID ?? "", "titles": c.titlesForLookup])

        case ("POST", "/status"):
            guard let e = req.json(StatusEvent.self) else { return HTTPResponse(status: 400, json: ["error": "需要 JSON"]) }
            handleStatus(e)
            return HTTPResponse(json: ["ok": true])

        case ("GET", "/wait"):
            // 长轮询由 handler 的 respond 回调完成，这里不会走到；见 routeAsync
            return HTTPResponse(status: 400, json: ["error": "bad"])

        default:
            return HTTPResponse(status: 404, json: ["error": "not found"])
        }
    }

    // MARK: 事件处理

    /// 处理 notify，返回请求 id
    @discardableResult
    func handleNotify(_ e: NotifyEvent) -> String {
        if e.resolvedAgent == .codex { return handleCodexNotify(e) }
        let id = UUID().uuidString
        let c = conversation(forTopic: e.topic)
        c.topic = e.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        c.apply(e, requestId: id)
        c.isTest = e.test == true
        // 没有聊天对话在生成（前台没在生成、侧栏也没有 Running 行）时，才允许把 notify 归给唯一在生成的 Code 会话
        let chatBusy = (bridgeGenerating && (bridge.currentChatID.map { !$0.hasPrefix("epitaxy/") } ?? true)) || !sidebarBusyTitles.isEmpty
        if e.test == true {
            // 诊断通知：不绑定任何真实对话
        } else if let s = SessionRegistry.caller(topic: c.topic, headline: c.headline, confirmedOnly: chatBusy) {
            // 正在生成的 Code 会话就是发 notify 的那条：直接绑定 ID 和侧栏标题
            if let other = conversations.first(where: { $0 !== c && $0.chatID == s.chatID }) {
                // 同一会话之前用别的 topic 记过：合并到旧的那条上
                conversations.removeAll { $0 === other }
                if axConversation === other { axConversation = c }
            }
            c.chatID = s.chatID
            if !s.name.isEmpty { c.sidebarTitle = s.name }
            Log.info("notify 绑定到 Code 会话 \(s.hostID.prefix(14)) 「\(s.name)」")
        } else if c.chatID == nil, bridgeGenerating, let fid = bridge.currentChatID, !fid.hasPrefix("epitaxy/") {
            // 前台是正在生成的聊天对话：notify 就是它发的
            if let other = conversations.first(where: { $0 !== c && $0.chatID == fid }) {
                conversations.removeAll { $0 === other }
                if axConversation === other { axConversation = c }
            }
            c.chatID = fid
            if let t = bridge.currentTitle { c.sidebarTitle = t }
            Log.info("notify 绑定到前台正在生成的对话「\(bridge.currentTitle ?? "-")」")
        } else if c.chatID == nil, sidebarBusyTitles.count == 1, let t = sidebarBusyTitles.first {
            if let other = conversations.first(where: { $0 !== c && $0.sidebarTitle == t }) {
                conversations.removeAll { $0 === other }
                if axConversation === other { axConversation = c }
                if c.chatID == nil { c.chatID = other.chatID }
            }
            c.sidebarTitle = t
            Log.info("notify 绑定到侧栏正在生成的对话「\(t)」")
        }
        if e.test != true { linkToForegroundConversation(c) }
        // 新来的提问比面板里点选的「完成」气泡更要紧：让它到最下面展开
        if c.state == .ask, let p = pinnedBubble, p !== c, p.state != .ask { pinnedBubble = nil }
        // 同一对话 ID 只留这一条（把辅助功能建的壳合并掉）
        if let id = c.chatID {
            for other in conversations where other !== c && other.chatID == id {
                if c.sidebarTitle == nil { c.sidebarTitle = other.sidebarTitle }
                if axConversation === other { axConversation = c }
                for (k, v) in activeKeys where v === other { activeKeys[k] = c }
            }
            conversations.removeAll { $0 !== c && $0.chatID == id }
        }
        Log.info("notify topic=\(c.topic) state=\(c.state.label) options=\(c.options.count) id=\(id.prefix(8)) sidebar=\(c.sidebarTitle ?? "-") chat=\(c.chatID.map(Self.shortID) ?? "-")")
        cancelAXFallback()
        for key in fallbackTimers.keys where activeKeys[key] === c || key == c.chatID || key == "row:" + (c.sidebarTitle ?? "") {
            fallbackTimers.removeValue(forKey: key)?.invalidate()
        }
        bump(c)
        recompute()
        return id
    }

    // MARK: Codex（龙娘）：MCP notify / notify hook / 会话日志

    /// 龙娘的 notify：来自 Codex 的 MCP 工具或 CLI 的 notify hook（后者带 thread-id）
    private func handleCodexNotify(_ e: NotifyEvent) -> String {
        let id = UUID().uuidString
        let c = conversation(forTopic: e.topic, agent: .codex, chatID: e.chatID)
        if c.chatID == nil || c.chatID == e.chatID {
            c.topic = e.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 日志刚刚已经把同一线程报成完成、而且用户已经看过：再来一条同类通知只更新内容，不重复弹
        let dup = c.state == .done && !c.unread && Date().timeIntervalSince(c.updatedAt) < 15 && e.resolvedState == .done
        c.apply(e, requestId: id)
        c.isTest = e.test == true
        if dup { c.unread = false }
        if c.chatID == nil, e.test != true { bindCodexNotify(c) }
        // 同一线程只留这一条
        if let cid = c.chatID {
            conversations.removeAll { $0 !== c && $0.agent == .codex && $0.chatID == cid }
        }
        Log.info("notify[codex] topic=\(c.topic) state=\(c.state.label) options=\(c.options.count) id=\(id.prefix(8)) chat=\(c.chatID.map { String($0.prefix(8)) } ?? "-")")
        bump(c)
        recompute()
        return id
    }

    /// MCP 的 notify 不知道自己在哪条线程；日志里正在工作的那条多半就是它
    private func bindCodexNotify(_ c: Conversation) {
        let busy = conversations.filter { $0.agent == .codex && $0 !== c && ($0.state == .working || $0.state == .thinking) && $0.chatID != nil }
        let recent = conversations.filter { $0.agent == .codex && $0 !== c && $0.chatID != nil && Date().timeIntervalSince($0.updatedAt) < 20 }
        if let src = busy.first ?? recent.first {
            c.chatID = src.chatID
            if c.sidebarTitle == nil { c.sidebarTitle = src.topic }
            if src.requestId == nil { conversations.removeAll { $0 === src } }
            return
        }
        // 日志没看到正在工作的线程（比如日志是 zst 而没装 zstd）：取最近 90 秒内有写入的那个会话文件
        if let t = codexWatcher?.mostRecentThread(within: 90) {
            c.chatID = t.id
            Log.info("notify[codex] 按最近写入的会话文件绑定 thread=\(t.id.prefix(8))")
        } else {
            Log.info("notify[codex] 找不到对应线程：日志目录没有最近写入的文件（是否需要 brew install zstd？）")
        }
    }

    private func codexConversation(_ t: CodexWatcher.ThreadInfo) -> Conversation {
        if let c = conversations.first(where: { $0.agent == .codex && $0.chatID == t.id }) { return c }
        let c = conversation(forTopic: t.title, agent: .codex, chatID: t.id)
        c.chatID = t.id
        return c
    }

    private func codexTurnStarted(_ t: CodexWatcher.ThreadInfo) {
        let c = codexConversation(t)
        if c.topic.isEmpty || c.topic == "Codex 线程" { c.topic = t.title }
        let justNotified = c.requestId != nil && c.state.showsBubble && Date().timeIntervalSince(c.updatedAt) < 90
        guard !justNotified else { return }
        c.state = .working
        c.updatedAt = Date()
        Log.info("codex 开始 thread=\(t.id.prefix(8)) \(c.topic)")
        bump(c)
        recompute()
    }

    private func codexTurnComplete(_ t: CodexWatcher.ThreadInfo, lastMessage: String?, error: String?) {
        let c = codexConversation(t)
        if c.topic.isEmpty || c.topic == "Codex 线程" { c.topic = t.title }
        // MCP notify 刚刚已经把这条报成完成/提问了：不要用日志的粗摘要覆盖
        if c.requestId != nil, c.state.showsBubble, Date().timeIntervalSince(c.updatedAt) < 20 {
            Log.info("codex 完成 thread=\(t.id.prefix(8))（已由 notify 报过，跳过）")
            return
        }
        if let error, !error.isEmpty {
            c.state = .error
            c.headline = String(error.prefix(80))
            c.points = []
        } else {
            let sum = CodexSummary.make(from: lastMessage)
            c.state = .done
            c.headline = sum.headline
            c.points = sum.points
        }
        c.question = nil
        c.options = []
        c.needsInput = false
        c.requestId = nil
        c.answer = nil
        c.updatedAt = Date()
        c.unread = true
        Log.info("codex 完成 thread=\(t.id.prefix(8)) \(c.state.label)：\(c.headline)")
        bump(c)
        recompute()
    }

    private func codexTurnAborted(_ t: CodexWatcher.ThreadInfo) {
        let c = codexConversation(t)
        if c.state == .working || c.state == .thinking {
            c.state = .idle
            c.updatedAt = Date()
            bump(c)
            recompute()
        }
    }

    /// notify 通常是前台正在生成的那条对话发来的（工具调用发生在回复过程中），
    /// 把 Claude 自己起的 topic 和窗口标题（= 侧栏标题）对上，跳转时就能找到它。
    private func linkToForegroundConversation(_ c: Conversation) {
        // 前台对话正在生成 → notify 几乎一定来自它：直接拿它的 UUID 和标题
        if bridgeGenerating, c.chatID == nil {
            if let id = bridge.currentChatID { c.chatID = id }
            if let t = bridge.currentTitle, c.sidebarTitle == nil { c.sidebarTitle = t }
        }
        // 没拿到 UUID：用登记表按标题精确/高相似度查
        if c.chatID == nil { c.chatID = lookupChatID(for: c) }
        guard let ax = axConversation, ax !== c, ax.topic != "当前对话" || ax.chatID != nil else { return }
        let axBusy = ax.state == .working || ax.state == .thinking
        let recent = Date().timeIntervalSince(ax.updatedAt) < 30
        guard axBusy || recent else { return }
        if c.sidebarTitle == nil || c.sidebarTitle == ax.topic {
            if ax.topic != "当前对话" { c.sidebarTitle = ax.sidebarTitle ?? ax.topic }
            if c.chatID == nil { c.chatID = ax.chatID }
            // ax 这条是从窗口标题临时建的壳，合并掉
            if ax.headline.isEmpty, ax.requestId == nil {
                conversations.removeAll { $0 === ax }
                axConversation = c
            }
        }
    }

    func handleStatus(_ e: StatusEvent) {
        let c = conversation(forTopic: e.topic ?? "当前对话", agent: Agent(name: e.agent))
        let s = ConvState(kind: e.state)
        if s == .idle || s == .working || s == .thinking {
            c.state = s
            c.updatedAt = Date()
            bump(c)
            recompute()
        }
    }

    /// MCP 长轮询：等用户在气泡里回答
    func waitForAnswer(requestId: String, timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        if let a = pendingAnswers.removeValue(forKey: requestId) {
            Log.info("wait id=\(requestId.prefix(8)) 已有答案，直接返回")
            completion(a)
            return
        }
        Log.info("wait id=\(requestId.prefix(8)) 挂起 \(Int(timeout))s")
        if let old = waiters.removeValue(forKey: requestId) {
            old.timer.invalidate()
            old.completion(nil)
        }
        let t = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self, let w = self.waiters.removeValue(forKey: requestId) else { return }
            Log.info("wait id=\(requestId.prefix(8)) 超时")
            w.completion(nil)
        }
        RunLoop.main.add(t, forMode: .common)
        waiters[requestId] = (completion, t)
    }

    /// 用户在气泡里点了选项 / 输入了文字
    func answer(_ c: Conversation, text: String) {
        c.answer = text
        c.unread = false
        if pinnedBubble === c { pinnedBubble = nil }
        hideTimers.removeValue(forKey: ObjectIdentifier(c))?.invalidate()
        window(for: c.agent).markBubbleAnswered(c, text: text)
        // 留 3 秒给「✓ 已回复」，然后从气泡堆里撤掉
        lingering[ObjectIdentifier(c)] = c
        let t = Timer(timeInterval: 3, repeats: false) { [weak self, weak c] _ in
            guard let self, let c else { return }
            self.lingering.removeValue(forKey: ObjectIdentifier(c))
            self.recompute(force: true)
        }
        RunLoop.main.add(t, forMode: .common)

        let recent = Date().timeIntervalSince(c.updatedAt) < 45
        if let rid = c.requestId, let w = waiters.removeValue(forKey: rid) {
            // MCP 调用还挂着：直接作为工具结果回去，Claude 在同一对话里继续
            Log.info("answer 「\(text)」→ 回传给挂起的 MCP 调用 id=\(rid.prefix(8))")
            w.timer.invalidate()
            w.completion(text)
            c.state = .working
        } else if let rid = c.requestId, c.state == .ask, recent {
            // MCP 马上会来取
            Log.info("answer 「\(text)」→ 暂存，等 MCP 来取 id=\(rid.prefix(8))")
            pendingAnswers[rid] = text
            c.state = .working
        } else if c.isTest || (c.chatID == nil && c.sidebarTitle == nil) {
            // 演示气泡、或根本不知道属于哪条对话：只记下来，不往任何对话里填（填错对话比不填糟糕得多）
            Log.info("answer 「\(text)」→ 这条没有对应的真实对话，不发送")
            c.state = .idle
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            window(for: c.agent).showWhisper(c.isTest ? "这是演示气泡，回答没有发出" : "不知道这条属于哪个对话，答案已复制到剪贴板")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.recompute() }
        } else {
            // 走辅助功能：切到那条对话，把答案填进输入框发出去（切不到就不发）
            Log.info("answer 「\(text)」→ 走辅助功能填进对话 id=\(c.chatID ?? "-") titles=\(c.titlesForLookup)")
            c.state = .working
            bridgeFor(c.agent).deliver(text, chat: c.chatRef) { [weak self] ok in
                guard let self else { return }
                Log.info("deliver 结果 ok=\(ok)")
                if !ok {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    c.state = .idle
                    self.window(for: c.agent).showWhisper("没能自动填进对话，答案已复制到剪贴板")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.recompute() }
                    self.bridgeFor(c.agent).open(chat: c.chatRef) { _ in }
                }
                self.recompute()
            }
        }
        c.updatedAt = Date()
        bump(c)
        NotificationCenter.default.post(name: .conversationsChanged, object: nil)
        statusItem.refresh()
        window(for: c.agent).setPose(topPose(for: c.agent))
    }

    func openConversation(_ c: Conversation) {
        // 跳过去看，气泡留着（等「知道了」或自动收起），回来还能继续在气泡里回一句
        if c.agent == .claude, c.chatID == nil { c.chatID = lookupChatID(for: c) }
        Log.info("open[\(c.agent.rawValue)] id=\(c.chatID.map(Self.shortID) ?? "-") titles=\(c.titlesForLookup)")
        bridgeFor(c.agent).open(chat: c.chatRef) { [weak self] ok in
            Log.info("open 结果 ok=\(ok)")
            if !ok { self?.window(for: c.agent).showWhisper("没找到这条对话，只打开了 \(c.agent.appName)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.recompute() }
        }
        recompute()
    }

    func dismissBubble(_ c: Conversation) {
        c.unread = false
        if pinnedBubble === c { pinnedBubble = nil }
        lingering.removeValue(forKey: ObjectIdentifier(c))
        hideTimers.removeValue(forKey: ObjectIdentifier(c))?.invalidate()
        recompute(force: true)
    }

    /// 面板里点了一条：把它的气泡（重新）展开显示，不跳转
    func focusBubble(_ c: Conversation) {
        pinnedBubble = c
        recompute(force: true)
    }

    func markAllRead() {
        for c in conversations { c.unread = false }
        pinnedBubble = nil
        lingering.removeAll()
        for (_, t) in hideTimers { t.invalidate() }
        hideTimers.removeAll()
        recompute(force: true)
    }

    func togglePanel(_ agent: Agent = .claude) {
        window(for: agent).togglePanel(panel)
    }

    func reloadAssets() {
        windowController.refreshClip()
        codexWindow.refreshClip()
    }

    /// 菜单里的「测试一下气泡」：轮流演示完成 / 提问（演示通知不绑定真实对话）
    private var testToggle = false
    func injectTestEvent(agent: Agent = .claude) {
        testToggle.toggle()
        let e: NotifyEvent
        if testToggle {
            e = NotifyEvent(topic: agent == .codex ? "分页接口改造" : "博客列表分页方案",
                            headline: "两种我都能做：无限滚动体验顺，页码方便收藏和 SEO。",
                            question: "列表页用哪种分页？", options: ["页码分页（推荐）", "无限滚动", "两种都做，加个开关"],
                            kind: "ask", agent: agent.rawValue, test: true)
        } else {
            e = NotifyEvent(topic: agent == .codex ? "登录页单测补齐" : "登录页表单校验",
                            headline: "登录页校验改好了，3 个测试全过",
                            points: ["邮箱、密码改成提交时统一校验，提示跟在字段下", "校验规则抽到 validators.ts，登录注册共用", "补了 3 个单元测试"],
                            kind: "done", agent: agent.rawValue, test: true)
        }
        handleNotify(e)
    }

    static func shortID(_ id: String) -> String { ClaudeBridge.shortID(id) }

    // MARK: Claude Code 会话登记表（~/.claude/sessions）

    private var registryTimer: Timer?
    private var registryBusy: Set<String> = []
    private var fallbackTimers: [String: Timer] = [:]
    private var activeKeys: [String: Conversation] = [:]

    private func startRegistryPolling() {
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.pollRegistry() }
        RunLoop.main.add(t, forMode: .common)
        registryTimer = t
        pollRegistry()
    }

    private func pollRegistry() {
        let sessions = SessionRegistry.snapshot()
        guard !sessions.isEmpty else { return }
        registerSidebar(sessions.filter { !$0.name.isEmpty }.map { (id: $0.chatID, title: $0.name) })
        let busyNow = Set(sessions.filter(\.busy).map(\.chatID))
        for s in sessions {
            let wasBusy = registryBusy.contains(s.chatID)
            if s.busy && !wasBusy {
                sessionStarted(s)
            } else if !s.busy && wasBusy {
                sessionFinished(s)
            }
        }
        registryBusy = busyNow
    }

    /// 已经按 ID / 标题记过的对话；没有就按侧栏标题建一条
    private func conversation(for s: CodeSession) -> Conversation {
        conversation(id: s.chatID, title: s.name)
    }

    private func conversation(id: String?, title: String) -> Conversation {
        if let id, let c = conversations.first(where: { $0.chatID == id }) { return c }
        if let c = conversations.first(where: { $0.sidebarTitle == title }) {
            if c.chatID == nil { c.chatID = id }
            return c
        }
        let c = conversation(forTopic: title.isEmpty ? (id ?? "当前对话") : title)
        if c.chatID == nil { c.chatID = id }
        if !title.isEmpty, c.sidebarTitle == nil { c.sidebarTitle = title }
        return c
    }

    private func sessionStarted(_ s: CodeSession) { activityStarted(key: s.chatID, id: s.chatID, title: s.name) }
    private func sessionFinished(_ s: CodeSession) { activityFinished(key: s.chatID) }

    /// 某条对话开始生成（来自 Code 登记表或聊天页侧栏行的状态前缀）
    private func activityStarted(key: String, id: String?, title: String) {
        let c = conversation(id: id, title: title)
        activeKeys[key] = c
        fallbackTimers.removeValue(forKey: key)?.invalidate()
        let justNotified = c.requestId != nil && c.state.showsBubble && Date().timeIntervalSince(c.updatedAt) < 90
        guard c.state != .working && c.state != .thinking && !justNotified else { return }
        c.state = .thinking
        c.updatedAt = Date()
        let t = Timer(timeInterval: 3, repeats: false) { [weak self, weak c] _ in
            guard let self, let c, c.state == .thinking else { return }
            c.state = .working
            self.recompute()
        }
        RunLoop.main.add(t, forMode: .common)
        bump(c)
        recompute()
    }

    private func activityFinished(key: String) {
        guard let c = activeKeys.removeValue(forKey: key), c.state == .working || c.state == .thinking else { return }
        // 生成结束：给 MCP 的 notify 4 秒时间；没来就用兜底的完成提醒
        fallbackTimers[key]?.invalidate()
        let t = Timer(timeInterval: 4, repeats: false) { [weak self, weak c] _ in
            guard let self, let c, c.state == .working || c.state == .thinking else { return }
            if self.stillBusyElsewhere(title: c.sidebarTitle ?? c.topic, chatID: c.chatID) || (self.axConversation === c && self.bridgeGenerating) {
                Log.info("兜底提醒取消：\(c.topic) 还在生成")
                return
            }
            self.finishWithoutNotify(c)
        }
        RunLoop.main.add(t, forMode: .common)
        fallbackTimers[key] = t
    }

    // MARK: 聊天页侧栏行（辅助功能扫出来的：标题 + 状态前缀）

    private var sidebarBusyTitles: Set<String> = []
    private var loggedStatuses: Set<String> = []

    private func sidebarUpdate(_ rows: [ClaudeBridge.SidebarRow]) {
        registerSidebar(rows.compactMap { r in r.id.map { (id: $0, title: r.title) } })
        var busyNow = Set<String>()
        for r in rows {
            if let st = r.status, !st.isEmpty, !loggedStatuses.contains(st) {
                loggedStatuses.insert(st)
                Log.info("侧栏行状态前缀「\(st)」（busy=\(r.busy)）")
            }
            guard r.busy else { continue }
            busyNow.insert(r.title)
            if !sidebarBusyTitles.contains(r.title) { activityStarted(key: "row:" + r.title, id: r.id, title: r.title) }
        }
        for t in sidebarBusyTitles where !busyNow.contains(t) { activityFinished(key: "row:" + t) }
        sidebarBusyTitles = busyNow
    }

    // MARK: 辅助功能观察到的生成状态

    private var bridgeGenerating = false

    /// 侧栏扫描结果：登记「标题 → UUID」，并补全已有对话的 UUID
    private func registerSidebar(_ links: [(id: String, title: String)]) {
        let before = Settings.shared.chatRegistry
        var reg = before
        for l in links where !l.title.isEmpty { reg[l.title] = l.id }
        if reg.count > 400 { reg = Dictionary(uniqueKeysWithValues: reg.suffix(300).map { ($0.key, $0.value) }) }
        if reg != before { Settings.shared.chatRegistry = reg }
        for c in conversations where c.chatID == nil {
            c.chatID = lookupChatID(for: c)
        }
    }

    /// 从登记表里按标题找 UUID：先精确，再高相似度
    private func lookupChatID(for c: Conversation) -> String? {
        let reg = Settings.shared.chatRegistry
        for t in c.titlesForLookup {
            if let id = reg[t] { return id }
        }
        var best: (String, Double)? = nil
        for t in c.titlesForLookup {
            for (title, id) in reg {
                let s = ClaudeBridge.similarity(t, title)
                if s >= 0.8, s > (best?.1 ?? 0) { best = (id, s) }
            }
        }
        return best?.0
    }

    /// 除了前台的「停止」按钮，侧栏行状态（Running…）和 Code 登记表也能说明这条对话还在生成
    private func stillBusyElsewhere(title: String?, chatID: String?) -> Bool {
        if let title, sidebarBusyTitles.contains(title) { return true }
        if let chatID, registryBusy.contains(chatID) { return true }
        return false
    }

    private func axUpdate(generating rawGenerating: Bool, title: String?, chatID: String?) {
        let generating = rawGenerating || stillBusyElsewhere(title: title, chatID: chatID)
        if generating != bridgeGenerating { Log.info("前台 \(title ?? "-") 生成中=\(generating)（停止按钮=\(rawGenerating)）") }
        bridgeGenerating = generating
        if let title, let chatID {
            var reg = Settings.shared.chatRegistry
            if reg[title] != chatID { reg[title] = chatID; Settings.shared.chatRegistry = reg }
        }
        let topic = title ?? "当前对话"
        if generating {
            cancelAXFallback()
            // 同一个对话 ID 已有记录（notify 先到、或刚才还没标题时建的壳）就沿用，别再建一条
            let c = chatID.flatMap { id in conversations.first { $0.chatID == id } } ?? conversation(forTopic: topic)
            if let title, c.topic == "当前对话" { c.topic = title }
            if let chatID { c.chatID = chatID }
            if let title, c.sidebarTitle == nil { c.sidebarTitle = title }
            axConversation = c
            // notify 是在回复过程中调用的，之后 Claude 可能还在写：别把刚弹出的完成/提问气泡又打回「思考中」
            let justNotified = c.requestId != nil && c.state.showsBubble && Date().timeIntervalSince(c.updatedAt) < 90
            if c.state != .working && c.state != .thinking && !justNotified {
                c.state = .thinking
                c.updatedAt = Date()
                axThinkTimer?.invalidate()
                let t = Timer(timeInterval: 3, repeats: false) { [weak self, weak c] _ in
                    guard let self, let c, c.state == .thinking else { return }
                    c.state = .working
                    self.recompute()
                }
                RunLoop.main.add(t, forMode: .common)
                axThinkTimer = t
                bump(c)
                recompute()
            }
        } else {
            axThinkTimer?.invalidate()
            // 标题通常在生成结束前后才出现：给按 ID 建的「当前对话」壳补上名字
            if let title, let chatID, let c = conversations.first(where: { $0.chatID == chatID }) {
                if c.topic == "当前对话" { c.topic = title }
                if c.sidebarTitle == nil || c.sidebarTitle == "" { c.sidebarTitle = title }
            }
            guard let c = axConversation, c.state == .working || c.state == .thinking else { return }
            // 生成结束：给 MCP 的 notify 4 秒时间；没来就用兜底的完成提醒
            axFallbackTimer?.invalidate()
            let t = Timer(timeInterval: 4, repeats: false) { [weak self, weak c] _ in
                guard let self, let c, c.state == .working || c.state == .thinking else { return }
                if self.bridgeGenerating || self.stillBusyElsewhere(title: c.sidebarTitle ?? c.topic, chatID: c.chatID) {
                    Log.info("兜底提醒取消：\(c.topic) 还在生成")
                    return
                }
                self.finishWithoutNotify(c)
            }
            RunLoop.main.add(t, forMode: .common)
            axFallbackTimer = t
        }
    }

    /// 发这条 notify 的对话，本轮已经写了多少字正文；判断不了（对话不在前台、也不是 Code 会话）给 nil
    private func replyLengthForCaller(of e: NotifyEvent, completion: @escaping (Int?) -> Void) {
        let chatBusy = (bridgeGenerating && (bridge.currentChatID.map { !$0.hasPrefix("epitaxy/") } ?? true)) || !sidebarBusyTitles.isEmpty
        let headline = (e.headline ?? e.summary ?? e.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = SessionRegistry.caller(topic: e.topic, headline: headline, confirmedOnly: chatBusy) {
            // Claude Code 把正文和工具调用放在同一条消息里，工具执行时这条消息还没写进对话记录，
            // 记录里的字数只能当参考，不能据此拒绝（Code 会话本来也不会把回复只塞进通知）
            Log.info("Code 会话「\(s.name)」记录里本轮正文 \(SessionRegistry.replyLength(of: s).map(String.init) ?? "未知") 字（仅参考）")
            completion(nil)
            return
        }
        if bridgeGenerating, let fid = bridge.currentChatID, !fid.hasPrefix("epitaxy/") {
            bridge.readLastReply { lines in completion(lines.joined().count) }
            return
        }
        completion(nil)
    }

    /// Claude 没调用 notify 的兜底完成气泡：对话在前台就摘录它最后一条回复的开头，否则只提示写完了
    private func finishWithoutNotify(_ c: Conversation) {
        let title = c.sidebarTitle ?? c.topic
        let inFront = bridge.currentChatID != nil && bridge.currentChatID == c.chatID
            || (bridge.currentTitle.map { ClaudeBridge.similarity($0, title) >= 0.8 } ?? false)
        let apply: ([String]) -> Void = { [weak self] lines in
            guard let self else { return }
            c.state = .done
            if let first = lines.first {
                c.headline = Self.clip(first, 70)
                c.points = lines.dropFirst().prefix(2).map { Self.clip($0, 80) } + ["（Claude 没调用 notify，这是回复开头）"]
            } else {
                c.headline = "这条回复写完了"
                c.points = ["Claude 这次没调用 notify，点「打开对话」看原文"]
            }
            c.question = nil
            c.options = []
            c.requestId = nil
            c.updatedAt = Date()
            c.unread = true
            self.bump(c)
            self.recompute()
        }
        if inFront { bridge.readLastReply(completion: apply) } else { apply([]) }
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    private func cancelAXFallback() {
        axFallbackTimer?.invalidate()
        axFallbackTimer = nil
    }

    // MARK: 状态表

    private func conversation(id: String) -> Conversation? {
        conversations.first { $0.requestId == id }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// 按主题找对话（同一只桌宠范围内）：先按 ID，再完全一致，或一方包含另一方
    private func conversation(forTopic topic: String, agent: Agent = .claude, chatID: String? = nil) -> Conversation {
        if let chatID, !chatID.isEmpty, let c = conversations.first(where: { $0.agent == agent && $0.chatID == chatID }) { return c }
        let t = Self.normalize(topic)
        func names(_ c: Conversation) -> [String] { [c.topic, c.sidebarTitle].compactMap { $0 }.map(Self.normalize) }
        let same = conversations.filter { $0.agent == agent }
        if let c = same.first(where: { names($0).contains(t) }) { return c }
        if t.count >= 4, let c = same.first(where: {
            names($0).contains { n in n.count >= 4 && (n.contains(t) || t.contains(n)) }
        }) { return c }
        let c = Conversation(topic: topic, agent: agent)
        c.chatID = chatID
        conversations.insert(c, at: 0)
        if conversations.count > 40 { conversations.removeLast() }
        return c
    }

    private func bump(_ c: Conversation) {
        conversations.removeAll { $0 === c }
        conversations.insert(c, at: 0)
        NotificationCenter.default.post(name: .conversationsChanged, object: nil)
    }

    /// 某只桌宠：它的对话里优先级最高的姿态
    private func topPose(for agent: Agent = .claude) -> Pose {
        let active = conversations.filter {
            $0.agent == agent && ($0.state == .working || $0.state == .thinking || ($0.state.showsBubble && $0.unread))
        }
        return (active.map(\.state).max() ?? .idle).pose
    }

    /// 重新决定姿态、气泡堆、轻提示（大小姐这一套走原逻辑，龙娘走 recomputeCodex）
    func recompute(force: Bool = false) {
        recomputeCodex(force: force)
        windowController.setPose(topPose(for: .claude))

        let quiet = Settings.shared.quietMode
        var list = conversations
            .filter { $0.agent == .claude && $0.unread && $0.state.showsBubble && !quiet }
            .sorted { a, b in
                if a.state != b.state { return a.state > b.state }
                return a.updatedAt > b.updatedAt
            }
        // 面板里点选的那条放最下面展开
        if let p = pinnedBubble, p.agent == .claude {
            list.removeAll { $0 === p }
            list.insert(p, at: 0)
        }
        // 刚回答完的留 3 秒
        for (_, c) in lingering where c.agent == .claude && !list.contains(where: { $0 === c }) { list.insert(c, at: 0) }
        let overflow = max(0, list.count - 3)
        let show = Array(list.prefix(3))
        let sig = show.map { c -> String in
            let answered = lingering[ObjectIdentifier(c)] != nil ? "a" : ""
            return "\(ObjectIdentifier(c).hashValue):\(c.state.rawValue):\(c.points.count):\(c.headline.hashValue)\(answered)"
        }.joined(separator: "|")

        if sig != shownSignature || force {
            if !force, currentBubble != nil, windowController.bubbleBusy {
                Log.info("气泡忙（输入/悬停中），暂不更新气泡堆")
            } else {
                shownSignature = sig
                currentBubble = show.first
                windowController.setBubbles(show.enumerated().map { i, c in bubbleSpec(c, expanded: i == 0) })
                for c in show {
                    if let a = lingering[ObjectIdentifier(c)]?.answer { windowController.markBubbleAnswered(c, text: a) }
                    else if c.state == .done { scheduleHide(c) }
                }
            }
        }

        if let busy = conversations.first(where: { $0.agent == .claude && ($0.state == .working || $0.state == .thinking) }) {
            windowController.showWhisper("\(busy.topic) · \(busy.state == .thinking ? "想一想…" : "正在写…")")
        } else if overflow > 0 {
            windowController.showWhisper("还有 \(overflow) 条通知，点我看面板")
        } else {
            windowController.showWhisper(nil)
        }
        statusItem.refresh()
    }

    /// 龙娘：同样最多叠三条，最新的展开；面板点选、刚回答完的也照顾到
    private func recomputeCodex(force: Bool) {
        guard let w = codexWindow else { return }
        w.setPose(topPose(for: .codex))
        let quiet = Settings.shared.quietMode
        var list = conversations
            .filter { $0.agent == .codex && $0.unread && $0.state.showsBubble && !quiet }
            .sorted { a, b in
                if a.state != b.state { return a.state > b.state }
                return a.updatedAt > b.updatedAt
            }
        if let p = pinnedBubble, p.agent == .codex {
            list.removeAll { $0 === p }
            list.insert(p, at: 0)
        }
        for (_, c) in lingering where c.agent == .codex && !list.contains(where: { $0 === c }) { list.insert(c, at: 0) }
        let overflow = max(0, list.count - 3)
        let show = Array(list.prefix(3))
        let sig = show.map { c -> String in
            let answered = lingering[ObjectIdentifier(c)] != nil ? "a" : ""
            return "\(ObjectIdentifier(c).hashValue):\(c.state.rawValue):\(c.points.count):\(c.headline.hashValue)\(answered)"
        }.joined(separator: "|")
        if sig != codexSignature || force {
            if !force, !show.isEmpty, w.bubbleBusy {
                Log.info("龙娘气泡忙（输入/悬停中），暂不更新气泡堆")
            } else {
                codexSignature = sig
                w.setBubbles(show.enumerated().map { i, c in bubbleSpec(c, expanded: i == 0) })
                for c in show {
                    if let a = lingering[ObjectIdentifier(c)]?.answer { w.markBubbleAnswered(c, text: a) }
                    else if c.state == .done { scheduleHide(c) }
                }
            }
        }
        if let busy = conversations.first(where: { $0.agent == .codex && ($0.state == .working || $0.state == .thinking) }) {
            w.showWhisper("\(busy.topic) · \(busy.state == .thinking ? "想一想…" : "正在写…")")
        } else if overflow > 0 {
            w.showWhisper("还有 \(overflow) 条通知，点我看面板")
        } else {
            w.showWhisper(nil)
        }
    }

    private func bubbleSpec(_ c: Conversation, expanded: Bool) -> PetWindowController.BubbleSpec {
        PetWindowController.BubbleSpec(
            conversation: c, expanded: expanded,
            onOpen: { [weak self] in self?.openConversation(c) },
            onAnswer: { [weak self] text in self?.answer(c, text: text) },
            onDismiss: { [weak self] in self?.dismissBubble(c) },
            onExpand: { [weak self] in self?.focusBubble(c) })
    }

    /// 「完成」气泡显示 20 秒后自动收起；用户正在气泡上（输入 / 悬停）就先不收
    private func scheduleHide(_ c: Conversation, after s: TimeInterval? = nil) {
        let key = ObjectIdentifier(c)
        if s == nil, hideTimers[key] != nil { return }   // 已经在计时，别重置
        hideTimers[key]?.invalidate()
        let t = Timer(timeInterval: s ?? Settings.shared.doneBubbleSeconds, repeats: false) { [weak self, weak c] _ in
            guard let self, let c else { return }
            if self.window(for: c.agent).bubbleBusy {
                self.scheduleHide(c, after: 6)
                return
            }
            self.hideTimers.removeValue(forKey: ObjectIdentifier(c))
            self.dismissBubble(c)
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimers[key] = t
    }
}

// MARK: - 长轮询路由（需要异步 respond）

extension PetController {
    /// EventServer 的入口：/wait 需要异步，其余同步
    func handle(_ req: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        if req.method == "GET", req.path == "/wait" {
            guard let id = req.query["id"], !id.isEmpty else {
                respond(HTTPResponse(status: 400, json: ["error": "需要 id"]))
                return
            }
            let timeout = min(max(TimeInterval(req.query["timeout"] ?? "") ?? 50, 1), 120)
            waitForAnswer(requestId: id, timeout: timeout) { answer in
                if let answer {
                    respond(HTTPResponse(json: ["answered": true, "answer": answer]))
                } else {
                    respond(HTTPResponse(json: ["answered": false]))
                }
            }
            return
        }
        if req.method == "POST", req.path == "/notify" {
            guard let e = req.json(NotifyEvent.self), !e.topic.trimmingCharacters(in: .whitespaces).isEmpty else {
                respond(HTTPResponse(status: 400, json: ["error": "需要 JSON，至少含 topic"])); return
            }
            // 硬性关卡：对话里还没写正文就不收这条 notify，让 Claude 先把回复写出来（龙娘 / 演示通知不过关卡）
            let check: (@escaping (Int?) -> Void) -> Void = { [weak self] done in
                if e.test == true || e.resolvedAgent == .codex { done(nil) } else { self?.replyLengthForCaller(of: e, completion: done) }
            }
            check { [weak self] replyChars in
                guard let self else { return }
                let notifyChars = ((e.headline ?? "") + (e.points ?? []).joined()).count
                // 一个字都没写就来通知 → 一定是想用通知代替回复；写了但很短而通知更长 → 同样可疑
                if let n = replyChars, n == 0 || (n < 20 && notifyChars > n + 20) {
                    Log.info("notify 被拒：topic=\(e.topic) 对话正文只有 \(n) 字，通知却有 \(notifyChars) 字")
                    respond(HTTPResponse(json: ["rejected": true, "replyChars": n]))
                    return
                }
                Log.info("notify 核对正文：topic=\(e.topic) 正文 \(replyChars.map(String.init) ?? "未知") 字，通知 \(notifyChars) 字")
                let id = self.handleNotify(e)
                respond(HTTPResponse(json: ["id": id, "state": self.conversation(id: id)?.state.label ?? "", "replyChars": replyChars ?? -1]))
            }
            return
        }
        if req.method == "POST", req.path == "/focus" {
            // 诊断：等同于在面板里点某一条
            let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            guard let t = obj["topic"] as? String, let c = conversations.first(where: { $0.topic == t || $0.sidebarTitle == t }) else {
                respond(HTTPResponse(status: 404, json: ["error": "没有这条对话"])); return
            }
            focusBubble(c)
            respond(HTTPResponse(json: ["ok": true]))
            return
        }
        if req.method == "POST", req.path == "/answer" {
            // 诊断：等同于在气泡里点选项 / 输入回答。{"topic": …, "text": …}
            let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            guard let text = obj["text"] as? String, !text.isEmpty else { respond(HTTPResponse(status: 400, json: ["error": "需要 text"])); return }
            let c: Conversation?
            if let t = obj["topic"] as? String, !t.isEmpty { c = conversations.first { $0.topic == t || $0.sidebarTitle == t } }
            else { c = currentBubble ?? conversations.first { $0.state == .ask } }
            guard let c else { respond(HTTPResponse(status: 404, json: ["error": "没有待回答的对话"])); return }
            answer(c, text: text)
            respond(HTTPResponse(json: ["ok": true, "topic": c.topic]))
            return
        }
        if req.method == "POST", req.path == "/send" {
            // 诊断：切到某条对话（没给就是当前页面），把 text 填进输入框并回车发送
            let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            guard let text = obj["text"] as? String, !text.isEmpty else { respond(HTTPResponse(status: 400, json: ["error": "需要 text"])); return }
            let ref = ChatRef(id: obj["id"] as? String, titles: [(obj["topic"] as? String) ?? ""].filter { !$0.isEmpty })
            bridge.deliver(text, chat: ref) { ok in respond(HTTPResponse(json: ["ok": ok])) }
            return
        }
        if req.method == "GET", req.path == "/lastreply" {
            bridge.readLastReply { lines in respond(HTTPResponse(json: ["lines": lines])) }
            return
        }
        if req.method == "GET", req.path == "/dump" {
            bridge.dumpTree { url in respond(HTTPResponse(json: ["path": url?.path ?? ""])) }
            return
        }
        respond(route(req))
    }
}
