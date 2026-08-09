import Foundation
import Testing
@testable import MacCleanerCore

/// DuplicateFilesModule 执行层防护：不依赖 UI 层的 keptFiles 选择，
/// clean 自身强制“每组至少保留一份”与删除前内容漂移重验。
@Suite("Duplicate files clean guard")
struct DuplicateFilesCleanGuardTests {
    private func makeDuplicateFixture() throws -> (root: String, a: String, b: String) {
        let root = NSTemporaryDirectory().appending("dup-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let a = (root as NSString).appendingPathComponent("a.bin")
        let b = (root as NSString).appendingPathComponent("b.bin")
        let data = Data(repeating: 0x55, count: 8 * 1024)
        try data.write(to: URL(fileURLWithPath: a))
        try data.write(to: URL(fileURLWithPath: b))
        return (root, a, b)
    }

    /// 删除策略默认把允许根限定在真实 home；测试改用临时目录作为 home。
    private func makeModule(scanRoot: String) -> DuplicateFilesModule {
        DuplicateFilesModule(
            scanRoot: scanRoot,
            minSize: 1,
            deleter: Deleter(policyCatalog: DeletionPolicyCatalog(home: scanRoot))
        )
    }

    @Test("整组（所有副本）都在删除列表时整组拒绝删除")
    func rejectsDeletingEveryCopyOfGroup() async throws {
        let (root, a, b) = try makeDuplicateFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let module = makeModule(scanRoot: root)
        let result = try await module.scan(context: ScanContext())
        #expect(result.items.count == 2)

        // 绕过 UI 保留逻辑：把两份都交给 clean
        let report = try await module.clean(items: result.items, dryRun: false)

        #expect(report.successCount == 0)
        #expect(report.failedItems.count == 2)
        #expect(report.failedItems.allSatisfy { $0.reason == .unsafeTarget })
        #expect(FileManager.default.fileExists(atPath: a))
        #expect(FileManager.default.fileExists(atPath: b))
    }

    @Test("保留一份时允许删除其余副本")
    func allowsDeletionWhenOneCopyKept() async throws {
        let (root, a, _) = try makeDuplicateFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let module = makeModule(scanRoot: root)
        let result = try await module.scan(context: ScanContext())
        let toDelete = result.items.filter { $0.path == a }
        #expect(toDelete.count == 1)

        let report = try await module.clean(items: toDelete, dryRun: true)

        #expect(report.failedItems.isEmpty)
        #expect(report.successCount == 1)
        #expect(FileManager.default.fileExists(atPath: a))
    }

    @Test("扫描后内容漂移的文件拒绝删除")
    func rejectsContentDriftedFile() async throws {
        let (root, a, _) = try makeDuplicateFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let module = makeModule(scanRoot: root)
        let result = try await module.scan(context: ScanContext())
        let target = try #require(result.items.first { $0.path == a })

        // 扫描后改写 a：同样长度、不同内容 → sampled hash 漂移
        try Data(repeating: 0x99, count: 8 * 1024).write(to: URL(fileURLWithPath: a))

        let report = try await module.clean(items: [target], dryRun: false)

        #expect(report.successCount == 0)
        #expect(report.failedItems.count == 1)
        #expect(report.failedItems.first?.reason == .contentModified)
        #expect(FileManager.default.fileExists(atPath: a))
    }

    @Test("无扫描记录时按传入 items 即完整一组处理：同组 ≥2 条拒绝")
    func rejectsCompleteGroupWithoutScanRecord() async throws {
        let (root, a, b) = try makeDuplicateFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // 未执行 scan 的模块实例：没有组记录
        let module = makeModule(scanRoot: root)
        let items = [a, b].map {
            CleanableItem(path: $0, displayName: "x", size: 1, category: .duplicateFiles, subcategory: "some-hash")
        }

        let report = try await module.clean(items: items, dryRun: false)

        #expect(report.successCount == 0)
        #expect(report.failedItems.count == 2)
        #expect(FileManager.default.fileExists(atPath: a))
        #expect(FileManager.default.fileExists(atPath: b))
    }

    @Test("删除成功后组记录收缩：剩余最后一份再删被拒")
    func registryShrinksAfterSuccessfulDeletion() async throws {
        let (root, a, b) = try makeDuplicateFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let module = makeModule(scanRoot: root)
        let result = try await module.scan(context: ScanContext())
        let first = try #require(result.items.first { $0.path == a })
        let second = try #require(result.items.first { $0.path == b })

        // 真删除第一份（useTrash 移到废纸篓，路径即消失）
        let firstReport = try await module.clean(items: [first], dryRun: false)
        #expect(firstReport.successCount == 1)

        // 组内只剩 b：再删违反“至少保留一份”
        let secondReport = try await module.clean(items: [second], dryRun: false)
        #expect(secondReport.successCount == 0)
        #expect(secondReport.failedItems.first?.reason == .unsafeTarget)
        #expect(FileManager.default.fileExists(atPath: b))
    }
}
