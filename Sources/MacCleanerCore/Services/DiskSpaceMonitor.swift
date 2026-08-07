import Foundation

public actor DiskSpaceMonitor {
    public static let shared = DiskSpaceMonitor()

    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<DiskSpaceInfo>.Continuation?
    private let spaceProvider: @Sendable () throws -> DiskSpaceInfo

    public private(set) var current: DiskSpaceInfo?

    public init(spaceProvider: @escaping @Sendable () throws -> DiskSpaceInfo = DiskSpaceInfo.current) {
        self.spaceProvider = spaceProvider
    }

    public var updates: AsyncStream<DiskSpaceInfo> {
        AsyncStream { continuation in
            self.continuation = continuation
            // 立即发送当前值
            if let current {
                continuation.yield(current)
            }
        }
    }

    public func start(interval: TimeInterval = 300) {
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
            let info = try spaceProvider()
            current = info
            continuation?.yield(info)
        } catch {
            // 静默失败，下次重试
        }
    }
}
