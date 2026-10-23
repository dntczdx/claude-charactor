import AppKit

/// 菜单栏入口：对话列表 + 开关
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private unowned let controller: PetController

    init(controller: PetController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "克劳德大小姐")
            b.imagePosition = .imageLeading
            b.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        }
        menu.delegate = self
        item.menu = menu
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .conversationsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .settingsChanged, object: nil)
    }

    /// 标题：例如 "1 在忙 · 1 完成 · 1 等你"
    @objc func refresh() {
        let list = controller.conversations
        let busy = list.filter { $0.state == .working || $0.state == .thinking }.count
        let done = list.filter { $0.state == .done && $0.unread }.count
        let ask = list.filter { $0.state == .ask && $0.unread }.count
        let err = list.filter { $0.state == .error && $0.unread }.count
        var parts: [String] = []
        if busy > 0 { parts.append("\(busy) 在忙") }
        if done > 0 { parts.append("\(done) 完成") }
        if ask > 0 { parts.append("\(ask) 等你") }
        if err > 0 { parts.append("\(err) 出错") }
        item.button?.title = parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let list = controller.conversations
        let header = NSMenuItem(title: list.isEmpty ? "还没有对话事件" : "对话 · \(list.count)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for c in list.prefix(12) {
            let mi = NSMenuItem(title: "\(c.topic)　\(c.state.label)", action: #selector(openConversation(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = c.id
            mi.image = dotImage(Palette.dot(for: c.state))
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        let s = Settings.shared
        menu.addItem(toggle("显示大小姐", on: s.showPet, action: #selector(toggleShow)))
        menu.addItem(toggle("安静模式（只记录不弹泡）", on: s.quietMode, action: #selector(toggleQuiet)))
        menu.addItem(toggle("允许到处走（蹦着挪）", on: s.allowWalking, action: #selector(toggleWalk)))
        menu.addItem(.separator())

        let test = NSMenuItem(title: "测试一下气泡", action: #selector(testBubble), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        let ax = NSMenuItem(title: controller.bridge.isTrusted ? "辅助功能权限：已授权" : "授权辅助功能（用于跳转对话、代填回答）…", action: #selector(requestAX), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)
        let reload = NSMenuItem(title: "重新载入动画素材", action: #selector(reloadAssets), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
        let port = NSMenuItem(title: "事件端口：127.0.0.1:\(Settings.shared.port)", action: nil, keyEquivalent: "")
        port.isEnabled = false
        menu.addItem(port)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func toggle(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.state = on ? .on : .off
        return mi
    }

    private func dotImage(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return img
    }

    @objc private func openConversation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let c = controller.conversations.first(where: { $0.id == id }) else { return }
        controller.openConversation(c)
    }
    @objc private func toggleShow() { Settings.shared.showPet.toggle() }
    @objc private func toggleQuiet() { Settings.shared.quietMode.toggle() }
    @objc private func toggleWalk() { Settings.shared.allowWalking.toggle() }
    @objc private func testBubble() { controller.injectTestEvent() }
    @objc private func requestAX() { controller.bridge.requestTrust() }
    @objc private func reloadAssets() { controller.reloadAssets() }
    @objc private func quit() { NSApp.terminate(nil) }
}
