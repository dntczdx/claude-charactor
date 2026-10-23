import AppKit
import QuartzCore

// MARK: - 颜色 / 字体

enum Palette {
    static let ink = NSColor(srgbRed: 0x14/255, green: 0x14/255, blue: 0x13/255, alpha: 1)
    static let paper = NSColor.white
    static let body = NSColor(srgbRed: 0x2B/255, green: 0x2A/255, blue: 0x28/255, alpha: 1)
    static let muted = NSColor(srgbRed: 0x6B/255, green: 0x67/255, blue: 0x5F/255, alpha: 1)
    static let clay = NSColor(srgbRed: 0xD9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
    static let orange = NSColor(srgbRed: 0xF0/255, green: 0x8A/255, blue: 0x3C/255, alpha: 1)
    static let optionBg = NSColor(srgbRed: 0xFF/255, green: 0xF8/255, blue: 0xEE/255, alpha: 1)
    static let optionHover = NSColor(srgbRed: 0xFD/255, green: 0xE7/255, blue: 0xC8/255, alpha: 1)

    static func dot(for s: ConvState) -> NSColor {
        switch s {
        case .done: return NSColor(srgbRed: 0x1F/255, green: 0x8A/255, blue: 0x4C/255, alpha: 1)
        case .ask: return NSColor(srgbRed: 0xB2/255, green: 0x62/255, blue: 0x00/255, alpha: 1)
        case .error: return NSColor(srgbRed: 0xC0/255, green: 0x39/255, blue: 0x2B/255, alpha: 1)
        case .working, .thinking: return clay
        case .idle: return NSColor(srgbRed: 0x8A/255, green: 0x86/255, blue: 0x7E/255, alpha: 1)
        }
    }
    static func chipBackground(for s: ConvState) -> NSColor {
        switch s {
        case .done: return NSColor(srgbRed: 0xE4/255, green: 0xF3/255, blue: 0xE9/255, alpha: 1)
        case .ask: return NSColor(srgbRed: 0xFB/255, green: 0xEE/255, blue: 0xDC/255, alpha: 1)
        case .error: return NSColor(srgbRed: 0xFB/255, green: 0xE3/255, blue: 0xDF/255, alpha: 1)
        case .working, .thinking: return NSColor(srgbRed: 0xFB/255, green: 0xE7/255, blue: 0xDD/255, alpha: 1)
        case .idle: return NSColor(srgbRed: 0xF2/255, green: 0xF0/255, blue: 0xEB/255, alpha: 1)
        }
    }
    static func chipText(for s: ConvState) -> NSColor {
        switch s {
        case .done: return NSColor(srgbRed: 0x1F/255, green: 0x7A/255, blue: 0x44/255, alpha: 1)
        case .ask: return NSColor(srgbRed: 0x9A/255, green: 0x53/255, blue: 0x00/255, alpha: 1)
        case .error: return NSColor(srgbRed: 0xA8/255, green: 0x32/255, blue: 0x1F/255, alpha: 1)
        case .working, .thinking: return NSColor(srgbRed: 0xA6/255, green: 0x4E/255, blue: 0x2B/255, alpha: 1)
        case .idle: return muted
        }
    }
}

enum Fonts {
    static func heavy(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .heavy) }
    static func bold(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .bold) }
    static func semibold(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }
    static func regular(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .regular) }
}

func relativeTime(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(s / 60) 分钟" }
    if s < 86400 { return "\(s / 3600) 小时" }
    return "\(s / 86400) 天"
}

// MARK: - 小控件

