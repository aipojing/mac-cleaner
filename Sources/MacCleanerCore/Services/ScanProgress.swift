import Foundation
import os

/// 全局扫描进度，DiskScanner 在 fts 遍历时更新，UI 层读取展示
public final class ScanProgress: Sendable {
    public static let shared = ScanProgress()

    private let _path = OSAllocatedUnfairLock(initialState: "")
    // 使用原子操作替代锁，每次 fts_read 仅做一次原子加法
    private let _counter = ManagedAtomic<Int>(0)

    private init() {}

    public var currentPath: String {
        _path.withLock { $0 }
    }

    /// 由 DiskScanner 在 fts 遍历中调用
    /// 使用原子递增避免锁，每 200 个文件才更新路径字符串
    public func report(path: String) {
        let count = _counter.wrappingIncrementThenLoad(ordering: .relaxed)
        if count % 200 == 0 {
            _path.withLock { $0 = path }
        }
    }

    public func reset() {
        _path.withLock { $0 = "" }
        _counter.store(0, ordering: .relaxed)
    }
}

/// 最小化的无锁原子 Int，基于 OSAtomicIncrement64
/// 避免引入 swift-atomics 外部依赖
public final class ManagedAtomic<T>: @unchecked Sendable where T == Int {
    private let storage: UnsafeMutablePointer<Int64>

    public init(_ value: Int) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: Int64(value))
    }

    deinit {
        storage.deallocate()
    }

    public enum Ordering {
        case relaxed
    }

    /// 原子递增并返回新值
    public func wrappingIncrementThenLoad(ordering: Ordering) -> Int {
        Int(OSAtomicIncrement64(storage))
    }

    /// 原子存储
    public func store(_ value: Int, ordering: Ordering) {
        storage.pointee = Int64(value)
    }
}
