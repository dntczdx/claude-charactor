import AppKit
import QuartzCore

/// 大小姐所在的透明窗口：动画、气泡、轻提示、拖拽、空闲时溜达
final class PetWindowController: NSObject {
    let agent: Agent
    let spriteSize: NSSize
    let windowSize: NSSize   // 高一点，装得下三条叠放的气泡
    /// 人物在窗口里的位置（窗口两侧各留一块放气泡）
    let spriteOrigin: NSPoint
    private let library: ClipLibrary

    let window: PetWindow
    private let content = NSView()
    private let spriteHost = SpriteHostView()
    private let player = SpritePlayer()
    // bubble: 见下方「气泡」一节（最下面那条）
    private var whisper: WhisperView?
    private var popover: NSPopover?

    private(set) var pose: Pose = .idle
    private var clipGeneration = 0
    private var idleTimer: Timer?
    private var walkTimer: Timer?
    private var walkTarget: CGFloat = 0
    private var walking = false
    // 蹦跳式移动：每一跳 0.5s、前进 26pt、起落 14pt，跳之间停 0.18s
    private var hopStartTime: TimeInterval = 0
    private var hopFromX: CGFloat = 0
    private var hopBaseY: CGFloat = 0
    private static let hopDuration: TimeInterval = 0.5
    private static let hopGap: TimeInterval = 0.18
    private static let hopDistance: CGFloat = 26
    private static let hopHeight: CGFloat = 14
    private var dragging = false
    private var dragStart: NSPoint = .zero
    private var dragOrigin: NSPoint = .zero
    private var dragMoved = false

    var onSpriteClick: (() -> Void)?

    init(agent: Agent) {
        self.agent = agent
        library = ClipLibrary.library(for: agent)
        spriteSize = agent.spriteSize
        let side = BubbleView.width + 40
        windowSize = NSSize(width: spriteSize.width + side * 2, height: max(720, spriteSize.height + 540))
        spriteOrigin = NSPoint(x: side, y: 0)
        window = PetWindow(contentRect: NSRect(origin: .zero, size: windowSize))
        super.init()

        content.frame = NSRect(origin: .zero, size: windowSize)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.layer?.isOpaque = false
        window.contentView = content
        // 再设一遍：contentView 换掉后保证窗口仍是透明的
        window.isOpaque = false
        window.backgroundColor = .clear

        spriteHost.frame = NSRect(origin: spriteOrigin, size: spriteSize)
        spriteHost.wantsLayer = true
        spriteHost.layer?.backgroundColor = NSColor.clear.cgColor
        spriteHost.layer?.isOpaque = false
        spriteHost.layer?.masksToBounds = false
        player.layer.frame = spriteHost.bounds
        spriteHost.layer?.addSublayer(player.layer)
        spriteHost.onMouseDown = { [weak self] p in self?.beginDrag(at: p) }
        spriteHost.onMouseDragged = { [weak self] p in self?.drag(to: p) }
        spriteHost.onMouseUp = { [weak self] in self?.endDrag() }
        content.addSubview(spriteHost)

        placeAtHome()
        if Settings.shared.showPet(agent) { window.orderFrontRegardless() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: 位置

    private var screen: NSScreen {
        NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// 人物左下角在屏幕上的坐标
    private var spriteScreenOrigin: NSPoint {
        NSPoint(x: window.frame.minX + spriteOrigin.x, y: window.frame.minY + spriteOrigin.y)
    }

    private func setSpriteScreenOrigin(_ p: NSPoint) {
        window.setFrameOrigin(NSPoint(x: p.x - spriteOrigin.x, y: p.y - spriteOrigin.y))
    }

    private func placeAtHome() {
        let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        if let saved = Settings.shared.homeOrigin(agent),
           NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -300, dy: -300).contains(saved) }) {
            setSpriteScreenOrigin(saved)
            return
        }
        // 默认：大小姐在右下角，龙娘站在她左边
        var x = vis.maxX - Agent.claude.spriteSize.width - 24
        if agent != .claude { x -= spriteSize.width + 40 }
        setSpriteScreenOrigin(NSPoint(x: x, y: vis.minY + 2))
    }

    @objc private func screenChanged() {
        clampToScreen()
    }

