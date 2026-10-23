import Foundation

/// 大小姐的姿态（对应一段动画片段）
enum Pose: String, CaseIterable {
    case idle, walk, working, thinking, done, ask, error
}

/// 单个对话的状态。rawValue 越大，优先级越高：
/// 多个对话同时存在时，大小姐摆出优先级最高的那个姿态。
enum ConvState: Int, Comparable {
    case idle = 0
    case thinking
    case working
    case done
    case ask
    case error

    static func < (lhs: ConvState, rhs: ConvState) -> Bool { lhs.rawValue < rhs.rawValue }

    var pose: Pose {
        switch self {
        case .idle: return .idle
        case .thinking: return .thinking
        case .working: return .working
        case .done: return .done
        case .ask: return .ask
        case .error: return .error
        }
    }

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .thinking: return "思考中"
        case .working: return "工作中"
        case .done: return "完成"
        case .ask: return "等你回答"
        case .error: return "出错"
        }
    }

    /// 这个状态是否需要弹气泡
    var showsBubble: Bool {
        switch self {
        case .done, .ask, .error: return true
        default: return false
        }
    }

    init(kind: String?) {
        switch (kind ?? "").lowercased() {
        case "ask", "question": self = .ask
        case "error", "failed": self = .error
        case "working", "busy": self = .working
        case "thinking": self = .thinking
        case "idle": self = .idle
        default: self = .done
        }
    }
}

/// MCP 服务器通过 POST /notify 送来的事件
struct NotifyEvent: Decodable {
    var topic: String
    var headline: String?
    var summary: String?
    var points: [String]?
    var question: String?
    var options: [String]?
    var needsInput: Bool?
    var kind: String?

    enum CodingKeys: String, CodingKey {
        case topic, headline, summary, points, question, options, kind
        case needsInput = "needs_input"
    }

    /// 没给 kind 时，根据内容推断：有问题就是提问，否则是完成
    var resolvedState: ConvState {
        if let kind, !kind.isEmpty { return ConvState(kind: kind) }
        if let q = question, !q.isEmpty { return .ask }
        if let opts = options, !opts.isEmpty { return .ask }
        return .done
    }
}

/// POST /status：只改状态，不弹气泡（工作中 / 思考中 / 空闲）
struct StatusEvent: Decodable {
    var topic: String?
    var state: String
}

/// 一条 Claude 桌面版里的对话，以 topic（对话主题）为 key
final class Conversation {
    let id = UUID()
    var topic: String
    /// Claude 桌面版侧栏里的真实标题（从窗口标题读到的），跳转时优先用它
    var sidebarTitle: String?
    var state: ConvState = .idle

    /// 跳转/定位时依次尝试的标题
    var titlesForLookup: [String] { [sidebarTitle, topic].compactMap { $0 } }
    var headline: String = ""
    var points: [String] = []
    var question: String?
    var options: [String] = []
    var needsInput: Bool = false
    var updatedAt = Date()
    /// 气泡还没被看过 / 点掉
    var unread = false
    /// 最近一次 notify 的请求 id，用来把气泡里的回答回传给还挂着的 MCP 调用
    var requestId: String?
    /// 用户已在气泡里给出的回答
    var answer: String?

    init(topic: String) {
        self.topic = topic
    }

    /// 应用一条 notify 事件
    func apply(_ e: NotifyEvent, requestId: String) {
        state = e.resolvedState
        headline = (e.headline ?? e.summary ?? e.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        points = (e.points ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if points.count > 3 { points = Array(points.prefix(3)) }
        question = e.question?.trimmingCharacters(in: .whitespacesAndNewlines)
        options = (e.options ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if options.count > 4 { options = Array(options.prefix(4)) }
        needsInput = e.needsInput ?? (state == .ask && options.isEmpty)
        updatedAt = Date()
        unread = state.showsBubble
        self.requestId = requestId
        answer = nil
    }

    /// 面板 / 菜单里的一行摘要
    var snippet: String {
        switch state {
        case .working: return "正在写…"
        case .thinking: return "想一想…"
        case .idle: return headline.isEmpty ? "空闲" : headline
        default: return headline
        }
    }
}

extension Notification.Name {
    static let conversationsChanged = Notification.Name("ClaudeGirl.conversationsChanged")
    static let settingsChanged = Notification.Name("ClaudeGirl.settingsChanged")
}
