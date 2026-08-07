import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

@MainActor
@Suite("Duplicate finder view model")
struct DuplicateFinderViewModelTests {
    /// 在临时目录构造一组内容相同的重复文件 + 一个不同文件
    private func makeFixture() throws -> (root: String, module: DuplicateFilesModule) {
        let root = NSTemporaryDirectory().appending("dup-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let content = Data(repeating: 0xAB, count: 2048)
        try content.write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent("a.bin")))
        try content.write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent("b.bin")))
        try Data(repeating: 0xCD, count: 2048)
            .write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent("c.bin")))
        let module = DuplicateFilesModule(scanRoot: root, minSize: 1)
        return (root, module)
    }

    @Test("扫描后组内默认不选中，没有任何待删项")
    func noDeletionPlanByDefault() async throws {
        let (root, module) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let viewModel = DuplicateFinderViewModel(module: module)

        await viewModel.performScanForTesting()

        #expect(viewModel.groups.count == 1)
        #expect(viewModel.keptFiles.isEmpty, "扫描后不得有默认保留选择")
        #expect(viewModel.itemsToDelete.isEmpty, "默认不得产生任何待删项")
    }

    @Test("显式选择保留文件后，其余项携带扫描身份进入待删列表")
    func explicitKeepProducesIdentifiedItems() async throws {
        let (root, module) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let viewModel = DuplicateFinderViewModel(module: module)
        await viewModel.performScanForTesting()

        let group = try #require(viewModel.groups.first)
        let keep = try #require(group.files.first)
        viewModel.keptFiles[group.id] = keep.id

        let items = viewModel.itemsToDelete
        #expect(items.count == 1)
        #expect(items.first?.path != keep.path)
        #expect(items.first?.fileIdentity != nil, "待删项必须携带身份，否则 guard 会全部拒绝")
    }

    @Test("清理失败时展示原因并保留失败项")
    func cleanFailureIsSurfaced() async throws {
        let (root, module) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let viewModel = DuplicateFinderViewModel(module: module)
        await viewModel.performScanForTesting()

        let group = try #require(viewModel.groups.first)
        let keep = try #require(group.files.first)
        let victim = try #require(group.files.first { $0.id != keep.id })
        viewModel.keptFiles[group.id] = keep.id

        // 扫描后替换目标文件，使 guard 因身份变化拒绝删除
        try FileManager.default.removeItem(atPath: victim.path)
        try Data(repeating: 0xEF, count: 4096).write(to: URL(fileURLWithPath: victim.path))

        await viewModel.cleanForTesting()

        #expect(viewModel.lastCleanError != nil, "清理失败必须展示原因")
        #expect(viewModel.groups.first?.files.contains { $0.path == victim.path } == true,
                "失败项应保留在列表中")
    }
}
