import Foundation
import MacCleanerCore
import os.log

private let logger = Logger(subsystem: "com.maccleaner.app", category: "Scan")

@Observable
@MainActor
final class ScanViewModel {
    enum Phase: Equatable {
        case idle
        case scanning(completed: Int, total: Int)
        case done
        case failed(String)
    }

    var phase: Phase = .idle
    var selectedModuleIDs: Set<ModuleIdentifier> = Set(
        ModuleIdentifier.allCases.filter { $0 != .largeFiles && $0 != .duplicateFiles }
    )
    var results: [ScanResult] = []
    var completedModules: [ModuleIdentifier] = []
    var totalDiscoveredSize: Int64 = 0
    var currentScanPath: String = ""

    /// 单模块大文件扫描进行中的实时状态；扫描结束/取消/重置时清空。
    var liveLargeFileItems: [CleanableItem] = []
    var liveLargeFileMatchCount = 0
    var liveLargeFileMatchedSize: Int64 = 0

    /// 仅当本次扫描只选中大文件模块时才启用实时预览。
    var isLargeFileScan: Bool {
        selectedModuleIDs == [.largeFiles]
    }

    private var scanTask: Task<Void, Never>?
    private var pathPollTask: Task<Void, Never>?

    var availableModules: [any CleanerModule] {
        ModuleRegistry.availableModules()
    }

    func startScan() {
        scanTask?.cancel()
        results = []
        clearLiveLargeFileResults()

        let moduleIDs = selectedModuleIDs
        totalDiscoveredSize = 0
        currentScanPath = ""
        completedModules = []
        ScanProgress.shared.reset()
        logger.notice("startScan()")

        // 定期从 ScanProgress 读取当前扫描路径
        pathPollTask = Task {
            while !Task.isCancelled {
                let path = ScanProgress.shared.currentPath
                if !path.isEmpty {
                    currentScanPath = path
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        scanTask = Task {
            let modules = ModuleRegistry.modules(for: Array(moduleIDs))
                .filter { $0.isAvailable() }

            guard !modules.isEmpty else {
                phase = .failed("没有可用的清理模块")
                return
            }

            let total = modules.count
            phase = .scanning(completed: 0, total: total)
            logger.notice("scanning \(total) modules via coordinator")

            // 仅单模块大文件扫描接入实时快照处理器（已在核心层限频）
            let updateHandler: (@Sendable (LargeFileScanUpdate) -> Void)?
            if moduleIDs == [.largeFiles] {
                updateHandler = { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.applyLargeFileUpdate(update)
                    }
                }
            } else {
                updateHandler = nil
            }

            // 统一扫描入口：共享 ScanContext，模块级有界并发。
            let coordinator = ScanCoordinator(
                modules: modules,
                onModuleFinished: { outcome in
                    if let error = outcome.error {
                        logger.error("\(outcome.module.displayName) error: \(error.localizedDescription)")
                    }
                    Task { @MainActor [weak self] in
                        guard let self, case .scanning = self.phase else { return }
                        self.phase = .scanning(completed: outcome.completedCount, total: outcome.totalCount)
                        if let result = outcome.result {
                            // 实时追加到 results，让 UI 能立即显示已完成模块
                            self.results.append(result)
                            self.completedModules.append(result.module)
                            self.totalDiscoveredSize = PhysicalSizeCalculator.uniqueAllocatedBytes(
                                in: self.results.flatMap(\.items)
                            )
                        }
                    }
                },
                onLargeFileUpdate: updateHandler
            )

            let scanned: [ScanResult]
            do {
                scanned = try await coordinator.scan()
            } catch {
                guard !Task.isCancelled else { return }
                clearLiveLargeFileResults()
                phase = .failed(error.localizedDescription)
                return
            }

            guard !Task.isCancelled else { return }

            pathPollTask?.cancel()
            currentScanPath = ""
            clearLiveLargeFileResults()

            // 并行应用统一排除过滤器（与 CLI、定时扫描同一入口）
            let filter = ScanResultFilter(exclusionManager: ExclusionManager.shared)
            let filtered = await withTaskGroup(of: ScanResult.self) { group in
                for result in scanned {
                    group.addTask {
                        let filteredResult = await filter.apply(to: result)
                        let excluded = result.items.count - filteredResult.items.count
                        if excluded > 0 {
                            logger.notice("\(result.module.displayName): excluded \(excluded) items by rules")
                        }
                        return filteredResult
                    }
                }
                var collected: [ScanResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            results = filtered
            // 总大小按物理占用统计：硬链接去重，不直接求和
            totalDiscoveredSize = PhysicalSizeCalculator.uniqueAllocatedBytes(
                in: results.flatMap(\.items)
            )

            // 排序保持稳定顺序
            let order = ModuleIdentifier.allCases
            results.sort { a, b in
                (order.firstIndex(of: a.module) ?? 0) < (order.firstIndex(of: b.module) ?? 0)
            }

            phase = .done
            logger.notice("scan complete: \(self.results.count) results")
        }
    }

    func cancel() {
        scanTask?.cancel()
        pathPollTask?.cancel()
        clearLiveLargeFileResults()
        phase = .idle
    }

    func reset() {
        scanTask?.cancel()
        pathPollTask?.cancel()
        results = []
        completedModules = []
        totalDiscoveredSize = 0
        currentScanPath = ""
        clearLiveLargeFileResults()
        phase = .idle
    }

    /// 应用核心层已限频的实时快照；只替换临时状态，绝不写入正式 results。
    func applyLargeFileUpdate(_ update: LargeFileScanUpdate) {
        liveLargeFileItems = update.items
        liveLargeFileMatchCount = update.matchedFileCount
        liveLargeFileMatchedSize = update.matchedAllocatedSize
    }

    private func clearLiveLargeFileResults() {
        liveLargeFileItems = []
        liveLargeFileMatchCount = 0
        liveLargeFileMatchedSize = 0
    }
}
