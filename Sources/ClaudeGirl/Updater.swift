import AppKit

/// 自动更新：定时看 GitHub 上的分支有没有新提交，有就 git pull 并重新打包安装（scripts/build-app.sh 会杀掉旧进程、装到 /Applications、再启动）。
/// 仓库路径由 build-app.sh 写进 Info.plist（ClaudeGirlRepoPath）。
final class Updater {
    static let shared = Updater()

    private var timer: Timer?
    private var running = false
    private(set) var lastCheck: Date?
    private(set) var lastResult = "还没检查过"
    private let buildLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeGirl-build.log")

    var repoPath: String? {
        if let p = Bundle.main.object(forInfoDictionaryKey: "ClaudeGirlRepoPath") as? String, FileManager.default.fileExists(atPath: p + "/scripts/build-app.sh") { return p }
        if let p = Settings.shared.repoPath, FileManager.default.fileExists(atPath: p + "/scripts/build-app.sh") { return p }
        return nil
    }

    var buildLogURL: URL { buildLog }

    func start() {
        guard repoPath != nil else {
            Log.info("自动更新：Info.plist 里没有仓库路径（用 scripts/build-app.sh 打包的才有），跳过")
            return
        }
        schedule()
        // 启动 40 秒后先检查一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in self?.checkAndUpdate(force: false) }
    }

    func schedule() {
        timer?.invalidate()
        timer = nil
        guard Settings.shared.autoUpdate else { return }
        let t = Timer(timeInterval: 10 * 60, repeats: true) { [weak self] _ in self?.checkAndUpdate(force: false) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// force=true：不管有没有新提交都重新编译一遍
    func checkAndUpdate(force: Bool, completion: ((String) -> Void)? = nil) {
        guard let repo = repoPath else { completion?("没有仓库路径"); return }
        guard !running else { completion?("正在更新中"); return }
        running = true
        lastCheck = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let check = Self.run(zsh: "cd \(Self.q(repo)) && git fetch -q origin && echo LOCAL=$(git rev-parse HEAD) && echo REMOTE=$(git rev-parse @{u} 2>/dev/null || echo none) && git status --porcelain | head -5")
            let local = Self.grab("LOCAL=", in: check.out)
            let remote = Self.grab("REMOTE=", in: check.out)
            let dirty = check.out.split(separator: "\n").contains { !$0.hasPrefix("LOCAL=") && !$0.hasPrefix("REMOTE=") && !$0.isEmpty }
            var message: String
            if check.status != 0 {
                message = "git fetch 失败：\(check.err.prefix(120))"
            } else if remote == "none" || remote.isEmpty {
                message = "分支没有上游，跳过"
            } else if local == remote && !force {
                message = "已是最新（\(local.prefix(7))）"
            } else if dirty && !force {
                message = "仓库有未提交改动，不自动 pull（\(remote.prefix(7)) 待更新）"
            } else {
                message = force ? "重新编译中…" : "发现新提交 \(remote.prefix(7))，正在 pull 并重新编译…"
                Log.info("自动更新：\(message)")
                DispatchQueue.main.async { NotificationCenter.default.post(name: .updaterBuilding, object: message) }
                // 放到后台独立进程：build-app.sh 会 pkill 掉本 app，所以不能等它
                let cmd = "cd \(Self.q(repo)) && { echo \"==== $(date) 自动更新 ====\"; git pull --ff-only; INSTALL=1 scripts/build-app.sh; echo \"==== exit $? ====\"; } >> \(Self.q(self.buildLog.path)) 2>&1"
                _ = Self.run(zsh: "nohup /bin/zsh -lc \(Self.q(cmd)) >/dev/null 2>&1 &")
            }
            DispatchQueue.main.async {
                self.running = false
                self.lastResult = message
                Log.info("自动更新：\(message)")
                completion?(message)
            }
        }
    }

    // MARK: 工具

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func grab(_ prefix: String, in text: String) -> String {
        for line in text.split(separator: "\n") where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// 用登录 shell 跑命令，这样 PATH 里有 brew 的 git / node / swift
    private static func run(zsh command: String) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return (-1, "", String(describing: error)) }
        let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, out, err)
    }
}

extension Notification.Name {
    static let updaterBuilding = Notification.Name("ClaudeGirl.updaterBuilding")
}
