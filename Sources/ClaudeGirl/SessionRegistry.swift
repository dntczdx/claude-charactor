import Foundation

/// Claude 桌面版「Code」页里的每条会话（Claude Code 进程）都会把自己登记在 ~/.claude/sessions/<pid>.json：
/// 里面有侧栏标题（name）、桌面版会话 ID（hostSessionId，形如 local_<uuid>）、是否正在生成（status）。
/// 读这个目录就能不靠猜标题，直接把 notify 绑到发它的那条会话，并拿到可用于 claude:// 深链接的 ID。
struct CodeSession {
    let pid: Int32
    let hostID: String          // local_<uuid>
    let name: String            // 侧栏标题
    let busy: Bool
    let statusUpdatedAt: Double // 毫秒时间戳
    let updatedAt: Double
    let transcriptID: String?   // Claude Code 自己的 session uuid（jsonl 文件名）
    let cwd: String?

    /// 跳转用的 ID：claude://claude.ai/epitaxy/<hostID>
    var chatID: String { "epitaxy/\(hostID)" }

    /// 这条会话的对话记录文件（~/.claude/projects/<cwd 编码>/<uuid>.jsonl）
    var transcriptURL: URL? {
        guard let transcriptID, let cwd else { return nil }
        let enc = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(enc)/\(transcriptID).jsonl")
    }
}

enum SessionRegistry {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    /// 当前仍活着的桌面版 Code 会话
    static func snapshot() -> [CodeSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [CodeSession] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let host = obj["hostSessionId"] as? String, !host.isEmpty else { continue }
            let pid = Int32((obj["pid"] as? Int) ?? Int(f.deletingPathExtension().lastPathComponent) ?? 0)
            guard pid > 0, kill(pid, 0) == 0 else { continue }   // 进程没了就当不存在
            let name = ((obj["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let status = ((obj["status"] as? String) ?? "").lowercased()
            out.append(CodeSession(
                pid: pid, hostID: host, name: name,
                busy: status == "busy" || status == "running" || status == "working",
                statusUpdatedAt: (obj["statusUpdatedAt"] as? Double) ?? 0,
                updatedAt: (obj["updatedAt"] as? Double) ?? 0,
                transcriptID: obj["sessionId"] as? String,
                cwd: obj["cwd"] as? String))
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 猜 notify 来自哪条会话：正在生成的那条；几条都在生成时，看谁的对话记录尾部出现了这次的 topic/headline；
    /// 再不行取状态最新的那条。
    static func caller(topic: String, headline: String, sessions: [CodeSession]? = nil) -> CodeSession? {
        let all = sessions ?? snapshot()
        let busy = all.filter(\.busy).sorted { $0.statusUpdatedAt > $1.statusUpdatedAt }
        if busy.isEmpty { return nil }
        if busy.count == 1 { return busy[0] }
        let needles = [headline, topic].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 4 }
        for s in busy {
            guard let url = s.transcriptURL, let tail = tail(of: url, bytes: 200_000) else { continue }
            if needles.contains(where: { tail.contains($0) || tail.contains(jsonEscaped($0)) }) { return s }
        }
        return busy[0]
    }

    private static func jsonEscaped(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let str = String(data: d, encoding: .utf8) else { return s }
        return String(str.dropFirst(2).dropLast(2))   // 去掉 ["…"]
    }

    private static func tail(of url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let d = try? h.readToEnd() else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}
