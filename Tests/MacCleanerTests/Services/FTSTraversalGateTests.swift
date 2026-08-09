import Foundation
import Testing
@testable import MacCleanerCore

@Suite("FTS traversal gate async")
struct FTSTraversalGateAsyncTests {
    @Test("等待许可期间取消任务立即抛 CancellationError")
    func cancelWhileWaitingThrowsImmediately() async throws {
        let holdGate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)

        // 占满全部许可的持有者：持有期间阻塞各自线程，测试结束才放行
        var holders: [Task<Void, Error>] = []
        for _ in 0..<FTSTraversalGate.maximumConcurrentTraversals {
            holders.append(Task {
                try await FTSTraversalGate.withPermit {
                    entered.signal()
                    holdGate.wait()
                }
            })
        }
        for _ in 0..<FTSTraversalGate.maximumConcurrentTraversals {
            entered.wait()
        }

        // 第三个任务排队等待许可（许可被占满，必然进入等待队列）
        let waiter = Task {
            try await FTSTraversalGate.withPermit { }
        }
        // 轮询等待队列，不依赖固定 sleep 时序
        while FTSTraversalGate.pendingWaiterCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let start = Date()
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(
            Date().timeIntervalSince(start) < 1,
            "等待中的取消必须立即生效，不能等到许可释放"
        )

        for _ in 0..<FTSTraversalGate.maximumConcurrentTraversals {
            holdGate.signal()
        }
        for holder in holders {
            try await holder.value
        }
    }

    @Test("operation 抛错或许可取消后许可正常归还，后续获取不卡死")
    func permitReleasedAfterThrow() async throws {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await FTSTraversalGate.withPermit { throw Boom() }
        }
        // 许可已归还：能立即再获取（若泄漏，此处将等到超时）。
        // 不做 tracker.current 绝对值断言——其他套件并行持有许可。
        try await FTSTraversalGate.withPermit { }
    }
}
