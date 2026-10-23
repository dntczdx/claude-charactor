import AppKit

/// 状态中枢：对话状态表、姿态、气泡队列、事件服务器、与 Claude 桌面版的桥接
final class PetController: NSObject {
    static let version = "0.1.0"

    private(set) var conversations: [Conversation] = []   // 最近活动在前
    let bridge = ClaudeBridge()

    private var windowController: PetWindowController!
    private var statusItem: StatusItemController!
    private var panel: ConversationPanel!
    private var server: EventServer?

    /// 还挂着的 /wait 长轮询：requestId → (回调, 超时计时器)
    private var waiters: [String: (completion: (String?) -> Void, timer: Timer)] = [:]
    /// 用户先答了、MCP 还没来取的答案
    private var pendingAnswers: [String: String] = [:]
    private var currentBubble: Conversation?
    private var bubbleTimer: Timer?
    private var axThinkTimer: Timer?
    private var axFallbackTimer: Timer?
    private var axConversation: Conversation?

    // MARK: 生命周期

    func start() {
        windowController = PetWindowController()
        windowController.onSpriteClick = { [weak self] in self?.togglePanel() }

        panel = ConversationPanel()
        panel.conversations = { [weak self] in self?.conversations ?? [] }
        panel.onOpen = { [weak self] c in
            self?.windowController.closePanel()
            self?.openConversation(c)
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
        windowController.setVisible(Settings.shared.showPet)
        windowController.walkingSettingChanged()
        recompute()
    }

    // MARK: HTTP 路由

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/health"):
            return HTTPResponse(json: ["ok": true, "version": Self.version, "accessibility": bridge.isTrusted, "conversations": conversations.count])

        case ("POST", "/notify"):
            guard let e = req.json(NotifyEvent.self), !e.topic.trimmingCharacters(in: .whitespaces).isEmpty else {
                return HTTPResponse(status: 400, json: ["error": "需要 JSON，至少含 topic"])
            }
            let id = handleNotify(e)
            return HTTPResponse(json: ["id": id, "state": conversation(id: id)?.state.label ?? ""])

        case ("GET", "/debug"):
            let sessions = SessionRegistry.snapshot().map { ["id": $0.chatID, "name": $0.name, "busy": $0.busy, "pid": Int($0.pid)] as [String: Any] }
            let convs = conversations.map { ["topic": $0.topic, "sidebar": $0.sidebarTitle ?? "", "chat": $0.chatID ?? "", "state": $0.state.label] }
            return HTTPResponse(json: ["accessibility": bridge.isTrusted, "foregroundTitle": bridge.currentTitle ?? "", "foregroundChat": bridge.currentChatID ?? "",
                                       "sessions": sessions, "conversations": convs, "registry": Settings.shared.chatRegistry])

        case ("POST", "/open"):
            // 诊断：按 topic / chat id 跳转，等同于点气泡里的「打开对话」
            let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            let c: Conversation
            if let id = obj["id"] as? String, !id.isEmpty {
                c = conversations.first { $0.chatID == id } ?? { let n = Conversation(topic: (obj["topic"] as? String) ?? id); n.chatID = id; return n }()
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
        let id = UUID().uuidString
        let c = conversation(forTopic: e.topic)
        c.topic = e.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        c.apply(e, requestId: id)
        if let s = SessionRegistry.caller(topic: c.topic, headline: c.headline) {
            // 正在生成的 Code 会话就是发 notify 的那条：直接绑定 ID 和侧栏标题
            if let other = conversations.first(where: { $0 !== c && $0.chatID == s.chatID }) {
                // 同一会话之前用别的 topic 记过：合并到旧的那条上
                conversations.removeAll { $0 === other }
                if axConversation === other { axConversation = c }
            }
            c.chatID = s.chatID
            if !s.name.isEmpty { c.sidebarTitle = s.name }
            Log.info("notify 绑定到 Code 会话 \(s.hostID.prefix(14)) 「\(s.name)」")
        } else if c.chatID == nil, sidebarBusyTitles.count == 1, let t = sidebarBusyTitles.first {
            if let other = conversations.first(where: { $0 !== c && $0.sidebarTitle == t }) {
                conversations.removeAll { $0 === other }
                if axConversation === other { axConversation = c }
                if c.chatID == nil { c.chatID = other.chatID }
            }
            c.sidebarTitle = t
            Log.info("notify 绑定到侧栏正在生成的对话「\(t)」")
        }
        linkToForegroundConversation(c)
        Log.info("notify topic=\(c.topic) state=\(c.state.label) options=\(c.options.count) id=\(id.prefix(8)) sidebar=\(c.sidebarTitle ?? "-") chat=\(c.chatID.map(Self.shortID) ?? "-")")
        cancelAXFallback()
        for key in fallbackTimers.keys where activeKeys[key] === c || key == c.chatID || key == "row:" + (c.sidebarTitle ?? "") {
            fallbackTimers.removeValue(forKey: key)?.invalidate()
        }
        bump(c)
        recompute()
        return id
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
        let c = conversation(forTopic: e.topic ?? "当前对话")
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
        windowController.markBubbleAnswered(text)
        scheduleBubbleHide(after: 3)

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
        } else {
            // 走辅助功能：切到那条对话，把答案填进输入框发出去
            Log.info("answer 「\(text)」→ 走辅助功能填进对话 titles=\(c.titlesForLookup)")
            c.state = .working
            bridge.deliver(text, chat: c.chatRef) { [weak self] ok in
                guard let self else { return }
                Log.info("deliver 结果 ok=\(ok)")
                if !ok {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    c.state = .idle
                    self.windowController.showWhisper("没能自动填进对话，答案已复制到剪贴板")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.recompute() }
                    self.bridge.open(chat: c.chatRef) { _ in }
                }
                self.recompute()
            }
        }
        c.updatedAt = Date()
        bump(c)
        NotificationCenter.default.post(name: .conversationsChanged, object: nil)
        statusItem.refresh()
        windowController.setPose(topPose())
    }

    func openConversation(_ c: Conversation) {
        c.unread = false
        if currentBubble === c { hideBubble() }
        if c.chatID == nil { c.chatID = lookupChatID(for: c) }
        Log.info("open id=\(c.chatID.map(Self.shortID) ?? "-") titles=\(c.titlesForLookup)")
        bridge.open(chat: c.chatRef) { [weak self] ok in
            Log.info("open 结果 ok=\(ok)")
            if !ok { self?.windowController.showWhisper("没在侧栏找到这条对话，只打开了 Claude") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.recompute() }
        }
        recompute()
    }

    func dismissBubble(_ c: Conversation) {
        c.unread = false
        if currentBubble === c { hideBubble() }
        recompute()
    }

    func markAllRead() {
        for c in conversations { c.unread = false }
        hideBubble()
        recompute()
    }

    func togglePanel() {
        windowController.togglePanel(panel)
    }

    func reloadAssets() {
        ClipLibrary.shared.rescan()
        windowController.refreshClip()
    }

    /// 菜单里的「测试一下气泡」：轮流演示完成 / 提问
    private var testToggle = false
    func injectTestEvent() {
        testToggle.toggle()
        let e: NotifyEvent
        if testToggle {
            e = NotifyEvent(topic: "博客列表分页方案", headline: "两种我都能做：无限滚动体验顺，页码方便收藏和 SEO。", summary: nil, points: nil,
                            question: "列表页用哪种分页？", options: ["页码分页（推荐）", "无限滚动", "两种都做，加个开关"], needsInput: nil, kind: "ask")
        } else {
            e = NotifyEvent(topic: "登录页表单校验", headline: "登录页校验改好了，3 个测试全过", summary: nil,
                            points: ["邮箱、密码改成提交时统一校验，提示跟在字段下", "校验规则抽到 validators.ts，登录注册共用", "补了 3 个单元测试"],
                            question: nil, options: nil, needsInput: nil, kind: "done")
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
            c.state = .done
            c.headline = "这条回复写完了"
            c.points = ["Claude 这次没调用 notify，点「打开对话」看原文"]
            c.question = nil
            c.options = []
            c.requestId = nil
            c.updatedAt = Date()
            c.unread = true
            self.bump(c)
            self.recompute()
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
            let c = conversation(forTopic: topic)
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
            guard let c = axConversation, c.state == .working || c.state == .thinking else { return }
            // 生成结束：给 MCP 的 notify 4 秒时间；没来就用兜底的完成提醒
            axFallbackTimer?.invalidate()
            let t = Timer(timeInterval: 4, repeats: false) { [weak self, weak c] _ in
                guard let self, let c, c.state == .working || c.state == .thinking else { return }
                if self.bridgeGenerating || self.stillBusyElsewhere(title: c.sidebarTitle ?? c.topic, chatID: c.chatID) {
                    Log.info("兜底提醒取消：\(c.topic) 还在生成")
                    return
                }
                c.state = .done
                c.headline = "这条回复写完了"
                c.points = ["Claude 这次没调用 notify，点「打开对话」看原文"]
                c.question = nil
                c.options = []
                c.requestId = nil
                c.updatedAt = Date()
                c.unread = true
                self.bump(c)
                self.recompute()
            }
            RunLoop.main.add(t, forMode: .common)
            axFallbackTimer = t
        }
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

    /// 按主题找对话：完全一致，或一方包含另一方（Claude 自己起的主题和侧栏标题常常只差几个字）
    private func conversation(forTopic topic: String) -> Conversation {
        let t = Self.normalize(topic)
        func names(_ c: Conversation) -> [String] { [c.topic, c.sidebarTitle].compactMap { $0 }.map(Self.normalize) }
        if let c = conversations.first(where: { names($0).contains(t) }) { return c }
        if t.count >= 4, let c = conversations.first(where: {
            names($0).contains { n in n.count >= 4 && (n.contains(t) || t.contains(n)) }
        }) { return c }
        let c = Conversation(topic: topic)
        conversations.insert(c, at: 0)
        if conversations.count > 30 { conversations.removeLast() }
        return c
    }

    private func bump(_ c: Conversation) {
        conversations.removeAll { $0 === c }
        conversations.insert(c, at: 0)
        NotificationCenter.default.post(name: .conversationsChanged, object: nil)
    }

    /// 所有对话里优先级最高的姿态
    private func topPose() -> Pose {
        let active = conversations.filter {
            $0.state == .working || $0.state == .thinking || ($0.state.showsBubble && $0.unread)
        }
        return (active.map(\.state).max() ?? .idle).pose
    }

    /// 重新决定姿态、气泡、轻提示
    func recompute() {
        windowController.setPose(topPose())

        let quiet = Settings.shared.quietMode
        let next = conversations
            .filter { $0.unread && $0.state.showsBubble && !quiet }
            .sorted { a, b in
                if a.state != b.state { return a.state > b.state }
                return a.updatedAt > b.updatedAt
            }
            .first
        if next !== currentBubble {
            showBubble(next)
        }

        if let busy = conversations.first(where: { $0.state == .working || $0.state == .thinking }) {
            windowController.showWhisper("\(busy.topic) · \(busy.state == .thinking ? "想一想…" : "正在写…")")
        } else {
            windowController.showWhisper(nil)
        }
        statusItem.refresh()
    }

    private func showBubble(_ c: Conversation?) {
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        currentBubble = c
        guard let c else {
            windowController.hideBubble()
            return
        }
        windowController.showBubble(
            for: c,
            onOpen: { [weak self] in self?.openConversation(c) },
            onAnswer: { [weak self] text in self?.answer(c, text: text) },
            onDismiss: { [weak self] in self?.dismissBubble(c) }
        )
        if c.state == .done {
            scheduleBubbleHide(after: Settings.shared.doneBubbleSeconds)
        }
    }

    private func scheduleBubbleHide(after s: TimeInterval) {
        bubbleTimer?.invalidate()
        let t = Timer(timeInterval: s, repeats: false) { [weak self] _ in
            guard let self, let c = self.currentBubble else { return }
            self.dismissBubble(c)
        }
        RunLoop.main.add(t, forMode: .common)
        bubbleTimer = t
    }

    private func hideBubble() {
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        currentBubble = nil
        windowController.hideBubble()
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
        if req.method == "GET", req.path == "/dump" {
            bridge.dumpTree { url in respond(HTTPResponse(json: ["path": url?.path ?? ""])) }
            return
        }
        respond(route(req))
    }
}
