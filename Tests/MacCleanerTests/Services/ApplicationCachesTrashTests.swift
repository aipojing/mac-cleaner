import Foundation
import Testing
@testable import MacCleanerCore

/// ApplicationCachesModule 的清理必须走废纸篓：应用缓存（含第三方通讯
/// 应用）可能含用户数据，永久删除不可恢复。
///
/// 该模块的 clean 内部使用生产 DeletionPolicyCatalog（真实 home），
/// 因此本测试在真实 ~/Library/Caches 下创建一个唯一命名的临时目录，
/// 清理后验证它进入了废纸篓而非被永久删除；测试结束清理废纸篓中
/// 由本测试创建的条目。
@Suite("ApplicationCaches 删除策略")
struct ApplicationCachesTrashTests {
    @Test("应用缓存清理使用废纸篓（可恢复），不做永久删除")
    func cleanUsesTrash() async throws {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let dirName = "devclean-trash-policy-test-\(UUID().uuidString)"
        let dir = "\(home)/Library/Caches/\(dirName)"
        let trashEntry = "\(home)/.Trash/\(dirName)"

        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let payload = (dir as NSString).appendingPathComponent("payload.bin")
        fm.createFile(atPath: payload, contents: Data(count: 256))

        // 无论断言成败，本测试创建的目录都不能残留：
        // 还在 Caches 里就直接删，进了废纸篓就从废纸篓删（仅限本测试创建的唯一名）。
        defer {
            if fm.fileExists(atPath: dir) { try? fm.removeItem(atPath: dir) }
            if fm.fileExists(atPath: trashEntry) { try? fm.removeItem(atPath: trashEntry) }
        }

        let provider = POSIXFileIdentityProvider()
        let item = CleanableItem(
            path: dir,
            displayName: "Trash Policy Test",
            size: 256,
            category: .applicationCaches,
            fileIdentity: try provider.identity(at: dir)
        )

        let report = try await ApplicationCachesModule().clean(items: [item], dryRun: false)

        #expect(report.failureCount == 0)
        #expect(report.successCount == 1)
        #expect(report.deletedItems.first?.movedToTrash == true, "应用缓存必须移到废纸篓而非永久删除")
        #expect(!fm.fileExists(atPath: dir))
    }
}
