import Foundation
import MacCleanerCore

@Observable
@MainActor
final class MenuBarViewModel {
    var diskSpace: DiskSpaceInfo?
    var isScanning = false
    /// 后台扫描发现的候选占用空间（不含推荐/可回收判断）
    var candidateBytes: Int64 = 0
    /// 定时扫描是否已启用
    var isScheduledScanEnabled = false

    private let monitor = DiskSpaceMonitor.shared
    private var monitorTask: Task<Void, Never>?
    private var scheduledCheckTask: Task<Void, Never>?

    func start() {
        monitorTask = Task {
            await monitor.start(interval: 300)
            for await info in await monitor.updates {
                self.diskSpace = info
            }
        }

        // 启动定时扫描（如果已配置）
        Task {
            await ScheduledScanService.shared.startIfEnabled()
            isScheduledScanEnabled = await ScheduledScanService.shared.currentConfig.enabled
        }

        // 定期同步后台扫描结果
        scheduledCheckTask = Task {
            while !Task.isCancelled {
                let candidateBytes = await ScheduledScanService.shared.lastScanCandidateBytes
                self.candidateBytes = candidateBytes
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() {
        Task {
            await monitor.refresh()
        }
    }

    func toggleScheduledScan(enabled: Bool) {
        Task {
            let current = await ScheduledScanService.shared.currentConfig
            await ScheduledScanService.shared.updateConfig(current.withEnabled(enabled))
            isScheduledScanEnabled = enabled
        }
    }

    var menuBarLabel: String {
        guard let info = diskSpace else { return "..." }
        return "\(info.formattedFree) 可用"
    }

    var isLowSpace: Bool {
        guard let info = diskSpace else { return false }
        return info.freePercent < 10
    }

    var hasCandidateSpace: Bool {
        candidateBytes > 100 * 1024 * 1024 // 100MB+
    }
}
