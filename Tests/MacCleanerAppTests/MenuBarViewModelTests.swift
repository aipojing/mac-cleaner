import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

@MainActor
@Suite("Menu bar view model")
struct MenuBarViewModelTests {
    @Test("start 幂等：重复调用不替换也不新增轮询任务")
    func startIsIdempotent() {
        let monitor = DiskSpaceMonitor(spaceProvider: {
            DiskSpaceInfo(totalBytes: 500_000_000_000, freeBytes: 250_000_000_000)
        })
        let viewModel = MenuBarViewModel(monitor: monitor)

        viewModel.start()
        let firstMonitorTask = viewModel.monitorTask
        let firstCheckTask = viewModel.scheduledCheckTask
        #expect(firstMonitorTask != nil)
        #expect(firstCheckTask != nil)

        // popover 每次 onAppear 都会调用 start()
        viewModel.start()
        viewModel.start()

        #expect(viewModel.monitorTask == firstMonitorTask, "重复 start 不得替换磁盘监视任务")
        #expect(viewModel.scheduledCheckTask == firstCheckTask, "重复 start 不得累积定时同步轮询")
    }
}
