import AppKit
import ImageIO
import QuartzCore

/// 一段动画：一组 CGImage 帧
struct Clip {
    let name: String
    let frames: [CGImage]
    let fps: Double
}

/// 片段代号
enum ClipName {
    // 大小姐（与原项目 Claude-girl 一致）
    static let standby = "A01"       // 待机
    static let thinking = "A02"      // 托腮思考
    static let typing = "A03"        // 敲小键盘
    static let sorry = "A05"         // 冒汗道歉
    static let palms = "A06"         // 双手合十等你
    static let teaRest = "A07"       // 捧茶歇一会儿
    static let wave = "B04"          // 开心挥手
    static let tea = "C01"           // 喝茶
    static let book = "C02"          // 翻书
    static let correct = "D01"       // 你说得完全正确
    static let longThink = "D03"     // 超长思考

    /// 每个姿态可用的片段（按优先顺序；第一个存在的被使用，idle 随机）
    static func candidates(agent: Agent, pose: Pose) -> [String] {
        switch agent {
        case .claude:
            switch pose {
            case .idle: return [tea, teaRest, book, standby]
            case .walk: return [standby, tea]
            case .working: return [typing, standby]
            case .thinking: return [thinking, longThink, standby]
            case .done: return [correct, wave, standby]
            case .ask: return [palms, wave, standby]
            case .error: return [sorry, standby]
            }
        case .codex:
            // 龙娘（ai-pet-7in1 的片段，文件名见 scripts/prepare-codex-assets.sh）
            switch pose {
            case .idle: return ["idle", "look", "mutter", "tap", "shy"]
            case .walk: return ["walk", "run", "idle"]
            case .working: return ["working", "coding", "idle"]
            case .thinking: return ["thinking", "mutter", "idle"]
            case .done: return ["done", "jump", "wave", "idle"]
            case .ask: return ["waiting", "wave", "look", "idle"]
            case .error: return ["error", "idle"]
            }
        }
    }

    static func candidates(for pose: Pose) -> [String] { candidates(agent: .claude, pose: pose) }
}

/// 按需从磁盘加载帧，最多缓存 3 段
final class ClipLibrary {
    static let shared = ClipLibrary(agent: .claude)
    static let codex = ClipLibrary(agent: .codex)
    static func library(for agent: Agent) -> ClipLibrary { agent == .claude ? shared : codex }

    let agent: Agent
    let fps: Double = 12
    private(set) var available: Set<String> = []
    private var cache: [String: Clip] = [:]
    private var lru: [String] = []
    private let queue = DispatchQueue(label: "claudegirl.clips", qos: .userInitiated)

    init(agent: Agent) {
        self.agent = agent
        rescan()
    }

    private var directory: URL? { AssetLocator.clipsDirectory(for: agent) }

    /// 支持两种形态：<代号>/001.png… 帧目录，或 <代号>.webp / .gif / .png（动图单文件，ImageIO 解码）
    static let animatedExtensions: Set<String> = ["webp", "gif", "png", "apng", "heics"]

    func rescan() {
        available = []
        guard let dir = directory,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for u in items {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                available.insert(u.lastPathComponent)
            } else if Self.animatedExtensions.contains(u.pathExtension.lowercased()) {
                available.insert(u.deletingPathExtension().lastPathComponent)
            }
        }
    }

    /// 为姿态挑一个存在的片段；idle 在可用的几段里随机
    func clipName(for pose: Pose) -> String? {
        let list = ClipName.candidates(agent: agent, pose: pose).filter { available.contains($0) }
        guard !list.isEmpty else { return nil }
        if pose == .idle { return list.randomElement() }
        return list.first
    }

    /// 主线程调用；帧在后台解码，解码完回到主线程
    func load(_ name: String, completion: @escaping (Clip?) -> Void) {
        if let c = cache[name] {
            touch(name)
            completion(c)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let clip = self.decode(name)
            DispatchQueue.main.async {
                if let clip { self.store(clip) }
                completion(clip)
            }
        }
    }

    private func decode(_ name: String) -> Clip? {
        guard let root = directory else { return nil }
        // 先找单文件动图（仓库自带、透明通道有保证），解不出来再退回帧目录
        for ext in ["webp", "gif", "apng", "png", "heics"] {
            let f = root.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: f.path), let clip = decodeAnimated(f, name: name) {
                return clip
            }
        }
        let dir = root.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tif", "tiff"]
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var frames: [CGImage] = []
        frames.reserveCapacity(files.count)
        let opts = [kCGImageSourceShouldCache: true] as CFDictionary
        for f in files {
            guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, opts) else { continue }
            frames.append(img)
        }
        return frames.isEmpty ? nil : Clip(name: name, frames: frames, fps: fps)
    }

    /// 用 ImageIO 把动图（WebP / GIF / APNG）的每一帧解出来
    private func decodeAnimated(_ url: URL, name: String) -> Clip? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        let opts = [kCGImageSourceShouldCache: true] as CFDictionary
        for i in 0..<count {
            if let img = CGImageSourceCreateImageAtIndex(src, i, opts) { frames.append(img) }
        }
        guard !frames.isEmpty else { return nil }
        // 帧率：读第一帧的延时，读不到就按默认
        var clipFPS = fps
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let dicts: [[CFString: Any]?] = [
                props[kCGImagePropertyWebPDictionary] as? [CFString: Any],
                props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
            ]
            for d in dicts {
                guard let d else { continue }
                let delay = (d[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                    ?? (d[kCGImagePropertyWebPDelayTime] as? Double)
                    ?? (d[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (d[kCGImagePropertyGIFDelayTime] as? Double)
                    ?? (d[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                    ?? (d[kCGImagePropertyAPNGDelayTime] as? Double)
                if let delay, delay > 0.005 { clipFPS = min(max(1.0 / delay, 4), 30); break }
            }
        }
        return Clip(name: name, frames: frames, fps: clipFPS)
    }

    private func store(_ clip: Clip) {
        cache[clip.name] = clip
        touch(clip.name)
        while lru.count > 3, let old = lru.first {
            lru.removeFirst()
            cache[old] = nil
        }
    }

    private func touch(_ name: String) {
        lru.removeAll { $0 == name }
        lru.append(name)
    }
}

/// 把帧逐张塞进 CALayer 播放
final class SpritePlayer {
    let layer = CALayer()
    private(set) var clip: Clip?
    private var index = 0
    private var timer: Timer?
    private var loop = true
    var onFinished: (() -> Void)?

    /// 朝左走时水平翻转
    var flipped = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = flipped ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
            CATransaction.commit()
        }
    }

    init() {
        layer.contentsGravity = .resizeAspect
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        layer.isOpaque = false
        layer.actions = ["contents": NSNull(), "transform": NSNull(), "position": NSNull(), "bounds": NSNull()]
    }

    var isPlaying: Bool { timer != nil }

    func play(_ clip: Clip, loop: Bool) {
        self.clip = clip
        self.loop = loop
        index = 0
        setContents(clip.frames[0])
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / clip.fps, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let clip else { return }
        index += 1
        if index >= clip.frames.count {
            if loop {
                index = 0
            } else {
                index = clip.frames.count - 1
                stop()
                onFinished?()
                return
            }
        }
        setContents(clip.frames[index])
    }

    private func setContents(_ img: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = img
        CATransaction.commit()
    }
}
