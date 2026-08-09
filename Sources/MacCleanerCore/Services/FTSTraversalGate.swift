import Foundation

/// 进程内所有 `fts_open` 遍历共用的并发边界。
///
/// 调用方只负责在遍历外包一层许可，避免各模块各自限流后叠加放大磁盘 IO。
/// 上限固定为保守的 2，与文件任务并发解耦，避免模块并发与目录大小计算
/// 共同放大元数据读取压力。
///
/// 提供两种入口：
/// - `withPermit`（async）：等待许可时任务挂起，不占用 Swift 协作线程池线程；
///   等待中被取消立即抛 `CancellationError`。所有 async 调用点必须使用它。
/// - `withPermitBlocking`（sync）：少量遗留同步调用点使用。等待时阻塞当前线程，
///   获许可后遍历也在同一线程执行，不会把等待转嫁到协作线程池。
enum FTSTraversalGate {
    static let maximumConcurrentTraversals = 2
    private static let core = Core(limit: maximumConcurrentTraversals)

    static let tracker = FTSConcurrencyTracker()

    /// 正在等待许可的任务数（测试用：确定性构造“等待中取消”场景）。
    static var pendingWaiterCount: Int { core.pendingWaiterCount }

    /// 异步获取许可后执行遍历。许可在等待、遍历完成、抛错或取消时都会归还；
    /// 等待中被取消的任务不会执行 operation，立即抛 `CancellationError`。
    /// 遍历执行期间的取消由 operation 内部检查 `Task.isCancelled` 负责。
    @discardableResult
    static func withPermit<T>(_ operation: () async throws -> T) async throws -> T {
        try await core.acquireAsync()
        tracker.enter()
        defer {
            tracker.exit()
            core.release()
        }
        try Task.checkCancellation()
        return try await operation()
    }

    /// 同步获取许可（遗留同步调用点）。等待时阻塞当前线程；由于获许可后
    /// 遍历也在当前线程上执行，许可持有者总能独立推进，不存在“线程已阻塞、
    /// 工作却排在协作池上无人执行”的饥饿风险。不可取消，新代码勿用。
    @discardableResult
    static func withPermitBlocking<T>(_ operation: () throws -> T) rethrows -> T {
        core.acquireSync()
        tracker.enter()
        defer {
            tracker.exit()
            core.release()
        }
        return try operation()
    }

    /// 混合等待队列的许可核心：异步等待者挂起（可即时取消），同步等待者
    /// 阻塞自身线程；两类等待者共享同一上限与 FIFO 顺序，许可释放时直接
    /// 移交给队首等待者（active 计数不变）。
    private final class Core: @unchecked Sendable {
        private enum Waiter {
            case sync(DispatchSemaphore)
            case async(id: UUID, continuation: CheckedContinuation<Void, any Error>)
        }

        private let limit: Int
        private let lock = NSLock()
        private var active = 0
        private var waiters: [Waiter] = []

        init(limit: Int) {
            self.limit = max(1, limit)
        }

        var pendingWaiterCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiters.count
        }

        func acquireSync() {
            lock.lock()
            if waiters.isEmpty && active < limit {
                active += 1
                lock.unlock()
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            waiters.append(.sync(semaphore))
            lock.unlock()
            semaphore.wait()
        }

        func acquireAsync() async throws {
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    lock.lock()
                    // isCancelled 检查与入队在同一把锁下完成：取消若在检查
                    // 之后送达，onCancel 会等锁释放后从队列中找到该等待者。
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if waiters.isEmpty && active < limit {
                        active += 1
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waiters.append(.async(id: id, continuation: continuation))
                    lock.unlock()
                }
            } onCancel: {
                // Core 是普通 NSLock 类（非 actor），取消路径无需跳入
                // 协作线程池，等待中的任务可以立即被唤醒。
                cancelWaiter(id: id)
            }
        }

        /// 取消时从等待队列移除并唤醒；与 release 的“先取出再 resume”
        /// 在同一把锁下互斥，不会重复 resume 同一个 continuation。
        private func cancelWaiter(id: UUID) {
            lock.lock()
            guard let index = waiters.firstIndex(where: {
                if case .async(let waiterID, _) = $0 { return waiterID == id }
                return false
            }) else {
                lock.unlock()
                return
            }
            let waiter = waiters.remove(at: index)
            lock.unlock()
            if case .async(_, let continuation) = waiter {
                continuation.resume(throwing: CancellationError())
            }
        }

        func release() {
            lock.lock()
            guard !waiters.isEmpty else {
                active -= 1
                lock.unlock()
                return
            }
            let next = waiters.removeFirst()
            lock.unlock()
            switch next {
            case .sync(let semaphore):
                semaphore.signal()
            case .async(_, let continuation):
                continuation.resume()
            }
        }
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
