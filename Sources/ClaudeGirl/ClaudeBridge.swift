import AppKit
import ApplicationServices

/// 要跳到的对话：优先用唯一 ID（claude.ai/chat/<uuid>），其次用标题
struct ChatRef {
    var id: String?
    var titles: [String]
}

/// 通过辅助功能 API 跟 Claude 桌面版打交道：
/// - 读网页区的 URL 得到当前对话的 UUID；读侧栏链接得到「标题 → UUID」
/// - 激活窗口、按 UUID（或标题）切换到某条对话
/// - 把回答填进输入框并发送
/// - 轮询「停止生成」按钮，判断当前对话是否在生成
final class ClaudeBridge {
    static let bundleIDs = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]

    private let axQueue = DispatchQueue(label: "claudegirl.ax", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var lastGenerating = false
    private var lastTitle: String?
    private var lastChatID: String?
    private var enabledPID: pid_t = 0
    private var tick = 0
    private var stopMissCount = 0

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    var runningApp: NSRunningApplication? {
        for id in Self.bundleIDs {
            if let a = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return a }
        }
        return nil
    }

    /// 最近一次轮询看到的前台对话标题 / UUID
    var currentTitle: String? { lastTitle }
    var currentChatID: String? { lastChatID }

    // MARK: 激活

    func activate(completion: @escaping (Bool) -> Void) {
        if let a = runningApp {
            a.activate(options: [.activateIgnoringOtherApps])
            completion(true)
            return
        }
        for id in Self.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                    DispatchQueue.main.async { completion(err == nil) }
                }
                return
            }
        }
        completion(false)
    }

    // MARK: 对外：打开对话 / 发送回答

    /// 激活 Claude 并切到 chat 指向的对话。顺序：已在该对话 → claude:// 链接（可选）→ 侧栏按 UUID → 侧栏按标题 → ⌘K 搜索
    func open(chat: ChatRef, completion: @escaping (Bool) -> Void) {
        activate { [weak self] ok in
            guard let self, ok else { completion(false); return }
            let titles = chat.titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            // 有 UUID 就直接用 claude:// 链接跳，不需要辅助功能权限
            var usedDeepLink = false
            if let id = chat.id, Settings.shared.useDeepLink, let url = Self.deepLink(for: id) {
                NSWorkspace.shared.open(url)
                usedDeepLink = true
                Log.info("跳转 \(url.absoluteString) 已发出")
            }
            guard self.isTrusted, chat.id != nil || !titles.isEmpty else { completion(ok); return }
            // 辅助功能可用：核对是否到了，没到再走侧栏 / 搜索
            self.after(usedDeepLink ? 1.4 : 0.6) {
                self.axQueue.async {
                    let result = self.navigate(to: chat.id, titles: titles, deepLinkTried: usedDeepLink)
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }

    /// 切到对话，把 text 填进输入框，回车发送
    func deliver(_ text: String, chat: ChatRef, completion: @escaping (Bool) -> Void) {
        guard isTrusted else { completion(false); return }
        open(chat: chat) { [weak self] _ in
            guard let self else { completion(false); return }
            self.after(0.9) {
                self.axQueue.async {
                    let ok = self.typeIntoComposer(text)
                    DispatchQueue.main.async { completion(ok) }
                }
            }
        }
    }

    // MARK: 观察生成状态

    struct SidebarRow {
        let id: String?
        let title: String
        let status: String?
        let busy: Bool
    }

    /// 每 1.5s 看一眼：是否在生成、前台对话标题与 ID；每 3s 扫一次侧栏，把所有对话行（标题、ID、状态前缀）交给 onSidebar
    func startObserving(onChange: @escaping (_ generating: Bool, _ title: String?, _ chatID: String?) -> Void,
                        onSidebar: @escaping ([SidebarRow]) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: axQueue)
        t.schedule(deadline: .now() + 2, repeating: 1.5)
        t.setEventHandler { [weak self] in
            guard let self, self.isTrusted, self.runningApp != nil else { return }
            self.enableElectronAccessibility()
            guard let win = self.mainWindow() else { return }
            let title = self.currentConversationTitle(window: win)
            let chatID = self.currentChatID(window: win)
            // 「停止」按钮偶尔会读不到（页面重排、思考中换了控件），连续 2 次没看到才算结束
            let stopSeen = self.findStopButton(in: win) != nil
            if stopSeen { self.stopMissCount = 0 } else { self.stopMissCount += 1 }
            let generating = stopSeen || (self.lastGenerating && self.stopMissCount < 2 && title == self.lastTitle)
            if generating != self.lastGenerating || title != self.lastTitle || chatID != self.lastChatID {
                self.lastGenerating = generating
                self.lastTitle = title
                self.lastChatID = chatID
                DispatchQueue.main.async { onChange(generating, title, chatID) }
            }
            self.tick += 1
            if self.tick % 2 == 1 {
                let rows = self.sidebarLinks(in: win).map { SidebarRow(id: $0.id, title: $0.title, status: $0.status, busy: $0.busy) }
                if !rows.isEmpty { DispatchQueue.main.async { onSidebar(rows) } }
            }
        }
        t.resume()
        pollTimer = t
    }

    func stopObserving() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    // MARK: AX 基础

    private func after(_ s: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: block)
    }

    private func axApp() -> AXUIElement? {
        runningApp.map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    /// Electron/Chromium 默认不构建网页的辅助功能树，要主动打开这个开关
    private func enableElectronAccessibility() {
        guard let app = runningApp, app.processIdentifier != enabledPID else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        enabledPID = app.processIdentifier
    }

    private func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        let r = AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return r == .success ? v : nil
    }

    private func element(_ v: AnyObject?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func str(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    private func urlString(_ el: AXUIElement) -> String? {
        guard let v = attr(el, kAXURLAttribute) else { return nil }
        if let u = v as? URL { return u.absoluteString }
        if let u = v as? NSURL { return u.absoluteString }
        if let s = v as? String { return s }
        return nil
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func role(_ el: AXUIElement) -> String {
        str(el, kAXRoleAttribute) ?? ""
    }

    /// 元素上所有能读到的文字
    private func texts(_ el: AXUIElement) -> [String] {
        var out: [String] = []
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute] {
            if let s = str(el, name), !s.isEmpty { out.append(s) }
        }
        return out
    }

    /// 元素及其后代（≤ 4 层）里的静态文字，拼成一句
    private func deepText(_ el: AXUIElement) -> String {
        var parts = texts(el)
        walk(el, maxNodes: 60, maxDepth: 4) { e, d in
            if d > 0, self.role(e) == "AXStaticText", let v = self.str(e, kAXValueAttribute), !v.isEmpty { parts.append(v) }
            return false
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func mainWindow() -> AXUIElement? {
        guard let app = axApp() else { return nil }
        enableElectronAccessibility()
        if let w = element(attr(app, kAXFocusedWindowAttribute)) { return w }
        if let w = element(attr(app, kAXMainWindowAttribute)) { return w }
        return (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    /// 深度优先遍历，visit 返回 true 时停止
    private func walk(_ root: AXUIElement, maxNodes: Int = 25000, maxDepth: Int = 60, visit: (AXUIElement, Int) -> Bool) {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var n = 0
        while let item = stack.popLast() {
            let (el, depth) = item
            n += 1
            if n > maxNodes { return }
            if visit(el, depth) { return }
            if depth < maxDepth {
                for c in children(el).reversed() { stack.append((c, depth + 1)) }
            }
        }
    }

    // MARK: 文本相似度

    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let scalars = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || ($0.value >= 0x3400 && $0.value <= 0x9FFF) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// 0…1：字符二元组重合度（对中文标题友好），互相包含直接算 1
    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a), nb = normalize(b)
        guard na.count >= 2, nb.count >= 2 else { return na == nb && !na.isEmpty ? 1 : 0 }
        if na.contains(nb) || nb.contains(na) { return 1 }
        func grams(_ s: String) -> Set<String> {
            let chars = Array(s)
            guard chars.count >= 2 else { return [s] }
            var set = Set<String>()
            for i in 0..<(chars.count - 1) { set.insert(String(chars[i...i + 1])) }
            return set
        }
        let ga = grams(na), gb = grams(nb)
        let inter = ga.intersection(gb).count
        return Double(inter) / Double(min(ga.count, gb.count))
    }

    /// 从页面 URL 里抠出对话 ID。两种页面：
    /// - 聊天：claude.ai/chat/<uuid> → "chat/<uuid>"
    /// - Code：claude.ai/epitaxy/local_<uuid> → "epitaxy/local_<uuid>"
    /// - Cowork：claude.ai/cowork/cse_<id> → "cowork/cse_<id>"
    /// 这个 ID 拼上 claude://claude.ai/ 就是深链接。
    static func chatID(from url: String?) -> String? {
        guard let url else { return nil }
        if let r = url.range(of: "/chat/") {
            let id = url[r.upperBound...].prefix { $0.isHexDigit || $0 == "-" }
            if id.count >= 32 { return "chat/" + String(id).lowercased() }
        }
        // Code 会话 /epitaxy/local_…、Cowork 会话 /cowork/cse_…、云端会话 /code/…
        for seg in ["epitaxy", "cowork", "code"] {
            if let r = url.range(of: "/\(seg)/") {
                let id = url[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                if id.count >= 8 { return seg + "/" + String(id) }
            }
        }
        return nil
    }

    /// 老版本登记表里存的是裸 uuid，补上 chat/ 前缀
    static func normalizeID(_ id: String) -> String {
        id.contains("/") ? id : "chat/" + id
    }

    /// 日志里用的短 ID：去掉 chat/ 或 epitaxy/local_ 前缀后取前 8 位
    static func shortID(_ id: String) -> String {
        let body = id.split(separator: "/").last.map(String.init) ?? id
        return String(body.replacingOccurrences(of: "local_", with: "").prefix(8))
    }

    static func deepLink(for id: String) -> URL? {
        URL(string: "claude://claude.ai/" + normalizeID(id))
    }

    // MARK: 读取：标题 / 当前 UUID / 侧栏链接

    /// 去掉「 - Claude」「 - Claude Code」之类的后缀
    private static func stripTitle(_ raw: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        for suffix in [" - Claude Code", " – Claude Code", " — Claude Code", " | Claude Code",
                       " - Claude", " – Claude", " | Claude", " — Claude", "- Claude"] {
            if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        }
        if t.isEmpty || t == "Claude" || t == "Claude Code" || t == "New chat" || t == "New session" || t == "新对话" { return nil }
        return t
    }

    /// 对话标题：桌面版的窗口标题只是「Claude」，真正的标题在 claude.ai 那个网页区上（「xxx - Claude Code」）；
    /// 聊天页则是窗口标题「xxx - Claude」
    private func currentConversationTitle(window: AXUIElement) -> String? {
        if let web = claudeWebArea(in: window), let t = Self.stripTitle(str(web, kAXTitleAttribute)) { return t }
        return Self.stripTitle(str(window, kAXTitleAttribute))
    }

    /// 窗口里所有网页区（Electron 外面套一层 file:// 的壳，里面才是 claude.ai 的页面）
    private func webAreas(in window: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        walk(window, maxNodes: 600, maxDepth: 14) { el, _ in
            if self.role(el) == "AXWebArea" { found.append(el) }
            return false
        }
        return found
    }

    private func pageURL(_ web: AXUIElement) -> String? {
        if let u = urlString(web) { return u }
        return str(web, "AXDocument")
    }

    /// 地址是 claude.ai 的那个网页区
    private func claudeWebArea(in window: AXUIElement) -> AXUIElement? {
        let areas = webAreas(in: window)
        if let w = areas.first(where: { (self.pageURL($0) ?? "").contains("claude.ai") }) { return w }
        return areas.last
    }

    /// 网页区的 AXURL 就是当前页面地址，里面有对话 ID
    private func currentChatID(window: AXUIElement) -> String? {
        for web in webAreas(in: window) {
            if let id = Self.chatID(from: pageURL(web)) { return id }
        }
        return nil
    }

    struct SidebarLink {
        let id: String?          // 聊天页旧版链接带 UUID；现在的会话/对话行是按钮，没有 ID，只能按标题
        let title: String
        let status: String?      // 聊天页行按钮的标题前缀（"Mark as unread" / "Idle" / 生成中的状态字样）
        let element: AXUIElement

        /// 行前缀是否表示正在生成
        var busy: Bool {
            guard let st = status?.lowercased(), !st.isEmpty else { return false }
            return ["working", "running", "generating", "thinking", "writing", "in progress", "responding", "正在", "生成中", "运行中", "思考"]
                .contains { st.contains($0) }
        }
    }

    /// 侧栏里的对话入口：
    /// - 旧版聊天页：指向 /chat/<uuid> 的 AXLink
    /// - Code 页：会话行是 AXButton（title=会话名）
    /// - 聊天页：对话行是 AXButton，title=「<状态> <对话名>」（"Mark as unread xxx" / "Idle xxx" / 生成中的状态…）
    /// 两种行旁边都有「More options for <名字>」的弹出按钮，用它来区分导航按钮并切出状态前缀
    func sidebarLinks(in window: AXUIElement) -> [SidebarLink] {
        var out: [SidebarLink] = []
        var seen = Set<String>()
        var buttons: [(title: String, element: AXUIElement)] = []
        var rowTitles = Set<String>()
        walk(window) { el, _ in
            let r = self.role(el)
            if r == "AXLink", let id = Self.chatID(from: self.urlString(el)) {
                if !seen.contains(id) {
                    seen.insert(id)
                    out.append(SidebarLink(id: id, title: self.deepText(el), status: nil, element: el))
                }
            } else if r == "AXButton", let t = self.str(el, kAXTitleAttribute)?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
                buttons.append((t, el))
            } else if r == "AXPopUpButton", let d = self.str(el, kAXDescriptionAttribute) {
                for prefix in ["More options for ", "更多选项："] where d.hasPrefix(prefix) {
                    rowTitles.insert(String(d.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
                }
            }
            return false
        }
        var seenTitles = Set<String>()
        // 长标题优先匹配，避免「xxx」被「yyy xxx」的后缀误配
        let sortedTitles = rowTitles.sorted { $0.count > $1.count }
        for b in buttons {
            var matched: String?
            var status: String?
            if rowTitles.contains(b.title) {
                matched = b.title
            } else if let t = sortedTitles.first(where: { b.title.hasSuffix(" " + $0) }) {
                matched = t
                status = String(b.title.dropLast(t.count)).trimmingCharacters(in: .whitespaces)
            }
            guard let t = matched, !seenTitles.contains(t) else { continue }
            seenTitles.insert(t)
            out.append(SidebarLink(id: nil, title: t, status: status, element: b.element))
        }
        return out
    }

    // MARK: 读取前台对话里 Claude 最后一条回复

    /// 前台对话里 Claude 最后一条回复的文字（按段落），用于 Claude 没调用 notify 时的兜底气泡。
    /// 消息是 AXDocumentArticle，标题「Claude responded: …」；正文是其中的 AXStaticText。
    func readLastReply(completion: @escaping ([String]) -> Void) {
        axQueue.async { [weak self] in
            guard let self, self.isTrusted, let win = self.mainWindow() else { DispatchQueue.main.async { completion([]) }; return }
            var lastClaude: AXUIElement?
            self.walk(win, maxNodes: 30000, maxDepth: 60) { el, _ in
                guard self.role(el) == "AXGroup", (self.str(el, kAXSubroleAttribute) ?? "") == "AXDocumentArticle" else { return false }
                // 标题（AXHeading）说明是谁说的
                var heading: String?
                self.walk(el, maxNodes: 40, maxDepth: 3) { h, _ in
                    if self.role(h) == "AXHeading" { heading = self.str(h, kAXTitleAttribute); return true }
                    return false
                }
                if let h = heading, h.hasPrefix("Claude responded") || h.hasPrefix("Claude 回复") { lastClaude = el }
                return false
            }
            var lines: [String] = []
            if let art = lastClaude {
                self.walk(art, maxNodes: 600, maxDepth: 12) { el, _ in
                    let r = self.role(el)
                    if r == "AXToolbar" { return false }
                    if r == "AXStaticText", let v = self.str(el, kAXValueAttribute) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty, !t.hasPrefix("Claude responded"), !t.hasPrefix("Claude 回复") {
                            // 行内片段（加粗词后面接「：…」之类）并回上一段
                            if let f = t.first, "：:，,。；;、）)".contains(f), !lines.isEmpty { lines[lines.count - 1] += t }
                            else { lines.append(t) }
                        }
                    }
                    return false
                }
            }
            DispatchQueue.main.async { completion(lines) }
        }
    }

    // MARK: 诊断：导出窗口结构

    /// 把 Claude 窗口的辅助功能树（前 N 个节点）写到 ~/Library/Logs/ClaudeGirl-axdump.txt
    func dumpTree(completion: @escaping (URL?) -> Void) {
        axQueue.async { [weak self] in
            guard let self, let win = self.mainWindow() else { DispatchQueue.main.async { completion(nil) }; return }
            var lines: [String] = []
            lines.append("window title: \(self.str(win, kAXTitleAttribute) ?? "-")")
            lines.append("window document: \(self.str(win, "AXDocument") ?? "-")")
            lines.append("window url: \(self.urlString(win) ?? "-")")
            var n = 0
            self.walk(win, maxNodes: 6000, maxDepth: 60) { el, depth in
                n += 1
                let r = self.role(el)
                let sub = self.str(el, kAXSubroleAttribute) ?? ""
                var bits: [String] = []
                if let t = self.str(el, kAXTitleAttribute), !t.isEmpty { bits.append("title=\(t.prefix(60))") }
                if let d = self.str(el, kAXDescriptionAttribute), !d.isEmpty { bits.append("desc=\(d.prefix(60))") }
                if let v = self.str(el, kAXValueAttribute), !v.isEmpty { bits.append("value=\(v.prefix(60))") }
                if let u = self.urlString(el) { bits.append("url=\(u.prefix(120))") }
                if let doc = self.str(el, "AXDocument") { bits.append("doc=\(doc.prefix(120))") }
                if let dom = self.str(el, "AXDOMIdentifier"), !dom.isEmpty { bits.append("id=\(dom.prefix(40))") }
                // 只记录有信息量的节点，纯容器跳过
                let interesting = !bits.isEmpty || r == "AXWebArea" || r == "AXLink" || r == "AXButton" || r == "AXTextArea"
                if interesting && lines.count < 2500 {
                    lines.append(String(repeating: " ", count: min(depth, 40)) + "[\(r)\(sub.isEmpty ? "" : "/" + sub)] " + bits.joined(separator: " | "))
                }
                return false
            }
            lines.append("nodes visited: \(n)")
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeGirl-axdump.txt")
            try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: url)
            DispatchQueue.main.async { completion(url) }
        }
    }

    // MARK: 跳转

    private func navigate(to rawID: String?, titles: [String], deepLinkTried: Bool = false) -> Bool {
        let id = rawID.map(Self.normalizeID)
        guard let win0 = mainWindow() else { return false }
        let curID = currentChatID(window: win0)
        let curTitle = currentConversationTitle(window: win0)
        Log.info("跳转 目标id=\(id.map(ClaudeBridge.shortID) ?? "-") titles=\(titles) 当前id=\(curID.map(Self.shortID) ?? "-") 当前标题=\(curTitle ?? "-")")

        // 1. 已经在这条对话上
        if let id, curID == id { return true }
        if id == nil, let cur = curTitle, titles.contains(where: { Self.similarity($0, cur) >= 0.8 }) { return true }

        // 2. claude:// 链接（open(chat:) 里没发过才发）
        if let id, !deepLinkTried, Settings.shared.useDeepLink, let url = Self.deepLink(for: id) {
            DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) }
            Thread.sleep(forTimeInterval: 1.4)
            if let w = mainWindow(), currentChatID(window: w) == id {
                Log.info("跳转 claude:// 成功")
                return true
            }
            Log.info("跳转 claude:// 未命中")
        }

        // 3. 侧栏按 UUID 精确匹配
        let links = sidebarLinks(in: win0)
        Log.info("侧栏链接 \(links.count) 条")
        if let id, let link = links.first(where: { $0.id == id }) {
            if press(elementOrAncestor: link.element), verifyArrived(id: id, titles: titles) {
                Log.info("跳转 侧栏按 UUID 成功")
                return true
            }
        }

        // 4. 侧栏按标题（要求很像）
        if pressRow(matching: titles, in: links, id: id) { return true }

        // 4.5 侧栏里没有：聊天/Cowork 和 Code 两个模式的侧栏互不显示，切到另一个模式再找一次
        if !titles.isEmpty, switchSidebarMode(in: win0) {
            Thread.sleep(forTimeInterval: 0.9)
            if let w = mainWindow() {
                let links2 = sidebarLinks(in: w)
                Log.info("切换侧栏模式后 \(links2.count) 条")
                if pressRow(matching: titles, in: links2, id: id) { return true }
            }
        }

        // 5. ⌘K 搜索
        if let q = titles.first {
            return searchAndOpen(query: q, id: id, titles: titles)
        }
        return false
    }

    /// 在侧栏行里按标题找最像的（≥ 0.7），点它并核对
    private func pressRow(matching titles: [String], in links: [SidebarLink], id: String?) -> Bool {
        guard !titles.isEmpty else { return false }
        let scored = links.map { l in (l, titles.map { Self.similarity($0, l.title) }.max() ?? 0) }
            .filter { $0.1 >= 0.7 }
            .sorted { $0.1 > $1.1 }
        for (l, s) in scored.prefix(2) {
            if press(elementOrAncestor: l.element), verifyArrived(id: id, titles: titles + [l.title]) {
                Log.info("跳转 侧栏按标题成功（相似度 \(String(format: "%.2f", s))：\(l.title)）")
                return true
            }
        }
        return false
    }

    /// 侧栏顶部的「Mode」单选组（Chat and Cowork / Code）：按下当前没选中的那个
    private func switchSidebarMode(in window: AXUIElement) -> Bool {
        var group: AXUIElement?
        walk(window, maxNodes: 3000, maxDepth: 30) { el, _ in
            if self.role(el) == "AXRadioGroup", (self.str(el, kAXDescriptionAttribute) ?? "").lowercased() == "mode" { group = el; return true }
            return false
        }
        guard let group else { return false }
        for b in children(group) where role(b) == "AXRadioButton" {
            let selected = (attr(b, kAXValueAttribute) as? Int) == 1 || (attr(b, kAXValueAttribute) as? Bool) == true
            if !selected {
                let ok = AXUIElementPerformAction(b, kAXPressAction as CFString) == .success
                if !ok, let p = centerPoint(of: b) { clickAt(p) }
                Log.info("切换侧栏模式 → \(self.str(b, kAXDescriptionAttribute) ?? "?")")
                return true
            }
        }
        return false
    }

    /// 点完等页面切换，再核对 UUID 或标题
    private func verifyArrived(id: String?, titles: [String]) -> Bool {
        Thread.sleep(forTimeInterval: 0.7)
        guard let w = mainWindow() else { return false }
        if let id, let cur = currentChatID(window: w) { return cur == Self.normalizeID(id) }
        if let cur = currentConversationTitle(window: w) {
            return titles.contains(where: { Self.similarity($0, cur) >= 0.7 })
        }
        return false
    }

    private func findStopButton(in window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        walk(window) { el, _ in
            guard self.role(el) == "AXButton" else { return false }
            let joined = self.texts(el).joined(separator: " ").lowercased()
            if joined.contains("stop") || joined.contains("停止") || joined.contains("取消生成") || joined.contains("cancel generation") {
                found = el
                return true
            }
            return false
        }
        return found
    }

    private func press(elementOrAncestor el: AXUIElement) -> Bool {
        var cur: AXUIElement? = el
        var tried: [AXUIElement] = []
        for _ in 0..<7 {
            guard let e = cur else { break }
            let r = role(e)
            if ["AXButton", "AXLink", "AXRow", "AXCell", "AXMenuItem"].contains(r) {
                if AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return true }
            }
            tried.append(e)
            cur = element(attr(e, kAXParentAttribute))
        }
        for e in tried.prefix(3) {
            if AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return true }
        }
        // 最后一招：在元素中心点一下
        if let p = centerPoint(of: el) {
            clickAt(p)
            return true
        }
        return false
    }

    /// ⌘K 打开「搜索对话」，输入标题，回车进第一个结果；核对 UUID / 标题
    private func searchAndOpen(query: String, id: String?, titles: [String]) -> Bool {
        postKey(40, flags: .maskCommand)                 // ⌘K
        Thread.sleep(forTimeInterval: 0.5)
        pasteText(query)
        Thread.sleep(forTimeInterval: 1.0)
        postKey(36, flags: [])                           // ↩︎
        let ok = verifyArrived(id: id, titles: titles)
        Log.info("⌘K 搜索「\(query)」结果 ok=\(ok)")
        if !ok { postKey(53, flags: []) }                // ⎋ 收起搜索框
        return ok
    }

    /// 找到输入框，粘贴文字并回车
    private func typeIntoComposer(_ text: String) -> Bool {
        guard let win = mainWindow() else { return false }
        var fields: [AXUIElement] = []
        walk(win) { el, _ in
            let r = self.role(el)
            if r == "AXTextArea" || r == "AXTextField" || r == "AXComboBox" {
                fields.append(el)
            }
            return false
        }
        Log.info("输入框候选 \(fields.count) 个")
        guard !fields.isEmpty else { return false }
        // 优先：占位文字像输入框的；否则取最后一个（输入框在页面底部）
        let composer = fields.first(where: { el in
            let p = (self.str(el, kAXPlaceholderValueAttribute) ?? "").lowercased()
            return p.contains("claude") || p.contains("reply") || p.contains("message") || p.contains("回复") || p.contains("消息")
        }) ?? fields.last!

        AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.25)
        let focused = (attr(composer, kAXFocusedAttribute) as? Bool) ?? false
        if !focused, let center = centerPoint(of: composer) {
            // 辅助功能聚焦不管用（网页里的富文本框常见）：在它中间点一下
            clickAt(center)
            Thread.sleep(forTimeInterval: 0.3)
        }
        pasteText(text)
        Thread.sleep(forTimeInterval: 0.35)

        var typed = (str(composer, kAXValueAttribute) ?? "").contains(text.prefix(8))
        if !typed {
            if AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                Thread.sleep(forTimeInterval: 0.2)
                typed = (str(composer, kAXValueAttribute) ?? "").contains(text.prefix(8))
            }
        }
        Log.info("输入框 focused=\(focused) typed=\(typed)")
        if typed {
            postKey(36, flags: [])                 // ↩︎
        }
        return typed
    }

    /// 元素在屏幕上的中心（AX 坐标系：左上角为原点，和 CGEvent 一致）
    private func centerPoint(of el: AXUIElement) -> CGPoint? {
        guard let posV = attr(el, kAXPositionAttribute), let sizeV = attr(el, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posV as! AXValue, .cgPoint, &pos), AXValueGetValue(sizeV as! AXValue, .cgSize, &size) else { return nil }
        guard size.width > 0, size.height > 0 else { return nil }
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + min(size.height / 2, 20))
    }

    private func clickAt(_ p: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
        up.post(tap: .cghidEventTap)
    }

    /// 用剪贴板粘贴（对网页里的富文本输入框最可靠），1 秒后恢复剪贴板
    private func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(9, flags: .maskCommand)          // ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        up.post(tap: .cghidEventTap)
    }
}
