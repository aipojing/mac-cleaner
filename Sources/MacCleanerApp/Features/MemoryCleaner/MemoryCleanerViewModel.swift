import Foundation
import MacCleanerCore

@Observable
@MainActor
final class MemoryCleanerViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case cleaning
        case done(freedBytes: UInt64)
        case failed(String)
    }

    var phase: Phase = .idle
    var memoryInfo: MemoryInfo?

    private let monitor: MemoryMonitor
    private let cleanerService: any MemoryCleanerService
    private let fallbackService: any MemoryCleanerService
    private var monitorTask: Task<Void, Never>?

    init(
        monitor: MemoryMonitor = .shared,
        cleanerService: any MemoryCleanerService = XPCMemoryCleanerService(),
        fallbackService: any MemoryCleanerService = AppleScriptMemoryCleanerService()
    ) {
        self.monitor = monitor
        self.cleanerService = cleanerService
        self.fallbackService = fallbackService
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        phase = .loading

        monitorTask = Task {
            await monitor.start(interval: 3)
            for await info in await monitor.updates {
                guard !Task.isCancelled else { break }
                memoryInfo = info
                // 只在非清理状态时更新 phase
                if case .cleaning = phase { continue }
                if case .done = phase { continue }
                phase = .loaded
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        Task { await monitor.stop() }
    }

    func cleanMemory() async {
        if case .cleaning = phase { return }

        let beforeUsed = memoryInfo?.usedBytes ?? 0
        phase = .cleaning

        do {
            // 优先 XPC 特权助手；未安装则降级到 AppleScript 提权
            do {
                try await cleanerService.purgeMemory()
            } catch {
                try await fallbackService.purgeMemory()
            }
            // 等一下让系统更新内存统计
            try? await Task.sleep(for: .milliseconds(500))
            await monitor.refresh()

            // 直接从 actor 读取最新快照，避免依赖 AsyncStream 消费时序
            let afterUsed = await monitor.current?.usedBytes ?? beforeUsed
            let freed = beforeUsed > afterUsed ? beforeUsed - afterUsed : 0
            phase = .done(freedBytes: freed)

            // 3秒后恢复正常状态
            Task {
                try? await Task.sleep(for: .seconds(3))
                if case .done = phase {
                    phase = .loaded
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
