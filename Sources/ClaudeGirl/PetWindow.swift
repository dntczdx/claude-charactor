import AppKit

/// 无边框、透明、置顶的桌宠窗口。
/// 透明区域会被系统自动当作"不在窗口里"，鼠标直接穿透到下面的窗口。
final class PetWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    /// 气泡里有输入框，需要能成为 key window
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 系统默认不让窗口上边越过屏幕顶部；这个窗口大部分是透明的（上方留给气泡），
    /// 人物在底部，所以要放开，否则人物只能升到「屏幕顶 − 380pt」。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
