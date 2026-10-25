import Foundation

/// 监听 Codex 的会话日志（$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl），
/// 从 task_started / task_complete / turn_aborted 事件得到每条线程的工作状态和最后一条回复。
/// Codex 桌面版和 CLI 共用这套日志，不需要模型配合。
final class CodexWatcher {
    struct ThreadInfo {
        let id: String
        var cwd: String
        var firstUserMessage: String?
        var lastAgentMessage: String?
        var file: URL

        /// 对话名：第一条用户消息的第一行（截短），没有就用目录名
        var title: String {
            if let m = firstUserMessage {
                let line = m.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
                if !line.isEmpty { return String(line.prefix(24)) }
            }
            let base = (cwd as NSString).lastPathComponent
            return base.isEmpty ? "Codex 线程" : base
        }
    }

    var onTurnStarted: ((ThreadInfo) -> Void)?
    var onTurnComplete: ((ThreadInfo, _ lastMessage: String?, _ error: String?) -> Void)?
    var onTurnAborted: ((ThreadInfo) -> Void)?

    private let queue = DispatchQueue(label: "claudegirl.codex", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    private var remainders: [String: Data] = [:]
    private var threads: [String: ThreadInfo] = [:]     // 按文件路径
    private let startDate = Date().addingTimeInterval(-5)
    private var warnedCompressed = false
    /// .jsonl.zst：记住上次解出来处理到了第几行、以及上次的文件大小
    private var zstLines: [String: Int] = [:]
    private var zstSizes: [String: UInt64] = [:]

    /// zstd 命令行（新版 Codex 会把会话日志压成 .jsonl.zst）
    private lazy var zstdPath: String? = {
        for p in ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd", "/opt/local/bin/zstd"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 2.0)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
        Log.info("Codex 日志监听启动：\(Settings.shared.codexHome.appendingPathComponent("sessions").path)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: 对外：最近活跃的线程

    /// 最近 `within` 秒内有写入的会话文件对应的线程（不解压，只看文件名和修改时间）。
    /// MCP 的 notify 不知道自己来自哪条线程时，用它兜底。
    func mostRecentThread(within: TimeInterval) -> (id: String, title: String)? {
        var best: (URL, Date)?
        let cutoff = Date().addingTimeInterval(-within)
        for dir in sessionDirs() {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for f in items where f.lastPathComponent.hasPrefix("rollout-") {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if m >= cutoff, m > (best?.1 ?? .distantPast) { best = (f, m) }
            }
        }
        guard let (file, _) = best else { return nil }
        let id = Self.idFromFilename(file)
        let title = queue.sync { threads[file.path]?.title } ?? (file.deletingPathExtension().lastPathComponent)
        return (id, title)
    }

    // MARK: 扫描

    private func sessionDirs() -> [URL] {
        let root = Settings.shared.codexHome.appendingPathComponent("sessions")
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        var dirs: [URL] = []
        for back in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            dirs.append(root.appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d)))
        }
        return dirs
    }

