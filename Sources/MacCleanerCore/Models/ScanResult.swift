import Foundation

public struct ScanResult: Sendable {
    public let module: ModuleIdentifier
    public let items: [CleanableItem]
    public let scanDuration: TimeInterval

    public init(module: ModuleIdentifier, items: [CleanableItem], scanDuration: TimeInterval = 0) {
        self.module = module
        self.items = items
        self.scanDuration = scanDuration
    }

    /// 全部过滤后候选的物理占用：按 (device, inode) 去重，
    /// 同一硬链接对象只计一次；无身份条目逐项计入。
    public var totalSize: Int64 {
        PhysicalSizeCalculator.uniqueAllocatedBytes(in: items)
    }
}
