import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

@MainActor
@Suite("Activity monitor search view model")
struct ActivityMonitorSearchViewModelTests {
    @Test("进程搜索包含真实路径和已有 AI 文本")
    func processSearchUsesFactsAndCachedAI() async throws {
        let ai = RecordingAIService()
        let process = RunningProcess.appFixture(path: "/Applications/Test.app/Test")
        let cached = try AIAssessment.fixture(summary: "图像处理服务")
        if let subject = try? AIAssessmentSubjectFactory().processSubject(for: process) {
            await ai.setState(.cached(cached), for: subject.subjectID)
        }
        let viewModel = ActivityMonitorViewModel(
            fetcher: StubProcessListFetcher(processes: [process]),
            aiService: ai
        )
        await viewModel.refresh()

        viewModel.searchText = "图像处理"
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(viewModel.filteredProcesses.count == 1)
        #expect(await ai.analysisCallCount == 0)
    }

    @Test("按路径事实搜索不触发 AI")
    func pathSearchIsLocalOnly() async {
        let ai = RecordingAIService()
        let process = RunningProcess.appFixture(path: "/Applications/Test.app/Test")
        let viewModel = ActivityMonitorViewModel(
            fetcher: StubProcessListFetcher(processes: [process]),
            aiService: ai
        )
        await viewModel.refresh()
        let analysisCallsBefore = await ai.analysisCallCount

        viewModel.searchText = "Test.app"
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(viewModel.filteredProcesses.count == 1)
        #expect(await ai.analysisCallCount == analysisCallsBefore)
    }

    @Test("未匹配文本得到空结果，清空后恢复")
    func emptyMatchAndRestore() async {
        let ai = RecordingAIService()
        let process = RunningProcess.appFixture()
        let viewModel = ActivityMonitorViewModel(
            fetcher: StubProcessListFetcher(processes: [process]),
            aiService: ai
        )
        await viewModel.refresh()
        #expect(viewModel.filteredProcesses.count == 1)

        viewModel.searchText = "绝不存在的进程名xyz"
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(viewModel.filteredProcesses.isEmpty)

        viewModel.searchText = ""
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(viewModel.filteredProcesses.count == 1)
    }

    @Test("AI 状态筛选只保留匹配的进程")
    func assessmentStatusFilter() async throws {
        let ai = RecordingAIService()
        let cachedProcess = RunningProcess.appFixture(pid: 101, name: "Cached")
        let plainProcess = RunningProcess.appFixture(pid: 102, name: "Plain")
        let cached = try AIAssessment.fixture(summary: "缓存结论")
        if let subject = try? AIAssessmentSubjectFactory().processSubject(for: cachedProcess) {
            await ai.setState(.cached(cached), for: subject.subjectID)
        }
        let viewModel = ActivityMonitorViewModel(
            fetcher: StubProcessListFetcher(processes: [cachedProcess, plainProcess]),
            aiService: ai
        )
        await viewModel.refresh()

        viewModel.selectedAssessmentStatuses = [.cached]
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(viewModel.filteredProcesses.map(\.name) == ["Cached"])
        #expect(await ai.analysisCallCount == 0)
    }
}
