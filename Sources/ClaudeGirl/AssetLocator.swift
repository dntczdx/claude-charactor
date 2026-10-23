import Foundation

/// 找到动画帧所在目录（clips/<片段代号>/001.png ...）
/// 查找顺序：环境变量 CLAUDEGIRL_ASSETS → app 包内 Resources/clips → 源码目录 Assets/clips（开发时 swift run）
enum AssetLocator {
    static var clipsDirectory: URL? {
        let fm = FileManager.default
        func existing(_ url: URL) -> URL? {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
        }

        if let env = ProcessInfo.processInfo.environment["CLAUDEGIRL_ASSETS"], !env.isEmpty,
           let u = existing(URL(fileURLWithPath: env)) {
            return u
        }
        if let res = Bundle.main.resourceURL, let u = existing(res.appendingPathComponent("clips")) {
            return u
        }
        // 开发模式：从可执行文件所在目录往上找 Assets/clips
        var dir = Bundle.main.bundleURL
        for _ in 0..<7 {
            if let u = existing(dir.appendingPathComponent("Assets/clips")) { return u }
            dir = dir.deletingLastPathComponent()
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        if let u = existing(cwd.appendingPathComponent("Assets/clips")) { return u }
        return nil
    }
}
