import Foundation
import Testing
@testable import MacCleanerCore

@Suite("Large file update publisher")
struct LargeFileUpdatePublisherTests {
    @Test("首项立即发布，间隔内更新合并，最终快照必定发布")
    func coalescesUpdatesAndAlwaysFinishes() {
        var now: TimeInterval = 100
        var delivered: [Int] = []
        var publisher = LargeFileUpdatePublisher<Int>(
            minimumInterval: 0.2,
            now: { now },
            deliver: { delivered.append($0) }
        )

        publisher.submit(1)
        now += 0.05; publisher.submit(2)
        now += 0.05; publisher.submit(3)
        now += 0.11; publisher.submit(4)
        publisher.finish(5)

        #expect(delivered == [1, 4, 5])
    }

    @Test("间隔到期后提交发送最新快照而非中间值")
    func sendsLatestAfterInterval() {
        var now: TimeInterval = 0
        var delivered: [Int] = []
        var publisher = LargeFileUpdatePublisher<Int>(
            minimumInterval: 0.2,
            now: { now },
            deliver: { delivered.append($0) }
        )

        publisher.submit(1)
        now += 0.05; publisher.submit(2)
        now += 0.2; publisher.submit(3)

        #expect(delivered == [1, 3])
    }
}
