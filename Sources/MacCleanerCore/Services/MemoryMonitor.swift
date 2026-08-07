import Foundation

public actor MemoryMonitor {
    public static let shared = MemoryMonitor()

    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<MemoryInfo>.Continuation?
    private let statsProvider: @Sendable () throws -> MemoryInfo

    public private(set) var current: MemoryInfo?

    public init(statsProvider: @escaping @Sendable () throws -> MemoryInfo = MemoryInfo.current) {
        self.statsProvider = statsProvider
    }

    public var updates: AsyncStream<MemoryInfo> {
        AsyncStream { continuation in
            self.continuation = continuation
            if let current {
                continuation.yield(current)
            }
        }
    }

    public func start(interval: TimeInterval = 3) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func refresh() {
        do {
            let info = try statsProvider()
            current = info
            continuation?.yield(info)
        } catch {
            // 静默失败，下次重试
        }
    }
}
