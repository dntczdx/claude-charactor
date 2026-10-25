import Foundation

/// 用户偏好（UserDefaults）
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private func bool(_ key: String, default def: Bool) -> Bool {
        d.object(forKey: key) as? Bool ?? def
    }
    private func set(_ value: Any?, _ key: String) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    /// 显示某只桌宠
    func showPet(_ agent: Agent) -> Bool {
        bool(agent == .claude ? "showPet" : "showPet.\(agent.rawValue)", default: true)
    }
    func setShowPet(_ agent: Agent, _ on: Bool) {
        set(on, agent == .claude ? "showPet" : "showPet.\(agent.rawValue)")
    }
    /// 兼容旧调用：大小姐
    var showPet: Bool {
        get { showPet(.claude) }
        set { setShowPet(.claude, newValue) }
    }
    /// 安静模式：只记录到面板，不弹气泡、不跳
    var quietMode: Bool {
        get { bool("quietMode", default: false) }
        set { set(newValue, "quietMode") }
    }
    /// 允许空闲时到处走（原项目没有走路动画，开了会一蹦一蹦地挪；默认关）
    var allowWalking: Bool {
        get { bool("allowWalking", default: false) }
        set { set(newValue, "allowWalking") }
    }
    /// 用深链接（claude:// / codex://）跳转对话
    var useDeepLink: Bool {
        get { bool("useDeepLink", default: true) }
        set { set(newValue, "useDeepLink") }
    }
    /// 「标题 → 对话 ID」登记表（Claude）
    var chatRegistry: [String: String] {
        get { d.dictionary(forKey: "chatRegistry") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "chatRegistry") }
    }
    /// 本地事件端口（MCP 服务器往这里 POST）
    var port: UInt16 {
        let v = d.integer(forKey: "port")
        return v > 0 && v < 65536 ? UInt16(v) : 47333
    }
    /// 上次放下某只桌宠的位置（人物框左下角，屏幕坐标）
    func homeOrigin(_ agent: Agent) -> CGPoint? {
        let key = agent == .claude ? "homeOrigin" : "homeOrigin.\(agent.rawValue)"
        guard let arr = d.array(forKey: key) as? [Double], arr.count == 2 else { return nil }
        return CGPoint(x: arr[0], y: arr[1])
    }
    func setHomeOrigin(_ agent: Agent, _ p: CGPoint?) {
        let key = agent == .claude ? "homeOrigin" : "homeOrigin.\(agent.rawValue)"
        if let p { d.set([p.x, p.y], forKey: key) } else { d.removeObject(forKey: key) }
    }
    /// 完成气泡停留秒数
    var doneBubbleSeconds: TimeInterval { 20 }

    /// Codex 的主目录（$CODEX_HOME 或 ~/.codex）
    var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    /// 是否监听 Codex 会话日志
    var watchCodex: Bool {
        get { bool("watchCodex", default: true) }
        set { set(newValue, "watchCodex") }
    }
}
