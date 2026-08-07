import Foundation
import MacCleanerCore

@Observable
@MainActor
final class DuplicateFinderViewModel {
    enum Phase {
        case idle
        case scanning
        case done
        case cleaning
        case failed(String)
    }

    var phase: Phase = .idle
    var groups: [DuplicateGroup] = []
    /// groupID → 用户显式选择要保留的 fileID。扫描后为空：
    /// 组内默认不选中，没有任何删除计划，直到用户点选保留文件或应用策略。
    var keptFiles: [String: UUID] = [:]
    var selectedStrategy: DuplicateRetentionStrategy = .keepNewest
    var preferredDirectory: String = ""
    /// 最近一次清理的失败摘要（成功或尚未清理时为 nil）
    var lastCleanError: String?

    private let module: DuplicateFilesModule

    init(module: DuplicateFilesModule = DuplicateFilesModule()) {
        self.module = module
    }

    var totalWastedSpace: Int64 {
        groups.reduce(0) { $0 + $1.totalWastedSpace }
    }

    /// 待删除项：只统计用户已显式选择保留文件的组；
    /// 未做选择的组不产生任何待删项。
    var itemsToDelete: [CleanableItem] {
        groups.flatMap { group in
            guard let keepID = keptFiles[group.id] else { return [CleanableItem]() }
            return group.files
                .filter { $0.id != keepID }
                .map {
                    CleanableItem(
                        path: $0.path, displayName: $0.name, size: $0.size,
                        category: .duplicateFiles,
                        evidenceTags: ["duplicate-file", "content-hash"],
                        fileIdentity: $0.fileIdentity
                    )
                }
        }
    }

    var deletableSize: Int64 {
        itemsToDelete.reduce(0) { $0 + $1.size }
    }

    func startScan() {
        phase = .scanning
        groups = []
        keptFiles = [:]
        lastCleanError = nil

        Task { await performScan() }
    }

    /// 测试入口：同步等待扫描完成
    func performScanForTesting() async {
        phase = .scanning
        groups = []
        keptFiles = [:]
        lastCleanError = nil
        await performScan()
    }

    private func performScan() async {
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await self.module.scan(context: ScanContext())
            }.value
            groups = module.groups(from: result)
            // 不做任何默认保留选择：删除集合保持为空，等用户显式操作。
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 对所有组应用保留策略，更新 keptFiles
    func applyStrategy(_ strategy: DuplicateRetentionStrategy) {
        selectedStrategy = strategy
        for group in groups {
            let toRemove = group.filesToRemove(
                strategy: strategy,
                preferredDirectory: strategy == .keepInDirectory ? preferredDirectory : nil
            )
            let removeIDs = Set(toRemove.map(\.id))
            let keepFile = group.files.first { !removeIDs.contains($0.id) }
            keptFiles[group.id] = keepFile?.id ?? group.files.first?.id
        }
    }

    func clean() {
        let items = itemsToDelete
        guard !items.isEmpty else { return }
        phase = .cleaning
        lastCleanError = nil

        Task { await performClean(items: items) }
    }

    /// 测试入口：同步等待清理完成
    func cleanForTesting() async {
        let items = itemsToDelete
        guard !items.isEmpty else { return }
        phase = .cleaning
        lastCleanError = nil
        await performClean(items: items)
    }

    private func performClean(items: [CleanableItem]) async {
        do {
            let report = try await module.clean(items: items, dryRun: false)

            // 从列表中移除已删除的文件，保留失败项供用户查看
            let deletedPaths = Set(report.deletedItems.map(\.path))
            groups = groups.compactMap { group in
                let remaining = group.files.filter { !deletedPaths.contains($0.path) }
                guard remaining.count >= 2 else { return nil }
                return DuplicateGroup(id: group.id, fileSize: group.fileSize, files: remaining)
            }
            let survivingGroupIDs = Set(groups.map(\.id))
            keptFiles = keptFiles.filter { survivingGroupIDs.contains($0.key) }

            if report.failureCount > 0 {
                let reasons = report.failedItems.prefix(3).map {
                    "\(($0.path as NSString).lastPathComponent)：\($0.error)"
                }.joined(separator: "；")
                lastCleanError = "\(report.failureCount) 项清理失败：\(reasons)"
            }
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