/// 自动换行的只读文字
final class WrapLabel: NSTextField {
    init(_ text: String, font: NSFont, color: NSColor, width: CGFloat, maxLines: Int = 0) {
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        textColor = color
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = maxLines
        cell?.wraps = true
        cell?.isScrollable = false
        preferredMaxLayoutWidth = width
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 圆角小标签（对话标题徽标）
final class ChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    init(text: String, state: ConvState, maxWidth: CGFloat = 230) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Palette.chipBackground(for: state).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = Palette.chipText(for: state).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
        label.font = Fonts.heavy(12)
        label.textColor = Palette.chipText(for: state)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 漫画风按钮：黑底白字（primary）或白底黑边（ghost）
final class PillButton: NSButton {
    enum Style { case primary, ghost, option, send }
    private let style: Style
    private var hovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?
    private let compact: Bool

    init(_ title: String, style: Style, compact: Bool = false) {
        self.style = style
        self.compact = compact
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        setButtonType(.momentaryChange)
        layer?.cornerRadius = style == .option ? 12 : 10
        layer?.borderWidth = 2
        translatesAutoresizingMaskIntoConstraints = false
        if style == .option { alignment = .left }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let ink = Palette.ink
        var bg: NSColor
        var fg: NSColor
        switch style {
        case .primary:
            bg = hovering ? Palette.body : ink
            fg = .white
        case .ghost:
            bg = hovering ? NSColor(srgbRed: 0xF2/255, green: 0xF0/255, blue: 0xEB/255, alpha: 1) : .white
            fg = ink
        case .option:
            bg = hovering ? Palette.optionHover : Palette.optionBg
            fg = ink
        case .send:
            bg = hovering ? Palette.orange : Palette.clay
            fg = .white
        }
        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = ink.cgColor
        let para = NSMutableParagraphStyle()
        para.alignment = style == .option ? .left : .center
        para.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Fonts.heavy(compact ? 12 : 13),
            .foregroundColor: fg,
            .paragraphStyle: para,
        ])
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        switch style {
        case .send:
            return NSSize(width: 36, height: 36)
        case .option:
            s.width += 28
            s.height = 40
        default:
            s.width += compact ? 20 : 28
            s.height = compact ? 30 : 36
        }
        return s
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 气泡里的输入框
final class ReplyField: NSTextField {
    init(placeholder: String) {
        super.init(frame: .zero)
        let padded = PaddedCell(textCell: "")
        padded.isEditable = true
        padded.isSelectable = true
        padded.usesSingleLineMode = true
        padded.isScrollable = true
        padded.lineBreakMode = .byTruncatingTail
        cell = padded
        isEditable = true
        isSelectable = true
        placeholderString = placeholder
        font = Fonts.semibold(13)
        textColor = Palette.ink
        isBordered = false
        drawsBackground = true
        backgroundColor = .white
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 2
        layer?.borderColor = Palette.ink.cgColor
        maximumNumberOfLines = 1
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // 左右留点内边距
    override func drawFocusRingMask() {}
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }
}

/// 让 NSTextField 的文字离边框远一点
final class PaddedCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let r = rect.insetBy(dx: 10, dy: 0)
        return super.drawingRect(forBounds: r)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: rect.insetBy(dx: 10, dy: 0), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: rect.insetBy(dx: 10, dy: 0), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

// MARK: - 漫画气泡

/// 白底粗墨边 + 硬阴影 + 小尾巴的漫画气泡。
/// 内容：对话标题徽标、一句结论、要点、问题 + 选项、输入框、动作按钮。
final class BubbleView: NSView {
    static let width: CGFloat = 360
    static let tail: CGFloat = 22
    static let shadow: CGFloat = 6
    static let radius: CGFloat = 18
    static let padX: CGFloat = 18
    static let padY: CGFloat = 14
    static var contentWidth: CGFloat { width - tail - shadow - padX * 2 }

    let conversation: Conversation
    let tailOnRight: Bool

    var onOpen: (() -> Void)?
    var onAnswer: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let stack = NSStackView()
    private var replyRow: NSStackView?
    private var replyField: ReplyField?
    private var picked: String?

    init(conversation: Conversation, tailOnRight: Bool) {
        self.conversation = conversation
        self.tailOnRight = tailOnRight
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        buildContent()
        layoutContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    // 气泡主体（不含尾巴与阴影）在自身坐标里的矩形
    private var bodyRect: NSRect {
        var r = bounds
        r.size.width -= BubbleView.tail + BubbleView.shadow
        r.origin.x = tailOnRight ? 0 : BubbleView.tail
        r.size.height -= BubbleView.shadow
        r.origin.y = BubbleView.shadow
        return r
    }

    private func buildContent() {
        let c = conversation
        let w = BubbleView.contentWidth
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 头部：徽标 + 时间
        let head = NSStackView()
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8
        head.translatesAutoresizingMaskIntoConstraints = false
        let chip = ChipView(text: c.topic, state: c.state)
        let time = NSTextField(labelWithString: relativeTime(c.updatedAt))
        time.font = Fonts.semibold(12)
        time.textColor = Palette.muted
        time.setContentHuggingPriority(.required, for: .horizontal)
        head.addArrangedSubview(chip)
        head.addArrangedSubview(NSView())
        head.addArrangedSubview(time)
        head.widthAnchor.constraint(equalToConstant: w).isActive = true
        stack.addArrangedSubview(head)

        // 标题（结论 / 问题）
        let titleText: String = {
            if c.state == .ask, let q = c.question, !q.isEmpty { return q }
            if !c.headline.isEmpty { return c.headline }
            switch c.state {
            case .done: return "这条做完啦"
            case .error: return "呜，这里出错了"
            case .ask: return "要你拿个主意"
            default: return c.state.label
            }
        }()
        stack.addArrangedSubview(WrapLabel(titleText, font: Fonts.heavy(18), color: Palette.ink, width: w))

        // 提问时如果另有结论，当作补充说明
        if c.state == .ask, let q = c.question, !q.isEmpty, !c.headline.isEmpty, c.headline != q {
            stack.addArrangedSubview(WrapLabel(c.headline, font: Fonts.regular(13), color: Palette.body, width: w))
        }

        // 要点
        if !c.points.isEmpty {
            let list = NSStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 5
            list.translatesAutoresizingMaskIntoConstraints = false
            for p in c.points {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .top
                row.spacing = 8
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 3
                dot.layer?.backgroundColor = Palette.dot(for: c.state == .error ? .error : .done).cgColor
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
                let dotBox = NSView()
                dotBox.translatesAutoresizingMaskIntoConstraints = false
                dotBox.addSubview(dot)
                dotBox.widthAnchor.constraint(equalToConstant: 8).isActive = true
                dotBox.heightAnchor.constraint(equalToConstant: 18).isActive = true
                dot.centerXAnchor.constraint(equalTo: dotBox.centerXAnchor).isActive = true
                dot.centerYAnchor.constraint(equalTo: dotBox.centerYAnchor).isActive = true
                row.addArrangedSubview(dotBox)
                row.addArrangedSubview(WrapLabel(p, font: Fonts.regular(13), color: Palette.body, width: w - 16))
                list.addArrangedSubview(row)
            }
            stack.addArrangedSubview(list)
        }

        // 选项
        if c.state == .ask, !c.options.isEmpty {
            let opts = NSStackView()
            opts.orientation = .vertical
            opts.alignment = .leading
            opts.spacing = 8
            opts.translatesAutoresizingMaskIntoConstraints = false
            for (i, o) in c.options.enumerated() {
                let b = PillButton("\(i + 1)  \(o)", style: .option)
                b.tag = i
                b.target = self
                b.action = #selector(pickOption(_:))
                b.widthAnchor.constraint(equalToConstant: w).isActive = true
                opts.addArrangedSubview(b)
            }
            stack.addArrangedSubview(opts)
        }

        // 输入框：提问时直接展开；完成时点「回一句…」再展开
        let reply = NSStackView()
        reply.orientation = .horizontal
        reply.alignment = .centerY
        reply.spacing = 6
        reply.translatesAutoresizingMaskIntoConstraints = false
        let field = ReplyField(placeholder: c.options.isEmpty ? "输入回答，回车发送" : "或者直接说…")
        field.target = self
        field.action = #selector(sendReply(_:))
        let send = PillButton("→", style: .send)
        send.target = self
        send.action = #selector(sendReply(_:))
        reply.addArrangedSubview(field)
        reply.addArrangedSubview(send)
        reply.widthAnchor.constraint(equalToConstant: w).isActive = true
        replyRow = reply
        replyField = field
        if c.state == .ask {
            stack.addArrangedSubview(reply)
        }

        // 动作
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        switch c.state {
        case .ask:
            let open = PillButton("去对话里细说", style: .ghost, compact: true)
            open.target = self; open.action = #selector(openTapped)
            actions.addArrangedSubview(open)
        case .error:
            let retry = PillButton("重试", style: .primary)
            retry.target = self; retry.action = #selector(retryTapped)
            let open = PillButton("打开对话", style: .ghost)
            open.target = self; open.action = #selector(openTapped)
            actions.addArrangedSubview(retry)
            actions.addArrangedSubview(open)
        default:
            let open = PillButton("打开对话", style: .primary)
            open.target = self; open.action = #selector(openTapped)
            let say = PillButton("回一句…", style: .ghost)
            say.target = self; say.action = #selector(toggleReply)
            actions.addArrangedSubview(open)
            actions.addArrangedSubview(say)
        }
        actions.addArrangedSubview(NSView())
        let ok = PillButton(c.state == .ask ? "稍后" : "知道了", style: .ghost, compact: true)
        ok.target = self; ok.action = #selector(dismissTapped)
        actions.addArrangedSubview(ok)
        actions.widthAnchor.constraint(equalToConstant: w).isActive = true
        stack.addArrangedSubview(actions)

        addSubview(stack)
    }

    private func layoutContent() {
        let body = bodyRect
        NSLayoutConstraint.deactivate(stack.constraints.filter { $0.firstItem === stack && $0.secondItem === self })
        stack.removeConstraints(stack.constraints.filter { $0.firstItem === stack && ($0.firstAttribute == .leading || $0.firstAttribute == .top) })
        let leading = body.minX + BubbleView.padX
        let topInset = BubbleView.padY
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            stack.widthAnchor.constraint(equalToConstant: BubbleView.contentWidth),
        ])
        // 高度由内容决定
        let fit = stack.fittingSize
        let h = fit.height + BubbleView.padY * 2 + BubbleView.shadow
        frame.size = NSSize(width: BubbleView.width, height: h)
        widthAnchor.constraint(equalToConstant: BubbleView.width).isActive = true
        heightAnchor.constraint(equalToConstant: h).isActive = true
    }

    /// 内容变化后重新量高度（展开输入框时）
    private func remeasure() {
        for c in constraints where c.firstItem === self && c.firstAttribute == .height { c.isActive = false }
        let fit = stack.fittingSize
        let h = fit.height + BubbleView.padY * 2 + BubbleView.shadow
        let oldH = frame.height
        heightAnchor.constraint(equalToConstant: h).isActive = true
        // 保持底边不动（坐标系 y 向上）
        frame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: h)
        _ = oldH
        needsDisplay = true
        superview?.needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // isFlipped 为 true，y 向下：阴影偏右下，即 +x +y
        let body = flippedBody
        let r = BubbleView.radius
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)
        let tailPath = NSBezierPath()
        let tailInner = NSBezierPath()
        let tailY = body.maxY - 24  // 距底 24pt 起
        if tailOnRight {
            tailPath.move(to: NSPoint(x: body.maxX - 2, y: tailY))
            tailPath.line(to: NSPoint(x: body.maxX + BubbleView.tail - 1, y: tailY - 6))
            tailPath.line(to: NSPoint(x: body.maxX - 2, y: tailY - 26))
            tailPath.close()
            tailInner.move(to: NSPoint(x: body.maxX - 4, y: tailY - 4))
            tailInner.line(to: NSPoint(x: body.maxX + BubbleView.tail - 9, y: tailY - 7))
            tailInner.line(to: NSPoint(x: body.maxX - 4, y: tailY - 22))
            tailInner.close()
        } else {
            tailPath.move(to: NSPoint(x: body.minX + 2, y: tailY))
            tailPath.line(to: NSPoint(x: body.minX - BubbleView.tail + 1, y: tailY - 6))
            tailPath.line(to: NSPoint(x: body.minX + 2, y: tailY - 26))
            tailPath.close()
            tailInner.move(to: NSPoint(x: body.minX + 4, y: tailY - 4))
            tailInner.line(to: NSPoint(x: body.minX - BubbleView.tail + 9, y: tailY - 7))
            tailInner.line(to: NSPoint(x: body.minX + 4, y: tailY - 22))
            tailInner.close()
        }

