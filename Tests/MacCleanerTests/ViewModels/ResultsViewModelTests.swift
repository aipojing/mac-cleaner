import Testing
@testable import MacCleanerCore

@Suite("CleanableItem facts")
struct CleanableItemFactsTests {
    @Test("事实初始化器记录路径、大小、模块和标签")
    func factsInitializer() {
        let item = CleanableItem(
            path: "/tmp/cache",
            displayName: "缓存",
            size: 1_024,
            category: .developerCaches,
            subcategory: "npm",
            evidenceTags: ["cache", "developer-tool", "npm"]
        )
        #expect(item.path == "/tmp/cache")
        #expect(item.size == 1_024)
        #expect(item.evidenceTags == ["cache", "developer-tool", "npm"])
    }

    @Test("ScanResult 统计全部候选大小，不区分推荐")
    func scanResultTotalsAllCandidates() {
        let result = ScanResult(
            module: .developerCaches,
            items: [
                CleanableItem(path: "/a", displayName: "a", size: 100,
                              category: .developerCaches, evidenceTags: ["cache"]),
                CleanableItem(path: "/b", displayName: "b", size: 200,
                              category: .developerCaches, evidenceTags: ["cache"]),
            ]
        )
        #expect(result.items.count == 2)
        #expect(result.totalSize == 300)
    }

    @Test("初始选择策略永远为空，AI 与扫描结果默认不选中")
    func initialSelectionIsEmpty() {
        let items = [
            CleanableItem(path: "/a", displayName: "a", size: 100,
                          category: .developerCaches, evidenceTags: ["cache"]),
        ]
        #expect(CleanupSelectionPolicy.initialSelection(from: items).isEmpty)
    }
}