    /// 只保证别完全丢到屏幕外：人物框至少留 80pt 在屏幕里，其余随便放
    private func clampToScreen() {
        let full = screen.frame
        let keep: CGFloat = 80
        var p = spriteScreenOrigin
        p.x = min(max(p.x, full.minX - spriteSize.width + keep), full.maxX - keep)
        p.y = min(max(p.y, full.minY - spriteSize.height + keep), full.maxY - keep)
        setSpriteScreenOrigin(p)
    }

    /// 气泡尾巴伸进人物框多少 / 气泡底边离人物框底多高（按人物框尺寸等比）
    private var bubbleOverlap: CGFloat { (spriteSize.width * 0.23).rounded() }
    private var bubbleLift: CGFloat { (spriteSize.height * 0.55).rounded() }

    /// 气泡放左边还是右边：左边放不下就放右边
    private var bubbleFitsOnLeft: Bool {
        spriteScreenOrigin.x + bubbleOverlap - BubbleView.width >= screen.visibleFrame.minX
    }

    func setVisible(_ visible: Bool) {
        if visible { window.orderFrontRegardless() } else { window.orderOut(nil) }
    }

    // MARK: 姿态与动画

    func setPose(_ newPose: Pose) {
        let changed = newPose != pose
        pose = newPose
        if newPose != .idle {
            stopIdleBehaviour()
            if changed || player.clip == nil { playClip(for: newPose) }
        } else {
            if changed || player.clip == nil { playClip(for: .idle) }
            scheduleIdleBehaviour()
        }
    }

    /// 素材重新载入后刷新
    func refreshClip() {
        library.rescan()
        playClip(for: walking ? .walk : pose)
    }

    private func playClip(for p: Pose, loop: Bool = true) {
        clipGeneration += 1
        let gen = clipGeneration
        guard let name = library.clipName(for: p) else {
            player.stop()
            player.layer.contents = placeholderImage()
            return
        }
        library.load(name) { [weak self] clip in
            guard let self, gen == self.clipGeneration, let clip else { return }
            self.player.play(clip, loop: loop)
        }
    }

    /// 点一下的小反应（被戳害羞），播完回到当前姿态
    private func playReaction() {
        let name = agent.reactionClip
        guard library.available.contains(name), pose == .idle, !walking else { return }
        clipGeneration += 1
        let gen = clipGeneration
        library.load(name) { [weak self] clip in
            guard let self, gen == self.clipGeneration, let clip else { return }
            self.player.onFinished = { [weak self] in
                self?.player.onFinished = nil
                self?.playClip(for: .idle)
            }
            self.player.play(clip, loop: false)
        }
    }

