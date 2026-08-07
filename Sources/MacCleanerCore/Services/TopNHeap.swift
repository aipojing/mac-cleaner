import Foundation

/// 固定容量最小堆：流式保留评分最高的 N 个元素。
///
/// 常驻存储不超过 capacity，插入复杂度 O(log N)，整体为
/// O(元素数 × log N)。评分相同按 tieBreak 字典序升序排名（小的排前面），
/// 保证输出顺序稳定，与枚举顺序无关。
public struct TopNHeap<Element> {
    public let capacity: Int
    private let score: (Element) -> Int64
    private let tieBreak: (Element) -> String

    private var storage: [Element] = []
    /// 历史上同时保留的候选峰值，用于验证常驻候选不超过 N。
    public private(set) var maximumObservedCount = 0

    public init(
        capacity: Int,
        score: @escaping (Element) -> Int64,
        tieBreak: @escaping (Element) -> String = { _ in "" }
    ) {
        self.capacity = max(0, capacity)
        self.score = score
        self.tieBreak = tieBreak
    }

    public var count: Int { storage.count }

    /// a 排名高于 b：分数更高，或同分时 tieBreak 字典序更小。
    private func ranksBefore(_ a: Element, _ b: Element) -> Bool {
        let sa = score(a)
        let sb = score(b)
        if sa != sb { return sa > sb }
        return tieBreak(a) < tieBreak(b)
    }

    public mutating func insert(_ element: Element) {
        guard capacity > 0 else { return }
        if storage.count < capacity {
            storage.append(element)
            siftUp(from: storage.count - 1)
            maximumObservedCount = max(maximumObservedCount, storage.count)
        } else if ranksBefore(element, storage[0]) {
            // 堆顶是当前保留集中排名最低的；新元素更好则替换
            storage[0] = element
            siftDown(from: 0)
        }
    }

    /// 按排名从高到低输出。
    public func sortedDescending() -> [Element] {
        storage.sorted { ranksBefore($0, $1) }
    }

    // MARK: - 堆维护（堆顶为排名最低的元素）

    private mutating func siftUp(from index: Int) {
        var child = index
        var parent = (child - 1) / 2
        // 父节点排名应低于（不优于）子节点：若子节点比父节点“更差”，上浮
        while child > 0 && ranksBefore(storage[parent], storage[child]) {
            storage.swapAt(parent, child)
            child = parent
            parent = (child - 1) / 2
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = parent * 2 + 2
            var worst = parent
            if left < storage.count && ranksBefore(storage[worst], storage[left]) {
                worst = left
            }
            if right < storage.count && ranksBefore(storage[worst], storage[right]) {
                worst = right
            }
            guard worst != parent else { return }
            storage.swapAt(parent, worst)
            parent = worst
        }
    }
}
