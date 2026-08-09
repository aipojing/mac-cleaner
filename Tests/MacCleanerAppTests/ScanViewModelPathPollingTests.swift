import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

@MainActor
@Suite("Scan view model path polling lifecycle")
struct ScanViewModelPathPollingTests {
    @Test("重新启动扫描会取消上一次的路径轮询任务")
    func restartCancelsPreviousPollTask() async {
        let viewModel = ScanViewModel()
        // 空模块集：走快速失败分支，不触碰真实文件系统
        viewModel.selectedModuleIDs = []

        viewModel.startScan()
        let firstPoll = viewModel.pathPollTask
        #expect(firstPoll != nil)

        viewModel.startScan()
        #expect(firstPoll?.isCancelled == true, "旧轮询任务必须在 startScan 开头被取消")
        #expect(viewModel.pathPollTask != nil)

        await waitForFailure(viewModel)
        viewModel.cancel()
    }

    @Test("扫描失败路径会停掉路径轮询任务，不残留永久任务")
    func failureStopsPollTask() async {
        let viewModel = ScanViewModel()
        viewModel.selectedModuleIDs = []

        viewModel.startScan()
        let poll = viewModel.pathPollTask

        await waitForFailure(viewModel)

        if case .failed = viewModel.phase {} else {
            Issue.record("空模块集扫描应进入失败状态")
        }
        #expect(poll?.isCancelled == true)
        #expect(viewModel.pathPollTask == nil, "失败后不得残留永久 100ms 轮询任务")
    }

    private func waitForFailure(_ viewModel: ScanViewModel) async {
        for _ in 0..<200 {
            if case .failed = viewModel.phase { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
