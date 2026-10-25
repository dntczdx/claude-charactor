import Foundation

/// 找到动画素材所在目录（<folder>/<代号>.webp 或 <folder>/<代号>/001.png …）
/// 查找顺序：环境变量 CLAUDEGIRL_ASSETS（指向 Assets 目录）→ app 包内 Resources/<folder> → 源码目录 Assets/<folder>（开发时 swift run）
enum AssetLocator {
    static func clipsDirectory(for agent: Agent) -> URL? {
        clipsDirectory(folder: agent.clipsFolder)
    }

    /// 兼容：大小姐
    static var clipsDirectory: URL? { clipsDirectory(for: .claude) }

    private static func clipsDirectory(folder: String) -> URL? {
        let fm = FileManager.default
        func existing(_ url: URL) -> URL? {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
        }

        if let env = ProcessInfo.processInfo.environment["CLAUDEGIRL_ASSETS"], !env.isEmpty {
            let base = URL(fileURLWithPath: env)
            if let u = existing(base.appendingPathComponent(folder)) { return u }
            if folder == "clips", let u = existing(base) { return u }
        }
        if let res = Bundle.main.resourceURL, let u = existing(res.appendingPathComponent(folder)) {
            return u
        }
        // 开发模式：从可执行文件所在目录往上找 Assets/<folder>
        var dir = Bundle.main.bundleURL
        for _ in 0..<7 {
            if let u = existing(dir.appendingPathComponent("Assets/\(folder)")) { return u }
            dir = dir.deletingLastPathComponent()
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        if let u = existing(cwd.appendingPathComponent("Assets/\(folder)")) { return u }
        return nil
    }
}
