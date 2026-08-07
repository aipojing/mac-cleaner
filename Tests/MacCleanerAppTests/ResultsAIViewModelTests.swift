import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

extension AIAssessment {
    static func fixture(
        subjectID: String = "cleanup:fixture",
        fingerprint: String = String(repeating: "a", count: 64),
        summary: String = "缓存目录",
        explanation: String = "应用生成的缓存数据，删除后应用会按需重建。",
        risk: AIRiskLevel = .low,
        recommendation: AIRecommendation = .delete,
        confidence: AIConfidence = .medium,
        evidence: [String] = ["位于 Library/Caches 下"],
        model: String = "deepseek-v4-pro",
        assessedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> AIAssessment {
        try AIAssessment(
            subjectID: subjectID,
            fingerprint: fingerprint,
            summary: summary,
            explanation: explanation,
            risk: risk,
            recommendation: recommendation,
            confidence: confidence,
            evidence: evidence,
            model: model,
            assessedAt: assessedAt
        )
    }
}

extension CleanableItem {
    static func appFixture(
        path: String = "/tmp/cache-a",
        displayName: String = "缓存 A",
        size: Int64 = 1_024,
        category: ModuleIdentifier = .developerCaches,
        subcategory: String? = "npm",
        evidenceTags: [String] = ["cache", "developer-tool", "npm"],
        fileIdentity: FileIdentity? = FileIdentity(device: 1, inode: 1, kind: .directory)
    ) -> CleanableItem {
        CleanableItem(
            path: path,
            displayName: displayName,
            size: size,
            category: category,
            subcategory: subcategory,
            evidenceTags: evidenceTags,
            fileIdentity: fileIdentity
        )
    }
}

extension ResultsViewModel {
    /// 测试夹具：两个清理项，可预制缓存结论。
    static func fixture(
        aiService: RecordingAIService,
        cached: AIAssessment? = nil
    ) async -> ResultsViewModel {
        let items = [
            CleanableItem.appFixture(),
            CleanableItem.appFixture(
                path: "/tmp/cache-b",
                displayName: "缓存 B",
                fileIdentity: FileIdentity(device: 1, inode: 2, kind: .directory)
            ),
        ]
        let results = [ScanResult(module: .developerCaches, items: items)]
        if let cached, let first = items.first,
           let subject = try? AIAssessmentSubjectFactory().cleanupSubject(for: first) {
            await aiService.setState(.cached(cached), for: subject.subjectID)
        }
        return ResultsViewModel(results: results, aiService: aiService)
    }
}

@MainActor
@Suite("Results AI view model")
struct ResultsAIViewModelTests {
    @Test("初始化只读缓存，不调用分析")
    func initializationReadsCacheOnly() async {
        let ai = RecordingAIService(states: ["item-1": .notAnalyzed])
        let viewModel = await ResultsViewModel.fixture(aiService: ai)
        await viewModel.loadCachedAssessments()
        #expect(await ai.stateLookupCount == 1)
        #expect(await ai.analysisCallCount == 0)
        #expect(viewModel.selectedItemIDs.isEmpty)
        #expect(viewModel.assessmentStates.count == 2)
    }

    @Test("缓存命中直接展示，不联网")
    func cacheHitDisplaysWithoutNetwork() async throws {
        let cached = try AIAssessment.fixture(summary: "旧结果")
        let ai = RecordingAIService()
        let viewModel = await ResultsViewModel.fixture(aiService: ai, cached: cached)
        await viewModel.loadCachedAssessments()
        #expect(await ai.analysisCallCount == 0)
        let state = viewModel.assessmentStates[viewModel.allItems[0].id]
        #expect(state?.assessment == cached)
    }

