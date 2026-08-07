import Foundation

/// 有界并发许可器：限制同时执行的异步任务数量。
///
/// 等待许可的任务按 FIFO 顺序获得许可；许可在 body 完成、抛错或取消时
/// 都会归还。等待中被取消的任务不会执行 body，也不会占用许可。
public actor AsyncLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// 获取许可后执行 body。body 结束（无论成功、抛错或取消）时许可自动归还。
    /// 调用任务被取消时：等待中的直接抛 `CancellationError`，不执行 body。
    public func withPermit<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if waiters.isEmpty && active < limit {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func release() {
        if !waiters.isEmpty {
            // 许可直接移交给最早的等待者，active 计数不变。
            let next = waiters.removeFirst()
            next.continuation.resume()
        } else {
            active -= 1
        }
    }

    /// 取消时从等待队列移除并唤醒；与 release 的“先取出再 resume”互斥，
    /// 不会重复 resume 同一个 continuation。
    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