    private func placeholderImage() -> CGImage? {
        let size = NSSize(width: spriteSize.width * 2, height: spriteSize.height * 2)
        let name = agent.shortName
        let img = NSImage(size: size, flipped: false) { rect in
            Palette.orange.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 80, y: 20, width: 160, height: rect.height * 0.5), xRadius: 50, yRadius: 50).fill()
            let text = "缺少\(name)动画素材\n请运行 scripts/prepare-assets.sh" as NSString
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            text.draw(in: NSRect(x: 10, y: rect.height * 0.5 + 30, width: rect.width - 20, height: 90), withAttributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .bold),
                .foregroundColor: Palette.ink,
                .paragraphStyle: para,
            ])
            return true
        }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: 空闲行为：喝茶一会儿，走一段

    private var walkingAllowed: Bool {
        Settings.shared.allowWalking && pose == .idle && bubble == nil && !dragging && popover?.isShown != true
    }

    func walkingSettingChanged() {
        if Settings.shared.allowWalking { scheduleIdleBehaviour() } else { stopIdleBehaviour() }
    }

    private func scheduleIdleBehaviour() {
        guard !walking else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        guard walkingAllowed else { return }
        let delay = TimeInterval.random(in: 8...20)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.startWalk() }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func stopIdleBehaviour() {
        idleTimer?.invalidate()
        idleTimer = nil
        if walking { stopWalk(resumeIdle: false) }
    }

    private func startWalk() {
        guard walkingAllowed else { return }
        let vis = screen.visibleFrame
        let minX = vis.minX + 8
        let maxX = vis.maxX - spriteSize.width - 8
        guard maxX - minX > 200 else { scheduleIdleBehaviour(); return }
        let cur = spriteScreenOrigin.x
        var target = CGFloat.random(in: minX...maxX)
        var tries = 0
        while abs(target - cur) < 140 && tries < 8 {
            target = CGFloat.random(in: minX...maxX)
            tries += 1
        }
        walkTarget = target
        walking = true
        player.flipped = target < cur
        playClip(for: .walk)
        hopStartTime = CACurrentMediaTime()
        hopFromX = cur
        hopBaseY = spriteScreenOrigin.y
        walkTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.walkStep() }
        RunLoop.main.add(t, forMode: .common)
        walkTimer = t
    }

    /// 一跳一跳地挪：跳的时候 x 匀速前进、y 走一段正弦弧；落地停一下再跳
    private func walkStep() {
        guard walking, walkingAllowed else { stopWalk(resumeIdle: true); return }
        let now = CACurrentMediaTime()
        let elapsed = now - hopStartTime
        let dir: CGFloat = walkTarget >= hopFromX ? 1 : -1
        let remaining = abs(walkTarget - hopFromX)
        let dist = min(PetWindowController.hopDistance, remaining)

        if elapsed >= PetWindowController.hopDuration {
            // 落地
            let landedX = hopFromX + dir * dist
            setSpriteScreenOrigin(NSPoint(x: landedX, y: hopBaseY))
            if abs(walkTarget - landedX) < 1 {
                stopWalk(resumeIdle: true)
                return
            }
            if elapsed >= PetWindowController.hopDuration + PetWindowController.hopGap {
                hopFromX = landedX
                hopStartTime = now
            }
            return
        }
        let t = CGFloat(elapsed / PetWindowController.hopDuration)
        let x = hopFromX + dir * dist * t
        let y = hopBaseY + PetWindowController.hopHeight * sin(t * .pi)
        setSpriteScreenOrigin(NSPoint(x: x, y: y))
    }

    private func stopWalk(resumeIdle: Bool) {
        walkTimer?.invalidate()
        walkTimer = nil
        let wasWalking = walking
        walking = false
        player.flipped = false
        if wasWalking { setSpriteScreenOrigin(NSPoint(x: spriteScreenOrigin.x, y: hopBaseY)) }
        Settings.shared.setHomeOrigin(agent, spriteScreenOrigin)
        if resumeIdle {
            if wasWalking { playClip(for: .idle) }
            scheduleIdleBehaviour()
        }
    }

    // MARK: 拖拽 / 点击

    private func beginDrag(at p: NSPoint) {
        dragging = true
        dragMoved = false
        dragStart = NSEvent.mouseLocation
        dragOrigin = window.frame.origin
        stopIdleBehaviour()
        if walking { stopWalk(resumeIdle: false) }
    }

    private func drag(to p: NSPoint) {
        guard dragging else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStart.x
        let dy = now.y - dragStart.y
        if abs(dx) > 3 || abs(dy) > 3 { dragMoved = true }
        window.setFrameOrigin(NSPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy))
    }

    private func endDrag() {
        guard dragging else { return }
        dragging = false
        if dragMoved {
            clampToScreen()
            Settings.shared.setHomeOrigin(agent, spriteScreenOrigin)
            relayoutBubble()
            scheduleIdleBehaviour()
        } else {
            playReaction()
            onSpriteClick?()
        }
    }

    // MARK: 气泡（最多叠放 3 条：最下面一条展开，上面的折叠成一行）

    struct BubbleSpec {
        let conversation: Conversation
        let expanded: Bool
        let onOpen: () -> Void
        let onAnswer: (String) -> Void
        let onDismiss: () -> Void
        let onExpand: () -> Void
    }
    private var bubbleSpecs: [BubbleSpec] = []
    private var bubblesOnLeft = true

    /// 最下面那条（展开的）
    private var bubble: BubbleView? { bubbles.first }
    private var bubbles: [BubbleView] = []

    /// 用户正在跟某条气泡打交道（悬停 / 输入中）
    var bubbleBusy: Bool { bubbles.contains { $0.isBusyWithUser } }
    var bubbleTopic: String? { bubble?.conversation.topic }
    var visibleBubbleCount: Int { bubbles.count }
    /// 诊断：每条气泡在窗口里的位置（x, y, w, h，y 向上），从下往上
    var bubbleFrames: [[Int]] { bubbles.map { [Int($0.frame.minX), Int($0.frame.minY), Int($0.frame.width), Int($0.frame.height)] } }

    /// 重建整叠气泡。specs[0] 在最下面、紧挨着大小姐
    func setBubbles(_ specs: [BubbleSpec]) {
        bubbleSpecs = specs
        for b in bubbles { b.removeFromSuperview() }
        bubbles = []
        guard !specs.isEmpty else {
            if pose == .idle { scheduleIdleBehaviour() }
            return
        }
        stopIdleBehaviour()
        bubblesOnLeft = bubbleFitsOnLeft
        var previous: BubbleView?
        for (i, spec) in specs.enumerated() {
            let b = BubbleView(conversation: spec.conversation, tailOnRight: bubblesOnLeft, compact: !spec.expanded)
            b.onOpen = spec.onOpen
            b.onAnswer = spec.onAnswer
            b.onDismiss = spec.onDismiss
            b.onExpand = spec.onExpand
            content.addSubview(b)
            if bubblesOnLeft {
                b.trailingAnchor.constraint(equalTo: spriteHost.leadingAnchor, constant: bubbleOverlap).isActive = true
            } else {
                b.leadingAnchor.constraint(equalTo: spriteHost.trailingAnchor, constant: -bubbleOverlap).isActive = true
            }
            if let prev = previous {
                b.bottomAnchor.constraint(equalTo: prev.topAnchor, constant: -8).isActive = true
            } else {
                b.bottomAnchor.constraint(equalTo: spriteHost.bottomAnchor, constant: -bubbleLift).isActive = true
            }
            if i > 0 { b.alphaValue = 0.96 }
            bubbles.append(b)
            previous = b
        }
        spriteHost.translatesAutoresizingMaskIntoConstraints = true
        content.layoutSubtreeIfNeeded()
        bubble?.animateIn()
        window.orderFrontRegardless()
        // 不主动抢焦点：用户点输入框时窗口自然成为 key window
    }

    /// 单条（兼容旧调用）
    func showBubble(for c: Conversation, onOpen: @escaping () -> Void, onAnswer: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        setBubbles([BubbleSpec(conversation: c, expanded: true, onOpen: onOpen, onAnswer: onAnswer, onDismiss: onDismiss, onExpand: {})])
    }

    /// 回答后把那条气泡缩成一行
    func markBubbleAnswered(_ c: Conversation, text: String) {
        bubbles.first { $0.conversation === c }?.showAnswered(text)
    }

    func hideBubble() {
        setBubbles([])
    }

    /// 拖到另一侧放不下时才重建（重建会丢掉正在输入的文字）
    private func relayoutBubble() {
        guard !bubbles.isEmpty, bubbleFitsOnLeft != bubblesOnLeft else { return }
        setBubbles(bubbleSpecs)
    }

    // MARK: 轻提示

    func showWhisper(_ text: String?) {
        guard let text, !text.isEmpty else {
            whisper?.removeFromSuperview()
            whisper = nil
            return
        }
        if let w = whisper {
            w.setText(text)
            return
        }
        let w = WhisperView(text: text)
        content.addSubview(w)
        NSLayoutConstraint.activate([
            w.centerXAnchor.constraint(equalTo: spriteHost.centerXAnchor),
            w.bottomAnchor.constraint(equalTo: spriteHost.topAnchor, constant: -4),
        ])
        whisper = w
    }

    // MARK: 面板

    func togglePanel(_ vc: NSViewController) {
        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentViewController = vc
        p.contentSize = vc.preferredContentSize
        popover = p
        window.makeKey()
        p.show(relativeTo: spriteHost.bounds.insetBy(dx: spriteSize.width * 0.2, dy: 20), of: spriteHost, preferredEdge: .maxY)
    }

    func closePanel() {
        popover?.performClose(nil)
    }
}

/// 放动画的视图，负责把鼠标事件交给控制器
final class SpriteHostView: NSView {
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onMouseDown?(event.locationInWindow) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event.locationInWindow) }
    override func mouseUp(with event: NSEvent) { onMouseUp?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