    @Test("缓存缺失只有用户点击后请求")
    func missingRequiresExplicitClick() async {
        let ai = RecordingAIService(states: ["item-1": .notAnalyzed])
        let viewModel = await ResultsViewModel.fixture(aiService: ai)
        await viewModel.loadCachedAssessments()
        #expect(await ai.analysisCallCount == 0)
        await viewModel.analyzeItem(viewModel.allItems[0])
        #expect(await ai.analysisCallCount == 1)
        #expect(await ai.lastForceRefresh == false)
    }

    @Test("AI 建议删除也不改变选择")
    func assessmentNeverSelectsItem() async throws {
        let ai = RecordingAIService(result: try AIAssessment.fixture(recommendation: .delete))
        let viewModel = await ResultsViewModel.fixture(aiService: ai)
        await viewModel.analyzeItem(viewModel.allItems[0])
        #expect(viewModel.selectedItemIDs.isEmpty)
    }

    @Test("批量分析只请求未分析项")
    func batchAnalyzesOnlyMissing() async throws {
        let cached = try AIAssessment.fixture(summary: "旧结果")
        let ai = RecordingAIService(result: try AIAssessment.fixture())
        let viewModel = await ResultsViewModel.fixture(aiService: ai, cached: cached)
        await viewModel.loadCachedAssessments()
        #expect(viewModel.unanalyzedCount == 1)
        await viewModel.analyzeMissingItems()
        #expect(await ai.analysisCallCount == 1)
        let analyzedIDs = await ai.analyzedSubjectIDs.flatMap { $0 }
        #expect(analyzedIDs.count == 1)
        #expect(viewModel.selectedItemIDs.isEmpty)
    }

    @Test("批量分析每次最多提交十项，其余条目保持可单独分析")
    func batchAnalysisOnlySubmitsNextTenItems() async throws {
        let items = (0..<12).map { index in
            CleanableItem.appFixture(
                path: "/tmp/cache-\(index)",
                displayName: "缓存 \(index)",
                fileIdentity: FileIdentity(
                    device: 1,
                    inode: UInt64(index + 1),
                    kind: .directory
                )
            )
        }
        let ai = RecordingAIService(result: try AIAssessment.fixture())
        let viewModel = ResultsViewModel(
            results: [ScanResult(module: .developerCaches, items: items)],
            aiService: ai
        )
        await viewModel.loadCachedAssessments()

        #expect(viewModel.nextAnalysisBatchCount == 10)
        await viewModel.analyzeMissingItems()

        let analyzedIDs = await ai.analyzedSubjectIDs.flatMap { $0 }
        #expect(analyzedIDs.count == 10)
        #expect(viewModel.unanalyzedCount == 2)
        #expect(viewModel.nextAnalysisBatchCount == 2)
        #expect(viewModel.assessmentStates[items[10].id] == .notAnalyzed)
        #expect(viewModel.assessmentStates[items[11].id] == .notAnalyzed)
    }

    @Test("重查失败保留旧卡片")
    func failedRefreshKeepsPreviousAssessment() async throws {
        let cached = try AIAssessment.fixture(summary: "旧结果")
        let ai = RecordingAIService(refreshError: TestDoubleError.offline)
        let viewModel = await ResultsViewModel.fixture(aiService: ai, cached: cached)
        await viewModel.loadCachedAssessments()
        await viewModel.reanalyzeItem(viewModel.allItems[0])
        #expect(await ai.lastForceRefresh == true)
        #expect(viewModel.assessmentStates[viewModel.allItems[0].id]?.assessment == cached)
    }

    @Test("取消分析调用服务并让单条加载状态立即回落")
    func cancelStopsAnalysisAndResetsSingleLoadingState() async {
        let ai = RecordingAIService()
        let viewModel = await ResultsViewModel.fixture(aiService: ai)
        let item = viewModel.allItems[0]
        viewModel.assessmentStates[item.id] = .loading(previous: nil)

        await viewModel.cancelAIAnalysis()

        #expect(await ai.cancelCallCount == 1)
        #expect(viewModel.assessmentStates[item.id] == .notAnalyzed)
    }
}
