import Foundation

/// 大文件扫描的实时快照：扫描进行中定期发布，最终以 `isFinal == true` 收尾。
///
/// 只通过 `ScanContext.onLargeFileUpdate` 传递，不进入最终 `ScanResult`，
/// 也不作为清理授权的数据源。
public struct LargeFileScanUpdate: Sendable {
    /// 当前按实际占用从大到小排列的临时 Top N 候选。
    public let items: [CleanableItem]
    /// 本次扫描至今满足阈值的文件总数（非仅显示数）。
    public let matchedFileCount: Int
    /// 满足阈值文件的累计实际占用；同一 (device, inode) 只计一次。
    public let matchedAllocatedSize: Int64
    /// 最后一次更新为 true。
    public let isFinal: Bool

    public init(
        items: [CleanableItem],
        matchedFileCount: Int,
        matchedAllocatedSize: Int64,
        isFinal: Bool
    ) {
        self.items = items
        self.matchedFileCount = matchedFileCount
        self.matchedAllocatedSize = matchedAllocatedSize
        self.isFinal = isFinal
    }
}
