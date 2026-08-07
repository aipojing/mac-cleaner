import Foundation
import Testing

/// 测试用临时主目录：在系统临时目录下创建一个隔离的 home 结构，
/// 测试结束后可整体清理，不触碰真实用户主目录。
struct TemporaryHome {
    let url: URL

    /// fixture 根路径（绝对路径字符串）。
    var path: String { url.path }

    /// 拼接相对子路径。
    func path(_ relative: String) -> String {
        (path as NSString).appendingPathComponent(relative)
    }

    /// 创建带预置文件的临时 home。
    /// files 的 key 是相对 home 的路径，value 是文件内容。
    static func fixture(files: [String: String] = [:]) throws -> TemporaryHome {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        for (relative, content) in files {
            let fileURL = base.appendingPathComponent(relative)
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return TemporaryHome(url: base)
    }

    /// 清理整个临时 home。
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
