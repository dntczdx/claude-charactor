import AppKit
import ApplicationServices

/// 通过辅助功能 API 跟 Claude 桌面版打交道：
/// - 激活窗口、按标题切换到某条对话（侧栏点击，失败则 ⌘K 搜索）
/// - 把回答填进输入框并发送
/// - 轮询「停止生成」按钮，判断当前对话是否在生成；读窗口标题得到当前对话名
final class ClaudeBridge {
    static let bundleIDs = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]

    private let axQueue = DispatchQueue(label: "claudegirl.ax", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var lastGenerating = false
    private var lastTitle: String?
    private var enabledPID: pid_t = 0

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

    /// 当前（前台）对话的窗口标题
    var currentTitle: String? { lastTitle }

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

    /// 激活 Claude 并切到标题匹配 titles 里任一项的对话（按顺序试）。都找不到就只激活窗口。
    func open(titles: [String], completion: @escaping (Bool) -> Void) {
        activate { [weak self] ok in
            guard let self, ok else { completion(false); return }
            let wanted = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !wanted.isEmpty, self.isTrusted else { completion(ok); return }
            self.after(0.7) {
                self.axQueue.async {
                    // 已经在这条对话上了
                    if let win = self.mainWindow(), let cur = self.currentConversationTitle(window: win),
                       wanted.contains(where: { Self.similarity($0, cur) >= 0.6 }) {
                        DispatchQueue.main.async { completion(true) }
                        return
                    }
                    for t in wanted where self.pressConversationRow(matching: t) {
                        DispatchQueue.main.async { completion(true) }
                        return
                    }
                    // 侧栏里没找到（可能收起了，或标题对不上）：用搜索框
                    let found = self.searchAndOpen(wanted)
                    DispatchQueue.main.async { completion(found) }
                }
            }
        }
    }

    func open(topic: String?, completion: @escaping (Bool) -> Void) {
        open(titles: topic.map { [$0] } ?? [], completion: completion)
    }

    /// 切到对话，把 text 填进输入框，回车发送
    func deliver(_ text: String, titles: [String], completion: @escaping (Bool) -> Void) {
        guard isTrusted else { completion(false); return }
        open(titles: titles) { [weak self] _ in
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

    /// 每 1.5s 看一眼：是否在生成、当前对话标题
    func startObserving(_ onChange: @escaping (_ generating: Bool, _ title: String?) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: axQueue)
        t.schedule(deadline: .now() + 2, repeating: 1.5)
        t.setEventHandler { [weak self] in
            guard let self, self.isTrusted, self.runningApp != nil else { return }
            self.enableElectronAccessibility()
            guard let win = self.mainWindow() else { return }
            let generating = self.findStopButton(in: win) != nil
            let title = self.currentConversationTitle(window: win)
            if generating != self.lastGenerating || title != self.lastTitle {
                self.lastGenerating = generating
                self.lastTitle = title
                DispatchQueue.main.async { onChange(generating, title) }
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

    // MARK: 具体动作

    /// 窗口标题通常是「对话标题 - Claude」
    private func currentConversationTitle(window: AXUIElement) -> String? {
        guard var t = str(window, kAXTitleAttribute)?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        for suffix in [" - Claude", " – Claude", " | Claude", " — Claude", " — Claude", "- Claude"] {
            if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        }
        if t.isEmpty || t == "Claude" || t == "New chat" || t == "新对话" { return nil }
        return t
    }

    private func findStopButton(in window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        walk(window) { el, _ in
            guard self.role(el) == "AXButton" else { return false }
            let joined = self.texts(el).joined(separator: " ").lowercased()
            if joined.contains("stop") || joined.contains("停止") {
                found = el
                return true
            }
            return false
        }
        return found
    }

    /// 在侧栏找标题匹配的那一行并按下
    private func pressConversationRow(matching topic: String) -> Bool {
        guard let win = mainWindow() else { return false }
        var candidates: [(AXUIElement, Double)] = []
        walk(win) { el, _ in
            let r = self.role(el)
            guard r == "AXStaticText" || r == "AXLink" || r == "AXButton" || r == "AXCell" || r == "AXRow" || r == "AXMenuItem" else { return false }
            var best = 0.0
            for t in self.texts(el) where t.count <= 120 {
                best = max(best, Self.similarity(t, topic))
            }
            if best >= 0.5 { candidates.append((el, best)) }
            return false
        }
        Log.info("侧栏匹配「\(topic)」候选 \(candidates.count) 个")
        guard !candidates.isEmpty else { return false }
        candidates.sort { $0.1 > $1.1 }
        for (el, _) in candidates.prefix(4) {
            if press(elementOrAncestor: el) {
                Thread.sleep(forTimeInterval: 0.5)
                return true
            }
        }
        return false
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
        return false
    }

    /// ⌘K 打开「搜索对话」，输入标题，回车进第一个结果；用窗口标题验证
    private func searchAndOpen(_ titles: [String]) -> Bool {
        guard let query = titles.first else { return false }
        let before = mainWindow().flatMap { currentConversationTitle(window: $0) }
        postKey(40, flags: .maskCommand)                 // ⌘K
        Thread.sleep(forTimeInterval: 0.5)
        pasteText(query)
        Thread.sleep(forTimeInterval: 0.9)
        postKey(36, flags: [])                           // ↩︎
        Thread.sleep(forTimeInterval: 0.9)
        let after = mainWindow().flatMap { currentConversationTitle(window: $0) }
        Log.info("⌘K 搜索「\(query)」前=\(before ?? "-") 后=\(after ?? "-")")
        if let now = after, now != before, titles.contains(where: { Self.similarity($0, now) >= 0.4 }) {
            return true
        }
        postKey(53, flags: [])                           // ⎋ 收起搜索框
        return false
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
        if !focused {
            // 辅助功能聚焦不管用（网页里的富文本框常见）：在它中间点一下
            if let center = centerPoint(of: composer) {
                clickAt(center)
                Thread.sleep(forTimeInterval: 0.3)
            }
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
