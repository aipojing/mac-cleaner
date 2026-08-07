import Testing
import Foundation
@testable import MacCleanerCore

private struct FileCandidate {
    let path: String
    let allocatedSize: Int64

    static func fixture(path: String, allocatedSize: Int64) -> FileCandidate {
        FileCandidate(path: path, allocatedSize: allocatedSize)
    }
}

@Suite("Top N heap")
struct TopNHeapTests {
    @Test("始终只保留最大的 N 项")
    func keepsLargestValues() {
        var heap = TopNHeap<Int>(capacity: 3, score: { Int64($0) })
        [5, 1, 9, 3, 8, 2].forEach { heap.insert($0) }
        #expect(heap.count == 3)
        #expect(heap.sortedDescending() == [9, 8, 5])
        #expect(heap.maximumObservedCount == 3)
    }

    @Test("同大小按规范化路径排序保证稳定")
    func stableTieBreak() {
        var heap = TopNHeap<FileCandidate>(capacity: 2, score: \.allocatedSize, tieBreak: \.path)
        heap.insert(.fixture(path: "/b", allocatedSize: 10))
        heap.insert(.fixture(path: "/a", allocatedSize: 10))
        #expect(heap.sortedDescending().map(\.path) == ["/a", "/b"])
    }

    @Test("容量为 0 时丢弃全部输入")
    func zeroCapacityDropsEverything() {
        var heap = TopNHeap<Int>(capacity: 0, score: { Int64($0) })
        [1, 2, 3].forEach { heap.insert($0) }
        #expect(heap.count == 0)
        #expect(heap.sortedDescending().isEmpty)
        #expect(heap.maximumObservedCount == 0)
    }

    @Test("新元素小于堆顶时直接丢弃")
    func rejectsSmallerThanWorst() {
        var heap = TopNHeap<Int>(capacity: 2, score: { Int64($0) })
        [10, 20, 5, 1, 30].forEach { heap.insert($0) }
        #expect(heap.sortedDescending() == [30, 20])
    }

    @Test("输入少于容量时全部保留且峰值正确")
    func keepsAllWhenUnderCapacity() {
        var heap = TopNHeap<Int>(capacity: 10, score: { Int64($0) })
        [3, 1, 2].forEach { heap.insert($0) }
        #expect(heap.sortedDescending() == [3, 2, 1])
        #expect(heap.maximumObservedCount == 3)
    }
}
