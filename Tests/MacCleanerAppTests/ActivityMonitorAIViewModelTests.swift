import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

extension RunningProcess {
    static func appFixture(
        pid: Int32 = 4_242,
        name: String = "Example",
        path: String = "/Applications/Example.app/Contents/MacOS/Example",
        user: String = "me",
        cpuPercent: Double = 1.5,
        residentMemoryBytes: UInt64 = 50_000_000,
        elapsedSeconds: UInt64? = 3_600,
        identity: ProcessIdentity? = ProcessIdentity(
            pid: 4_242,
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            startTimeTicks: 9_999,
            bundleIdentifier: "com.example.app"
        )
    ) -> RunningProcess {
        RunningProcess(
            id: pid,
            name: name,
            path: path,
            user: user,
            cpuPercent: cpuPercent,
            residentMemoryBytes: residentMemoryBytes,
            elapsedSeconds: elapsedSeconds,
            signedByApple: false,
            identity: identity
        )
    }
}

extension ActivityMonitorViewModel {
    static func fixture(
        aiService: RecordingAIService,
        terminationService: RecordingTerminationService = RecordingTerminationService(),
        processes: [RunningProcess] = [.appFixture()]
    ) async -> ActivityMonitorViewModel {
        let viewModel = ActivityMonitorViewModel(
            fetcher: StubProcessListFetcher(processes: processes),
            terminationService: terminationService,
            aiService: aiService
        )
        await viewModel.refresh()
        return viewModel
    }
}

@MainActor
@Suite("Activity monitor AI view model")
struct ActivityMonitorAIViewModelTests {
    @Test("三秒刷新只加载新 fingerprint 的缓存")
    func refreshNeverAnalyzesAutomatically() async {
        let ai = RecordingAIService()
        let viewModel = await ActivityMonitorViewModel.fixture(aiService: ai)
        await viewModel.refresh()
        #expect(await ai.analysisCallCount == 0)
        #expect(await ai.stateLookupCount == 1)
    }

    @Test("AI 建议关闭不能绕过本地 guard")
    func recommendationCannotTerminate() async throws {
        let ai = RecordingAIService(result: try AIAssessment.fixture(recommendation: .delete))
        let termination = RecordingTerminationService(result: .protectedProcess)
        let viewModel = await ActivityMonitorViewModel.fixture(
            aiService: ai,
            terminationService: termination
        )
        let process = try #require(viewModel.processes.first)
        await viewModel.analyze(process)
        #expect(await termination.signalCount == 0)
        await viewModel.requestTermination(process)
        #expect(await termination.signalCount == 0)
        #expect(viewModel.terminationError == .protectedProcess)
    }

    @Test("显式分析只请求目标进程，不改变其他状态")
    func analyzeSingleProcess() async throws {
        let ai = RecordingAIService(result: try AIAssessment.fixture())
        let viewModel = await ActivityMonitorViewModel.fixture(aiService: ai)
        await viewModel.refresh()
        #expect(await ai.analysisCallCount == 0)

        let process = try #require(viewModel.processes.first)
        await viewModel.analyze(process)
        #expect(await ai.analysisCallCount == 1)
        #expect(await ai.lastForceRefresh == false)
        let state = viewModel.assessmentState(for: process)
        #expect(state?.assessment != nil)
    }

    @Test("缓存命中展示且不联网")
    func cacheHitDisplaysWithoutNetwork() async throws {
        let cached = try AIAssessment.fixture(summary: "旧结果")
        let process = RunningProcess.appFixture()
        let subject = try AIAssessmentSubjectFactory().processSubject(for: process)
        let ai = RecordingAIService(states: [subject.subjectID: .cached(cached)])
        let viewModel = await ActivityMonitorViewModel.fixture(aiService: ai, processes: [process])
        #expect(await ai.analysisCallCount == 0)
        #expect(viewModel.assessmentState(for: process)?.assessment == cached)
    }

    @Test("重查失败保留旧结果")
    func failedRefreshKeepsPrevious() async throws {
        let cached = try AIAssessment.fixture(summary: "旧结果")
        let process = RunningProcess.appFixture()
        let subject = try AIAssessmentSubjectFactory().processSubject(for: process)
        let ai = RecordingAIService(
            states: [subject.subjectID: .cached(cached)],
            refreshError: TestDoubleError.offline
        )
        let viewModel = await ActivityMonitorViewModel.fixture(aiService: ai, processes: [process])
        await viewModel.reanalyze(process)
        #expect(await ai.lastForceRefresh == true)
        #expect(viewModel.assessmentState(for: process)?.assessment == cached)
    }

    @Test("终止成功清除错误并移除进程")
    func successfulTerminationRemovesProcess() async throws {
        let termination = RecordingTerminationService()
        let viewModel = await ActivityMonitorViewModel.fixture(
            aiService: RecordingAIService(),
            terminationService: termination
        )
        let process = try #require(viewModel.processes.first)
        await viewModel.requestTermination(process)
        #expect(await termination.signalCount == 1)
        #expect(viewModel.terminationError == nil)
        #expect(viewModel.processes.isEmpty)
    }
}
