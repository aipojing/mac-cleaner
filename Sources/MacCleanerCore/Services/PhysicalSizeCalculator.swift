import Foundation

/// 物理空间统计：按 (device, inode) 去重，感知硬链接。
///
/// 展示和选择统计都必须通过这里，不再直接求和 item size，
/// 否则同一物理对象会被多个路径重复计数。
public enum PhysicalSizeCalculator {
    /// 所有候选的物理占用：同一 (device, inode) 只计一次；
    /// 无身份的条目（虚拟对象或读取失败）逐项计入。
    public static func uniqueAllocatedBytes(in items: [CleanableItem]) -> Int64 {
        var seen: Set<PhysicalObjectKey> = []
        var total: Int64 = 0
        for item in items {
            guard let identity = item.fileIdentity else {
                total += item.allocatedSize
                continue
            }
            let key = PhysicalObjectKey(device: identity.device, inode: identity.inode)
            if seen.insert(key).inserted {
                total += item.allocatedSize
            }
        }
        return total
    }

    /// 估算选中项实际可释放的空间。
    ///
    /// 普通对象选中即计入（同一 inode 只计一次）。常规文件硬链接
    /// （linkCount > 1）只有当选中的已知路径数量达到 linkCount 时才计入：
    /// 只要还有未选中的硬链接路径存在，删除部分路径不会释放物理空间，
    /// 此时计入 0 —— 展示侧应提示“实际释放取决于其他硬链接”。
    public static func estimatedReclaimableBytes(
        selected: [CleanableItem],
        allKnownItems: [CleanableItem]
    ) -> Int64 {
        estimatedReclaimableBytesByModule(
            selected: selected,
            allKnownItems: allKnownItems
        ).values.reduce(0, +)
    }

    /// 按模块拆分预计可释放空间，并保证所有模块小计之和等于全局总计。
    ///
    /// 同一物理对象跨模块出现时，只归属给 `ModuleIdentifier.allCases`
    /// 中优先级最高的已选模块，避免每个模块独立估算后重复计数或都显示 0。
    public static func estimatedReclaimableBytesByModule(
        selected: [CleanableItem],
        allKnownItems: [CleanableItem]
    ) -> [ModuleIdentifier: Int64] {
        var knownLinkCounts: [PhysicalObjectKey: UInt64] = [:]
        for item in allKnownItems {
            guard let identity = item.fileIdentity else { continue }
            let key = PhysicalObjectKey(device: identity.device, inode: identity.inode)
            knownLinkCounts[key] = max(knownLinkCounts[key] ?? 1, item.linkCount)
        }

        var unidentifiedByModule: [ModuleIdentifier: Int64] = [:]
        var selectedByObject: [PhysicalObjectKey: [CleanableItem]] = [:]
        for item in selected {
            guard let identity = item.fileIdentity else {
                unidentifiedByModule[item.category, default: 0] += item.allocatedSize
                continue
            }
            let key = PhysicalObjectKey(device: identity.device, inode: identity.inode)
            selectedByObject[key, default: []].append(item)
        }

        var result = unidentifiedByModule
        for (key, items) in selectedByObject {
            guard let representative = items.first else { continue }
            let requiredLinks = knownLinkCounts[key] ?? representative.linkCount
            let selectedPathCount = UInt64(Set(items.map(\.path)).count)
            if representative.fileIdentity?.kind == .regularFile,
               requiredLinks > 1,
               selectedPathCount < requiredLinks {
                continue
            }

            guard let owner = items.map(\.category).min(by: {
                modulePriority($0) < modulePriority($1)
            }) else { continue }
            let allocatedSize = items.map(\.allocatedSize).max() ?? 0
            result[owner, default: 0] += allocatedSize
        }
        return result
    }

    private static func modulePriority(_ module: ModuleIdentifier) -> Int {
        ModuleIdentifier.allCases.firstIndex(of: module) ?? ModuleIdentifier.allCases.count
    }
}

private struct PhysicalObjectKey: Hashable {
    let device: UInt64
    let inode: UInt64
}