    private func scan() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for dir in sessionDirs() {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for f in items {
                let name = f.lastPathComponent
                guard name.hasPrefix("rollout-") else { continue }
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if name.hasSuffix(".jsonl.zst") {
                    if mtime < cutoff && zstLines[f.path] == nil { continue }
                    readCompressed(f)
                    continue
                }
                guard name.hasSuffix(".jsonl") else { continue }
                if mtime < cutoff && offsets[f.path] == nil { continue }
                readNewLines(of: f)
            }
        }
    }

    private func readNewLines(of file: URL) {
        let key = file.path
        guard let h = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? h.close() }
        let start = offsets[key] ?? 0
        let end = (try? h.seekToEnd()) ?? 0
        guard end > start else {
            if end < start { offsets[key] = 0; remainders[key] = nil }   // 文件被重写
            return
        }
        try? h.seek(toOffset: start)
        guard let data = try? h.read(upToCount: Int(end - start)), !data.isEmpty else { return }
        offsets[key] = end
        var buf = remainders[key] ?? Data()
        buf.append(data)
        var lines: [Data] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            lines.append(buf.subdata(in: buf.startIndex..<nl))
            buf = buf.subdata(in: (nl + 1)..<buf.endIndex)
        }
        remainders[key] = buf
        for l in lines where !l.isEmpty { handle(line: l, file: file) }
    }

    /// zstd 压缩的日志：大小变了就整个解一遍，只处理上次没处理过的行
    private func readCompressed(_ file: URL) {
        let key = file.path
        let size = (try? FileManager.default.attributesOfItem(atPath: key)[.size] as? UInt64) ?? 0
        if zstSizes[key] == size { return }
        zstSizes[key] = size
        guard let zstd = zstdPath else {
            if !warnedCompressed {
                warnedCompressed = true
                Log.info("Codex 日志是 zstd 压缩的（\(file.lastPathComponent)），但没找到 zstd 命令：brew install zstd 后重启桌宠即可读取")
            }
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: zstd)
        proc.arguments = ["-dcq", key]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard !data.isEmpty else { return }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // 最后一行可能还没写完（流式压缩）：没有换行结尾就先不处理
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        let done = zstLines[key] ?? 0
        guard lines.count > done else { return }
        for l in lines[done...] { handle(line: Data(l), file: file) }
        zstLines[key] = lines.count
    }

    // MARK: 解析

    private func handle(line: Data, file: URL) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let ts = (obj["timestamp"] as? String).flatMap { isoFrac.date(from: $0) ?? iso.date(from: $0) }
        let fresh = (ts ?? .distantPast) >= startDate
        let key = file.path

        switch type {
        case "session_meta":
            let id = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? Self.idFromFilename(file)
            var info = threads[key] ?? ThreadInfo(id: id, cwd: "", firstUserMessage: nil, lastAgentMessage: nil, file: file)
            if let cwd = payload["cwd"] as? String { info.cwd = cwd }
            threads[key] = info

        case "event_msg":
            var info = threads[key] ?? ThreadInfo(id: Self.idFromFilename(file), cwd: "", firstUserMessage: nil, lastAgentMessage: nil, file: file)
            let pt = (payload["type"] as? String) ?? ""
            switch pt {
            case "user_message":
                if info.firstUserMessage == nil, let m = payload["message"] as? String, !m.isEmpty { info.firstUserMessage = m }
            case "agent_message":
                if let m = payload["message"] as? String, !m.isEmpty { info.lastAgentMessage = m }
            case "item_completed":
                if let item = payload["item"] as? [String: Any] {
                    let it = ((item["type"] as? String) ?? "").lowercased()
                    let text = (item["text"] as? String) ?? (item["message"] as? String) ?? Self.joinContent(item["content"])
                    if it.contains("user"), info.firstUserMessage == nil, let text, !text.isEmpty { info.firstUserMessage = text }
                    if it.contains("agent") || it.contains("assistant"), let text, !text.isEmpty { info.lastAgentMessage = text }
                }
            case "task_started", "turn_started":
                threads[key] = info
                if fresh { emit { self.onTurnStarted?(info) } }
                return
            case "task_complete", "turn_complete":
                let last = (payload["last_agent_message"] as? String) ?? info.lastAgentMessage
                info.lastAgentMessage = last ?? info.lastAgentMessage
                let err = (payload["error"] as? [String: Any])?["message"] as? String
                threads[key] = info
                if fresh { emit { self.onTurnComplete?(info, last, err) } }
                return
            case "turn_aborted":
                threads[key] = info
                if fresh { emit { self.onTurnAborted?(info) } }
                return
            default:
                break
            }
            threads[key] = info

        case "response_item":
            // 新版日志里消息以 response_item 形式保存：{type:"message", role, content:[{type:"input_text"|"output_text", text}]}
            guard (payload["type"] as? String) == "message" else { return }
            var info = threads[key] ?? ThreadInfo(id: Self.idFromFilename(file), cwd: "", firstUserMessage: nil, lastAgentMessage: nil, file: file)
            let role = (payload["role"] as? String) ?? ""
            guard let text = Self.joinContent(payload["content"]), !text.isEmpty else { return }
            if role == "user" {
                // 跳过系统注入的环境说明之类
                if info.firstUserMessage == nil, !text.hasPrefix("<"), !text.hasPrefix("#") { info.firstUserMessage = text }
            } else if role == "assistant" {
                info.lastAgentMessage = text
            }
            threads[key] = info

        default:
            break
        }
    }

    private func emit(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private static func joinContent(_ v: Any?) -> String? {
        guard let arr = v as? [[String: Any]] else { return v as? String }
        let parts = arr.compactMap { $0["text"] as? String }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// rollout-2026-10-25T10-11-12-<uuid>.jsonl → uuid
    private static func idFromFilename(_ file: URL) -> String {
        var stem = file.deletingPathExtension().lastPathComponent
        if stem.hasSuffix(".jsonl") { stem = String(stem.dropLast(".jsonl".count)) }
        // 去掉 "rollout-" 和时间戳（19 个字符 + 1 个连字符）
        let afterPrefix = stem.hasPrefix("rollout-") ? String(stem.dropFirst("rollout-".count)) : stem
        if afterPrefix.count > 20 {
            let idx = afterPrefix.index(afterPrefix.startIndex, offsetBy: 20)
            let rest = String(afterPrefix[idx...])
            return rest.split(separator: "_").first.map(String.init) ?? rest
        }
        return afterPrefix
    }
}

/// 把 Codex 最后一条回复压成气泡文案：第一行当结论，后面的要点最多三条
enum CodexSummary {
    static func make(from message: String?) -> (headline: String, points: [String]) {
        guard let message else { return ("这条做完了", []) }
        let lines = message
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
            .map { line -> String in
                var l = line
                for prefix in ["- ", "* ", "• ", "## ", "# ", "### "] where l.hasPrefix(prefix) { l = String(l.dropFirst(prefix.count)) }
                if let r = l.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { l.removeSubrange(r) }
                return l.replacingOccurrences(of: "**", with: "")
            }
        guard let first = lines.first else { return ("这条做完了", []) }
        let headline = String(first.prefix(60))
        let points = lines.dropFirst().filter { $0.count >= 4 }.prefix(3).map { String($0.prefix(70)) }
        return (headline, Array(points))
    }
}
