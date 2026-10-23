import AppKit

/// 点大小姐弹出的对话面板（NSPopover）
final class ConversationPanel: NSViewController {
    var conversations: () -> [Conversation] = { [] }
    var onOpen: ((Conversation) -> Void)?
    var onMarkAllRead: (() -> Void)?

    private let stack = NSStackView()
    private var observer: Any?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 380),
        ])
        view = root
        observer = NotificationCenter.default.addObserver(forName: .conversationsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    func rebuild() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        // 标题行
        let head = NSStackView()
        head.orientation = .horizontal
        head.alignment = .centerY
        head.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 16)
        head.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "对话")
        title.font = Fonts.heavy(16)
        title.textColor = Palette.ink
        head.addArrangedSubview(title)
        head.addArrangedSubview(NSView())
        let all = PillButton("全部标为已读", style: .ghost, compact: true)
        all.target = self
        all.action = #selector(markAll)
        head.addArrangedSubview(all)
        head.widthAnchor.constraint(equalToConstant: 380).isActive = true
        stack.addArrangedSubview(head)

        let list = conversations()
        if list.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "还没有对话事件。\n让 Claude 桌面版里的对话跑起来，大小姐会把结果记在这里。")
            empty.font = Fonts.regular(13)
            empty.textColor = Palette.muted
            empty.preferredMaxLayoutWidth = 340
            let box = NSStackView(views: [empty])
            box.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 16, right: 16)
            box.widthAnchor.constraint(equalToConstant: 380).isActive = true
            stack.addArrangedSubview(box)
        }
        for c in list {
            let row = PanelRow(conversation: c)
            row.onClick = { [weak self] in self?.onOpen?(c) }
            stack.addArrangedSubview(row)
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 380, height: max(80, stack.fittingSize.height))
    }

    @objc private func markAll() { onMarkAllRead?() }
}

/// 面板里的一行
final class PanelRow: NSView {
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    init(conversation c: Conversation) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let top = NSView()
        top.wantsLayer = true
        top.layer?.backgroundColor = NSColor(srgbRed: 0xEE/255, green: 0xEC/255, blue: 0xE6/255, alpha: 1).cgColor
        top.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = Palette.dot(for: c.state).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: c.topic)
        name.font = Fonts.heavy(14)
        name.textColor = Palette.ink
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        let snip = NSTextField(labelWithString: c.snippet)
        snip.font = Fonts.regular(12)
        snip.textColor = Palette.muted
        snip.lineBreakMode = .byTruncatingTail
        snip.maximumNumberOfLines = 1
        let text = NSStackView(views: [name, snip])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        snip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chip = ChipView(text: c.state.label, state: c.state, maxWidth: 100)
        let time = NSTextField(labelWithString: relativeTime(c.updatedAt))
        time.font = Fonts.semibold(12)
        time.textColor = Palette.muted
        time.translatesAutoresizingMaskIntoConstraints = false

        addSubview(top)
        addSubview(dot)
        addSubview(text)
        addSubview(chip)
        addSubview(time)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 380),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.topAnchor.constraint(equalTo: topAnchor),
            top.heightAnchor.constraint(equalToConstant: 2),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            chip.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 10),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            time.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 10),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        time.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(srgbRed: 0xFA/255, green: 0xF9/255, blue: 0xF5/255, alpha: 1).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
