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

    /// 显示大小姐
    var showPet: Bool {
        get { bool("showPet", default: true) }
        set { set(newValue, "showPet") }
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
    /// 用 claude://claude.ai/chat/<uuid> 链接跳转（已验证桌面版支持，默认开）
    var useDeepLink: Bool {
        get { bool("useDeepLink", default: true) }
        set { set(newValue, "useDeepLink") }
    }
    /// 「标题 → 对话 UUID」登记表
    var chatRegistry: [String: String] {
        get { d.dictionary(forKey: "chatRegistry") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "chatRegistry") }
    }
    /// 本地事件端口（MCP 服务器往这里 POST）
    var port: UInt16 {
        let v = d.integer(forKey: "port")
        return v > 0 && v < 65536 ? UInt16(v) : 47333
    }
    /// 上次放下大小姐的位置（窗口左下角，屏幕坐标）
    var homeOrigin: CGPoint? {
        get {
            guard let arr = d.array(forKey: "homeOrigin") as? [Double], arr.count == 2 else { return nil }
            return CGPoint(x: arr[0], y: arr[1])
        }
        set {
            if let p = newValue { d.set([p.x, p.y], forKey: "homeOrigin") } else { d.removeObject(forKey: "homeOrigin") }
        }
    }
    /// 完成气泡停留秒数
    var doneBubbleSeconds: TimeInterval { 20 }
}
