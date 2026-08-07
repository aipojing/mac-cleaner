import Foundation
import Testing
@testable import MacCleanerCore

@Suite("Scan result filter")
struct ScanResultFilterTests {
    @Test("过滤器保持模块信息并删除排除项")
    func filtersExcludedItems() async {
        let manager = InMemoryExclusionManager(excludedPaths: ["/tmp/cache/keep"])
        let filter = ScanResultFilter(exclusionManager: manager)
        let result = ScanResult(
            module: .applicationCaches,
            items: [
                CleanableItem(
                    path: "/tmp/cache/delete",
                    displayName: "delete",
                    size: 10,
                    category: .applicationCaches
                ),
                CleanableItem(
                    path: "/tmp/cache/keep",
                    displayName: "keep",
                    size: 20,
                    category: .applicationCaches
                ),
            ],
            scanDuration: 0
        )

        let filtered = await filter.apply(to: result)

        #expect(filtered.module == result.module)
        #expect(filtered.items.map(\.path) == ["/tmp/cache/delete"])
    }

    @Test("无规则时结果原样通过")
    func passesThroughWithoutRules() async {
        let manager = InMemoryExclusionManager()
        let filter = ScanResultFilter(exclusionManager: manager)
        let result = ScanResult(
            module: .systemLogs,
            items: [
                CleanableItem(path: "/tmp/a", displayName: "a", size: 1, category: .systemLogs),
                CleanableItem(path: "/tmp/b", displayName: "b", size: 2, category: .systemLogs),
            ],
            scanDuration: 1.5
        )

        let filtered = await filter.apply(to: result)

        #expect(filtered.items.count == 2)
        #expect(filtered.scanDuration == 1.5)
    }

    @Test("排除子树内的后代路径")
    func excludesDescendants() async {
        let manager = InMemoryExclusionManager(excludedPaths: ["/tmp/cache/keep"])
        let filter = ScanResultFilter(exclusionManager: manager)
        let result = ScanResult(
            module: .developerCaches,
            items: [
                CleanableItem(
                    path: "/tmp/cache/keep/sub/dir",
                    displayName: "deep",
                    size: 10,
                    category: .developerCaches
                ),
            ],
            scanDuration: 0
        )

        let filtered = await filter.apply(to: result)
        #expect(filtered.items.isEmpty)
    }
}

/// 固定候选的测试模块：用于验证统一扫描入口。
struct FixtureCleanerModule: CleanerModule {
    let identifier: ModuleIdentifier
    let displayName = "Fixture"
    let description = "fixture module"
    let items: [CleanableItem]

    func isAvailable() -> Bool { true }
    func scan(context: ScanContext) async throws -> ScanResult {
        ScanResult(module: identifier, items: items, scanDuration: 0)
    }
    func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        CleanupReport(module: identifier)
    }
}

@Suite("Scheduled scan exclusion integration")
struct ScheduledScanExclusionTests {
    @Test("定时扫描总大小不包含排除路径")
    func scheduledScanAppliesFilter() async throws {
        let tempPath = NSTemporaryDirectory() + "sched-excl-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let exclusionManager = InMemoryExclusionManager(excludedPaths: ["/tmp/cache/keep"])
        let service = ScheduledScanService(storePath: tempPath, exclusionManager: exclusionManager)

        let module = FixtureCleanerModule(
            identifier: .applicationCaches,
            items: [
                CleanableItem(path: "/tmp/cache/delete", displayName: "d", size: 100, category: .applicationCaches),
                CleanableItem(path: "/tmp/cache/keep", displayName: "k", size: 900, category: .applicationCaches),
            ]
        )

        let results = await service.performScanForTesting(modules: [module])
        let kept = results.flatMap(\.items)

        #expect(kept.map(\.path) == ["/tmp/cache/delete"])
        let total = results.reduce(Int64(0)) { $0 + $1.totalSize }
        #expect(total == 100, "排除路径不能计入定时扫描总大小")
    }
}
