import Foundation
import MacCleanerCore

/// 清理完成后的验证报告
struct CleanupSummary: Equatable {
    let expectedSize: Int64
    let actualFreed: Int64
    /// 移到废纸篓的大小（磁盘空间未真正释放）
    let trashedSize: Int64
    let successCount: Int
    let failureCount: Int
    let failedItems: [FailedItem]
    let hasPermissionIssues: Bool

    var discrepancy: Int64 { expectedSize - actualFreed - trashedSize }
    var hasDiscrepancy: Bool { discrepancy != 0 && !failedItems.isEmpty }
    var hasTrashedItems: Bool { trashedSize > 0 }

    /// 按失败原因分组
    var failuresByReason: [FailureReason: [FailedItem]] {
        Dictionary(grouping: failedItems, by: \.reason)
    }

    static func == (lhs: CleanupSummary, rhs: CleanupSummary) -> Bool {
        lhs.expectedSize == rhs.expectedSize
            && lhs.actualFreed == rhs.actualFreed
            && lhs.successCount == rhs.successCount
            && lhs.failureCount == rhs.failureCount
    }
}

@Observable
@MainActor
final class CleanupViewModel {
    enum State: Equatable {
        case idle
        case cleaning(progress: Double, current: String)
        case done(summary: CleanupSummary)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case let (.cleaning(lp, lc), .cleaning(rp, rc)): return lp == rp && lc == rc
            case let (.done(ls), .done(rs)): return ls == rs
            case let (.failed(l), .failed(r)): return l == r
            default: return false
            }
        }
    }

    var state: State = .idle

    func clean(items: [CleanableItem], dryRun: Bool = false) {
        guard !items.isEmpty else { return }

        state = .cleaning(progress: 0, current: "")

        Task {
            var grouped: [ModuleIdentifier: [CleanableItem]] = [:]
            for item in items {
                grouped[item.category, default: []].append(item)
            }

            let moduleIDs = Array(grouped.keys)
            var totalExpected: Int64 = 0
            var totalActualFreed: Int64 = 0
            var totalTrashed: Int64 = 0
            var totalSuccess = 0
            var totalFailed = 0
            var allFailedItems: [FailedItem] = []
            var hasPermissionIssues = false
            var allReports: [CleanupReport] = []

            for (index, moduleID) in moduleIDs.enumerated() {
                guard let module = ModuleRegistry.module(for: moduleID),
                      let batch = grouped[moduleID]
                else { continue }

                let batchExpected = batch.reduce(Int64(0)) { $0 + $1.size }
                totalExpected += batchExpected

                let progress = Double(index + 1) / Double(moduleIDs.count)
                state = .cleaning(progress: progress, current: module.displayName)

                do {
                    let report = try await module.clean(items: batch, dryRun: dryRun)
                    allReports.append(report)
                    totalActualFreed += report.actualFreed
                    totalTrashed += report.trashedSize
                    totalSuccess += report.successCount
                    totalFailed += report.failureCount
                    allFailedItems.append(contentsOf: report.failedItems)
                    if report.hasPermissionFailures {
                        hasPermissionIssues = true
                    }
                } catch {
                    state = .failed("清理 \(module.displayName) 失败: \(error.localizedDescription)")
                    return
                }
            }

            // 持久化清理记录
            await CleanupHistoryStore.shared.record(reports: allReports, dryRun: dryRun)

            let summary = CleanupSummary(
                expectedSize: totalExpected,
                actualFreed: totalActualFreed,
                trashedSize: totalTrashed,
                successCount: totalSuccess,
                failureCount: totalFailed,
                failedItems: allFailedItems,
                hasPermissionIssues: hasPermissionIssues
            )
            state = .done(summary: summary)
        }
    }

    func reset() {
        state = .idle
    }
}
