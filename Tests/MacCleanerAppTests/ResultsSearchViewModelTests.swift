import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

@MainActor
@Suite("Results search view model")
struct ResultsSearchViewModelTests {
    @Test("键入、筛选和排序不调用 AI、不改变选择")
    func searchIsLocalAndSelectionNeutral() async {
        let ai = RecordingAIService()
        let viewModel = await ResultsViewModel.fixture(aiService: ai)
        let selectedBefore = viewModel.selectedItemIDs
        viewModel.searchText = "npm"
        viewModel.selectedRisks = [.low]
        viewModel.sortMode = .actionability
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(await ai.analysisCallCount == 0)
        #expect(viewModel.selectedItemIDs == selectedBefore)
    }

    @Test("按路径 basename 文本搜索命中事实项")
    func textSearchHitsFacts() async {
        let ai = RecordingAIService()
        let viewModel = await ResultsViewModel.fixture(aiService: ai)
        viewModel.searchText = "cache-b"
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(viewModel.visibleItems.map(\.path) == ["/tmp/cache-b"])
        #expect(await ai.analysisCallCount == 0)
    }

    @Test("已缓存 AI 文本参与搜索，未分析项不显示虚构说明")
    func cachedAITextIsSearchable() async throws {
        let cached = try AIAssessment.fixture(summary: "图像处理服务")
        let ai = RecordingAIService()
        let viewModel = await ResultsViewModel.fixture(aiService: ai, cached: cached)
        await viewModel.loadCachedAssessments()
        viewModel.searchText = "图像处理"
        await viewModel.updateSearchResultsImmediatelyForTesting()
        // 只有第一项有缓存结论
        #expect(viewModel.visibleItems.map(\.path) == ["/tmp/cache-a"])
        #expect(await ai.analysisCallCount == 0)
    }

    @Test("筛选组合只保留匹配项且不影响选择")
    func filtersCombine() async {
        let ai = RecordingAIService()
        let viewModel = await ResultsViewModel.fixture(aiService: ai)
        viewModel.toggleItem(viewModel.allItems[0])
        let selectedBefore = viewModel.selectedItemIDs
        viewModel.selectedModules = [.xcode]
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(viewModel.visibleItems.isEmpty)
        #expect(viewModel.selectedItemIDs == selectedBefore)
    }

    @Test("重置筛选只清筛选不清选择")
    func resetFiltersKeepsSelection() async {
        let ai = RecordingAIService()
        let viewModel = await ResultsViewModel.fixture(aiService: ai)
        viewModel.toggleItem(viewModel.allItems[0])
        let selectedBefore = viewModel.selectedItemIDs
        viewModel.searchText = "npm"
        viewModel.selectedModules = [.xcode]
        viewModel.selectedRisks = [.high]
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(viewModel.visibleItems.isEmpty)

        viewModel.resetFilters()
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(viewModel.searchText.isEmpty)
        #expect(viewModel.selectedModules.isEmpty)
        #expect(viewModel.selectedRisks.isEmpty)
        #expect(viewModel.selectedItemIDs == selectedBefore)
        #expect(viewModel.visibleItems.count == 2)
    }

    @Test("跨模块硬链接的分组小计之和等于全局已选空间")
    func moduleSelectedSizesUseGlobalAttribution() {
        let identity = FileIdentity(device: 1, inode: 42, kind: .regularFile)
        let developerItem = CleanableItem(
            path: "/tmp/dev-link",
            displayName: "dev-link",
            size: 4096,
            category: .developerCaches,
            fileIdentity: identity,
            allocatedSize: 4096,
            linkCount: 2
        )
        let applicationItem = CleanableItem(
            path: "/tmp/app-link",
            displayName: "app-link",
            size: 4096,
            category: .applicationCaches,
            fileIdentity: identity,
            allocatedSize: 4096,
            linkCount: 2
        )
        let viewModel = ResultsViewModel(
            results: [
                ScanResult(module: .developerCaches, items: [developerItem]),
                ScanResult(module: .applicationCaches, items: [applicationItem]),
            ],
            aiService: RecordingAIService()
        )
        viewModel.toggleItem(developerItem)
        viewModel.toggleItem(applicationItem)

        let developerSize = viewModel.selectedSize(for: .developerCaches)
        let applicationSize = viewModel.selectedSize(for: .applicationCaches)

        #expect(developerSize == 4096)
        #expect(applicationSize == 0)
        #expect(developerSize + applicationSize == viewModel.totalSelectedSize)
    }
}
