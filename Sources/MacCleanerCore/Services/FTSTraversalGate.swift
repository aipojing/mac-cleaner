import Foundation

/// 进程内所有 `fts_open` 遍历共用的并发边界。
///
/// 调用方只负责在同步遍历闭包外包一层 `withPermit`，避免各模块各自
/// 限流后叠加放大磁盘 IO。默认上限与扫描文件任务上限一致。
enum FTSTraversalGate {
    private static let semaphore = DispatchSemaphore(
        value: ScanContext.defaultFileTaskLimit
    )

    static let tracker = FTSConcurrencyTracker()

    @discardableResult
    static func withPermit<T>(_ operation: () throws -> T) rethrows -> T {
        semaphore.wait()
        tracker.enter()
        defer {
            tracker.exit()
            semaphore.signal()
        }
        return try operation()
    }
}

struct FTSConcurrencySnapshot: Sendable {
    let current: Int
    let peak: Int
    let totalEntries: Int
}

/// 轻量并发探针，用于验证所有 fts 入口都经过统一 gate。
final class FTSConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var currentValue = 0
    private var peakValue = 0
    private var totalEntriesValue = 0

    var peak: Int { snapshot().peak }

    func enter() {
        lock.lock()
        currentValue += 1
        totalEntriesValue += 1
        peakValue = max(peakValue, currentValue)
        lock.unlock()
    }

    func exit() {
        lock.lock()
        currentValue -= 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        // 测试可能与其他套件并行；不能把仍在运行的遍历从峰值中抹掉。
        peakValue = currentValue
        lock.unlock()
    }

    func snapshot() -> FTSConcurrencySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return FTSConcurrencySnapshot(
            current: currentValue,
            peak: peakValue,
            totalEntries: totalEntriesValue
        )
    }
}
