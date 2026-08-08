import Foundation

/// 一次扫描的共享上下文：所有模块通过同一个 metadata index 和
/// 并发限制器访问文件系统，避免重复 lstat 和无界并发。
public struct ScanContext: Sendable {
    /// 单次扫描的文件元数据快照索引（同一路径最多读取一次）。
    public let metadataIndex: FileMetadataIndex
    /// 文件系统任务并发许可（目录枚举、大小统计等）。
    public let fileTaskLimiter: AsyncLimiter
    /// full hash 任务并发许可（默认 4，防止大文件 IO 打满磁盘）。
    public let hashTaskLimiter: AsyncLimiter
    /// 大文件扫描的实时快照处理器；nil 时不产生任何临时 UI 数据。
    public let onLargeFileUpdate: (@Sendable (LargeFileScanUpdate) -> Void)?

    /// 文件系统任务默认并发上限：min(max(activeProcessorCount, 2), 8)。
    public static var defaultFileTaskLimit: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8)
    }

    public static let defaultHashTaskLimit = 4

    /// 通过共享元数据索引记录文件身份：同一路径在一次扫描中
    /// 最多执行一次 lstat（跨模块去重由索引保证）。
    public func recordIdentities(of items: [CleanableItem]) async -> [CleanableItem] {
        var result: [CleanableItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            result.append(await item.recordingIdentity(via: metadataIndex))
        }
        return result
    }

    public init(
        metadataIndex: FileMetadataIndex = FileMetadataIndex(),
        fileTaskLimit: Int = ScanContext.defaultFileTaskLimit,
        hashTaskLimit: Int = ScanContext.defaultHashTaskLimit,
        onLargeFileUpdate: (@Sendable (LargeFileScanUpdate) -> Void)? = nil
    ) {
        self.metadataIndex = metadataIndex
        self.fileTaskLimiter = AsyncLimiter(limit: fileTaskLimit)
        self.hashTaskLimiter = AsyncLimiter(limit: hashTaskLimit)
        self.onLargeFileUpdate = onLargeFileUpdate
    }
}