        // 硬阴影
        let shadowT = AffineTransform(translationByX: BubbleView.shadow, byY: BubbleView.shadow)
        let shadowBody = bodyPath.copy() as! NSBezierPath
        shadowBody.transform(using: shadowT)
        let shadowTail = tailPath.copy() as! NSBezierPath
        shadowTail.transform(using: shadowT)
        Palette.ink.setFill()
        shadowBody.fill()
        shadowTail.fill()
        // 墨边
        bodyPath.fill()
        tailPath.fill()
        // 白底
        Palette.paper.setFill()
        NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: r - 3, yRadius: r - 3).fill()
        tailInner.fill()
    }

    /// 翻转坐标系（y 向下）里的主体矩形
    private var flippedBody: NSRect {
        var r = bounds
        r.size.width -= BubbleView.tail + BubbleView.shadow
        r.origin.x = tailOnRight ? 0 : BubbleView.tail
        r.size.height -= BubbleView.shadow
        r.origin.y = 0
        return r
    }

    // MARK: 动作

    @objc private func pickOption(_ sender: PillButton) {
        guard sender.tag < conversation.options.count else { return }
        let text = conversation.options[sender.tag]
        picked = text
        onAnswer?(text)
    }

    @objc private func sendReply(_ sender: Any?) {
        guard let f = replyField else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        f.stringValue = ""
        onAnswer?(text)
    }

    @objc private func toggleReply() {
        guard let row = replyRow else { return }
        if row.superview == nil {
            // 插到动作行前面
            let idx = max(0, stack.arrangedSubviews.count - 1)
            stack.insertArrangedSubview(row, at: idx)
            remeasure()
            window?.makeFirstResponder(replyField)
        } else {
            window?.makeFirstResponder(replyField)
        }
    }

    @objc private func openTapped() { onOpen?() }
    @objc private func dismissTapped() { onDismiss?() }
    @objc private func retryTapped() { onAnswer?("请重试一次刚才那一步。") }

    /// 把焦点给输入框（提问气泡弹出时）
    func focusInput() {
        if replyField?.superview != nil { window?.makeFirstResponder(replyField) }
    }

    /// 显示「已回复」：把内容换成一行
    func showAnswered(_ text: String) {
        for v in stack.arrangedSubviews.dropFirst() {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let mark = NSTextField(labelWithString: "✓ 已回复「\(text)」")
        mark.font = Fonts.heavy(13)
        mark.textColor = Palette.dot(for: .done)
        mark.lineBreakMode = .byTruncatingTail
        mark.maximumNumberOfLines = 1
        row.addArrangedSubview(mark)
        row.addArrangedSubview(NSView())
        let open = PillButton("打开对话", style: .ghost, compact: true)
        open.target = self; open.action = #selector(openTapped)
        row.addArrangedSubview(open)
        row.widthAnchor.constraint(equalToConstant: BubbleView.contentWidth).isActive = true
        stack.addArrangedSubview(row)
        remeasure()
    }

    /// 弹出动画：从尾巴那一角弹开
    func animateIn() {
        guard let layer else { return }
        // 不改锚点（AppKit 布局时会据此挪动图层），只做缩放 + 淡入
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 0.6
        a.toValue = 1.0
        a.damping = 12
        a.stiffness = 220
        a.mass = 0.9
        a.initialVelocity = 4
        a.duration = a.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        layer.add(a, forKey: "pop")
        layer.add(fade, forKey: "fade")
    }
}

// MARK: - 轻提示（进行中的灰色小字）

final class WhisperView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.8).cgColor
        layer?.cornerRadius = 12
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = text
        label.font = Fonts.semibold(12)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setText(_ t: String) { label.stringValue = t }
}
