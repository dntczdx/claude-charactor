import AppKit
import QuartzCore

/// 大小姐所在的透明窗口：动画、气泡、轻提示、拖拽、空闲时溜达
final class PetWindowController: NSObject {
    static let spriteSize = NSSize(width: 260, height: 180)
    static let windowSize = NSSize(width: 860, height: 560)
    /// 人物在窗口里的位置（窗口两侧各留一块放气泡）
    static let spriteOrigin = NSPoint(x: 300, y: 0)

    let window: PetWindow
    private let content = NSView()
    private let spriteHost = SpriteHostView()
    private let player = SpritePlayer()
    private var bubble: BubbleView?
    private var whisper: WhisperView?
    private var popover: NSPopover?

    private(set) var pose: Pose = .idle
    private var clipGeneration = 0
    private var idleTimer: Timer?
    private var walkTimer: Timer?
    private var walkTarget: CGFloat = 0
    private var walking = false
    private var dragging = false
    private var dragStart: NSPoint = .zero
    private var dragOrigin: NSPoint = .zero
    private var dragMoved = false

    var onSpriteClick: (() -> Void)?

    override init() {
        window = PetWindow(contentRect: NSRect(origin: .zero, size: PetWindowController.windowSize))
        super.init()

        content.frame = NSRect(origin: .zero, size: PetWindowController.windowSize)
        content.wantsLayer = true
        window.contentView = content

        spriteHost.frame = NSRect(origin: PetWindowController.spriteOrigin, size: PetWindowController.spriteSize)
        spriteHost.wantsLayer = true
        spriteHost.layer?.masksToBounds = false
        player.layer.frame = spriteHost.bounds
        spriteHost.layer?.addSublayer(player.layer)
        spriteHost.onMouseDown = { [weak self] p in self?.beginDrag(at: p) }
        spriteHost.onMouseDragged = { [weak self] p in self?.drag(to: p) }
        spriteHost.onMouseUp = { [weak self] in self?.endDrag() }
        content.addSubview(spriteHost)

        placeAtHome()
        if Settings.shared.showPet { window.orderFrontRegardless() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: 位置

    private var screen: NSScreen {
        NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// 人物左下角在屏幕上的坐标
    private var spriteScreenOrigin: NSPoint {
        NSPoint(x: window.frame.minX + PetWindowController.spriteOrigin.x, y: window.frame.minY + PetWindowController.spriteOrigin.y)
    }

    private func setSpriteScreenOrigin(_ p: NSPoint) {
        window.setFrameOrigin(NSPoint(x: p.x - PetWindowController.spriteOrigin.x, y: p.y - PetWindowController.spriteOrigin.y))
    }

    private func placeAtHome() {
        let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        if let saved = Settings.shared.homeOrigin,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -200, dy: -200).contains(saved) }) {
            setSpriteScreenOrigin(saved)
        } else {
            setSpriteScreenOrigin(NSPoint(x: vis.maxX - PetWindowController.spriteSize.width - 24, y: vis.minY + 2))
        }
    }

    @objc private func screenChanged() {
        clampToScreen()
    }

    private func clampToScreen() {
        let vis = screen.visibleFrame
        var p = spriteScreenOrigin
        p.x = min(max(p.x, vis.minX - 40), vis.maxX - PetWindowController.spriteSize.width + 40)
        p.y = min(max(p.y, vis.minY - 10), vis.maxY - PetWindowController.spriteSize.height)
        setSpriteScreenOrigin(p)
    }

    /// 气泡放左边还是右边：左边放不下就放右边
    private var bubbleFitsOnLeft: Bool {
        spriteScreenOrigin.x + 60 - BubbleView.width >= screen.visibleFrame.minX
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
        playClip(for: walking ? .walk : pose)
    }

    private func playClip(for p: Pose, loop: Bool = true) {
        clipGeneration += 1
        let gen = clipGeneration
        guard let name = ClipLibrary.shared.clipName(for: p) else {
            player.stop()
            player.layer.contents = PetWindowController.placeholderImage()
            return
        }
        ClipLibrary.shared.load(name) { [weak self] clip in
            guard let self, gen == self.clipGeneration, let clip else { return }
            self.player.play(clip, loop: loop)
        }
    }

