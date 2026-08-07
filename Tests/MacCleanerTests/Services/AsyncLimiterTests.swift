import Testing
import Foundation
@testable import MacCleanerCore

/// 记录并发峰值的探针。
actor ConcurrencyProbe {
    private(set) var currentConcurrent = 0
    private(set) var maximumConcurrent = 0

    func recordWork() async {
        currentConcurrent += 1
        maximumConcurrent = max(maximumConcurrent, currentConcurrent)
        try? await Task.sleep(for: .milliseconds(20))
        currentConcurrent -= 1
    }
}

/// 等待持有者已进入 body 的门闩，消除测试调度竞态。
private actor LimiterGate {
    private var entered = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuations.append($0) }
    }
}

@Suite("Async limiter")
struct AsyncLimiterTests {
    @Test("文件任务不会超过设置的并发数")
    func limitsConcurrency() async {
        let probe = ConcurrencyProbe()
        let limiter = AsyncLimiter(limit: 3)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try? await limiter.withPermit { await probe.recordWork() }
                }
            }
        }
        #expect(await probe.maximumConcurrent == 3)
    }

    @Test("body 抛错后许可被归还，后续任务仍可执行")
    func releasesPermitAfterThrow() async throws {
        let limiter = AsyncLimiter(limit: 1)
        struct ProbeError: Error {}
        await #expect(throws: ProbeError.self) {
            try await limiter.withPermit { throw ProbeError() }
        }
        let value = try await limiter.withPermit { 42 }
        #expect(value == 42)
    }

    @Test("等待中的任务被取消后不执行 body")
    func cancelledWaiterDoesNotRun() async throws {
        let limiter = AsyncLimiter(limit: 1)
        let probe = ConcurrencyProbe()
        let gate = LimiterGate()
        let releaseHolder = LimiterGate()

        // 占住唯一许可，并确认已进入 body（避免调度竞态）；
        // holder 由测试显式放行，不用固定时长睡眠（高负载下会超时）
        let holder = Task {
            try await limiter.withPermit {
                await gate.markEntered()
                await releaseHolder.waitUntilEntered()
            }
        }
        await gate.waitUntilEntered()

        let waiter = Task {
            try await limiter.withPermit { await probe.recordWork() }
        }
        // 给 waiter 一个进入等待队列的窗口
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        // waiter 结束后其取消必然已被处理（无论已入队还是预取消）
        _ = try? await waiter.value
        // 取消处理完毕才放行 holder，杜绝 holder 先释放许可导致的移交竞态
        await releaseHolder.markEntered()
        _ = try? await holder.value

        #expect(await probe.maximumConcurrent == 0)
    }
}
