import Foundation

/// 极简日志：追加到 ~/Library/Logs/ClaudeGirl.log，同时打到系统日志
enum Log {
    private static let queue = DispatchQueue(label: "claudegirl.log")
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ClaudeGirl.log")
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(fmt.string(from: Date())) \(message)\n"
        NSLog("[ClaudeGirl] %@", message)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
            // 太大了就截断
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
                try? Data().write(to: url)
            }
        }
    }
}