    /// 点一下的小反应（被戳害羞），播完回到当前姿态
    private func playReaction() {
        guard ClipLibrary.shared.available.contains("C06"), pose == .idle, !walking else { return }
        clipGeneration += 1
        let gen = clipGeneration
        ClipLibrary.shared.load("C06") { [weak self] clip in
            guard let self, gen == self.clipGeneration, let clip else { return }
            self.player.onFinished = { [weak self] in
                self?.player.onFinished = nil
                self?.playClip(for: .idle)
            }
            self.player.play(clip, loop: false)
        }
    }

    private static func placeholderImage() -> CGImage? {
        let size = NSSize(width: 520, height: 360)
        let img = NSImage(size: size, flipped: false) { rect in
            Palette.orange.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: 180, y: 20, width: 160, height: 220), xRadius: 50, yRadius: 50).fill()
            let text = "缺少动画素材\n请运行 scripts/prepare-assets.sh" as NSString
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            text.draw(in: NSRect(x: 60, y: 250, width: 400, height: 90), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .bold),
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
        let maxX = vis.maxX - PetWindowController.spriteSize.width - 8
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
        walkTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.walkStep() }
        RunLoop.main.add(t, forMode: .common)
        walkTimer = t
    }

    private func walkStep() {
        guard walking, walkingAllowed else { stopWalk(resumeIdle: true); return }
        let speed: CGFloat = 46.0 / 30.0  // 46pt/s
        var p = spriteScreenOrigin
        let dx = walkTarget - p.x
        if abs(dx) <= speed {
            p.x = walkTarget
            setSpriteScreenOrigin(p)
            stopWalk(resumeIdle: true)
            return
        }
        p.x += dx > 0 ? speed : -speed
        setSpriteScreenOrigin(p)
    }

    private func stopWalk(resumeIdle: Bool) {
        walkTimer?.invalidate()
        walkTimer = nil
        let wasWalking = walking
        walking = false
        player.flipped = false
        Settings.shared.homeOrigin = spriteScreenOrigin
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
            Settings.shared.homeOrigin = spriteScreenOrigin
            relayoutBubble()
            scheduleIdleBehaviour()
        } else {
            playReaction()
            onSpriteClick?()
        }
    }

    // MARK: 气泡

    func showBubble(for c: Conversation, onOpen: @escaping () -> Void, onAnswer: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        hideBubble()
        stopIdleBehaviour()
        let onLeft = bubbleFitsOnLeft
        let b = BubbleView(conversation: c, tailOnRight: onLeft)
        b.onOpen = onOpen
        b.onAnswer = onAnswer
        b.onDismiss = onDismiss
        content.addSubview(b)
        if onLeft {
            b.trailingAnchor.constraint(equalTo: spriteHost.leadingAnchor, constant: 60).isActive = true
        } else {
            b.leadingAnchor.constraint(equalTo: spriteHost.trailingAnchor, constant: -60).isActive = true
        }
        b.bottomAnchor.constraint(equalTo: spriteHost.bottomAnchor, constant: -100).isActive = true
        spriteHost.translatesAutoresizingMaskIntoConstraints = true
        content.layoutSubtreeIfNeeded()
        bubble = b
        b.animateIn()
        window.orderFrontRegardless()
        // 不主动抢焦点：用户点输入框时窗口自然成为 key window
        whisper?.isHidden = true
    }

    /// 回答后把气泡缩成一行
    func markBubbleAnswered(_ text: String) {
        bubble?.showAnswered(text)
    }

    func hideBubble() {
        bubble?.removeFromSuperview()
        bubble = nil
        whisper?.isHidden = false
        if pose == .idle { scheduleIdleBehaviour() }
    }

    private func relayoutBubble() {
        guard let b = bubble else { return }
        let c = b.conversation
        let onOpen = b.onOpen, onAnswer = b.onAnswer, onDismiss = b.onDismiss
        showBubble(for: c, onOpen: onOpen ?? {}, onAnswer: onAnswer ?? { _ in }, onDismiss: onDismiss ?? {})
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
        w.isHidden = bubble != nil
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
        p.show(relativeTo: spriteHost.bounds.insetBy(dx: 60, dy: 20), of: spriteHost, preferredEdge: .maxY)
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
