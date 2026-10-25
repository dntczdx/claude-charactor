import AppKit

/// 桌宠盯着的工具：Claude 桌面版 / Codex 桌面版，各有一只小人
enum Agent: String, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "克劳德大小姐"
        case .codex: return "GPT 龙娘"
        }
    }
    var shortName: String {
        switch self {
        case .claude: return "大小姐"
        case .codex: return "龙娘"
        }
    }
    var appName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
    /// 动画素材子目录（Resources/<folder>）
    var clipsFolder: String {
        switch self {
        case .claude: return "clips"
        case .codex: return "clips-codex"
        }
    }
    var bundleIDs: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex: return ["com.openai.codex", "com.openai.Codex", "com.openai.codex.desktop"]
        }
    }
    /// 人物框尺寸（pt）
    var spriteSize: NSSize {
        switch self {
        case .claude: return NSSize(width: 215, height: 149)   // 大小姐头大身宽，缩到约 0.83 倍才和龙娘差不多高
        case .codex: return NSSize(width: 150, height: 200)
        }
    }
    /// 点一下的小反应片段
    var reactionClip: String {
        switch self {
        case .claude: return "C06"
        case .codex: return "shy"
        }
    }
    /// 按对话 ID 跳转的深链接
    func deepLink(chatID: String) -> URL? {
        switch self {
        case .claude: return URL(string: "claude://claude.ai\(chatID)")
        case .codex: return URL(string: "codex://threads/\(chatID)")
        }
    }

    init(name: String?) {
        self = Agent(rawValue: (name ?? "").lowercased()) ?? .claude
    }
}

/// 小人的姿态（对应一段动画片段）
enum Pose: String, CaseIterable {
    case idle, walk, working, thinking, done, ask, error
}

/// 单个对话的状态。rawValue 越大，优先级越高：
/// 多个对话同时存在时，小人摆出优先级最高的那个姿态。
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

/// MCP 服务器 / notify hook 通过 POST /notify 送来的事件
struct NotifyEvent: Decodable {
    var topic: String
    var headline: String?
    var summary: String?
    var points: [String]?
    var question: String?
    var options: [String]?
    var needsInput: Bool?
    var kind: String?
    /// "claude" / "codex"，缺省 claude
    var agent: String?
    /// 对话 / 线程 ID（Codex notify hook 能给 thread-id）
    var chatID: String?
    /// 诊断用：true 时不去猜它来自哪条对话（不会绑到正在生成的会话上）
    var test: Bool?

    enum CodingKeys: String, CodingKey {
        case topic, headline, summary, points, question, options, kind, agent, test
        case needsInput = "needs_input"
        case chatID = "chat_id"
    }

    init(topic: String, headline: String? = nil, summary: String? = nil, points: [String]? = nil,
         question: String? = nil, options: [String]? = nil, needsInput: Bool? = nil, kind: String? = nil,
         agent: String? = nil, chatID: String? = nil, test: Bool? = nil) {
        self.topic = topic
        self.headline = headline
        self.summary = summary
        self.points = points
        self.question = question
        self.options = options
        self.needsInput = needsInput
        self.kind = kind
        self.agent = agent
        self.chatID = chatID
        self.test = test
    }

    var resolvedAgent: Agent { Agent(name: agent) }

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
    var agent: String?
}

/// 一条对话（Claude 的 chat 或 Codex 的 thread），以 topic 为 key
final class Conversation {
    let id = UUID()
    let agent: Agent
    var topic: String
    /// 侧栏里的真实标题（Claude：从内容区标题读到的），跳转时优先用它
    var sidebarTitle: String?
    /// 对话的唯一 ID：Claude 是 URL 路径（/chat/<uuid>），Codex 是 thread uuid
    var chatID: String?
    var state: ConvState = .idle
    /// 诊断 / 演示通知建的对话：回答只记下来，绝不往任何真实对话里填
    var isTest = false
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

    init(topic: String, agent: Agent) {
        self.topic = topic
        self.agent = agent
    }

    /// 跳转/定位时依次尝试的标题
    var titlesForLookup: [String] { [sidebarTitle, topic].compactMap { $0 } }
    var chatRef: ChatRef { ChatRef(id: chatID, titles: titlesForLookup) }

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
        if let cid = e.chatID, !cid.isEmpty { chatID = cid }
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
