import Foundation

/// 跨模块候选合并：消除同一路径和目录覆盖造成的重复。
///
/// 第一阶段按规范化路径合并：主 category 按 `ModuleIdentifier.allCases`
/// 固定优先级选择（与任务完成顺序无关），tags 和来源模块合并排序。
/// 第二阶段消除已被目录候选完整覆盖的子项（按路径组件边界判断）。
///
/// 不同路径即使 (device, inode) 相同也保留为不同可选项：
/// 选择一个路径时不能暗中删除另一个硬链接。符号链接保持自身身份，
/// 不与目标 inode 合并。
public struct CandidateMerger: Sendable {
    public init() {}

    public func merge(_ items: [CleanableItem]) -> [CleanableItem] {
        // 第一阶段：按规范化路径分组合并
        var order: [String] = []
        var groups: [String: [CleanableItem]] = [:]
        for item in items {
            let key = POSIXFileMetadataProvider.normalized(item.path)
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
            }
            groups[key]?.append(item)
        }

        var merged = order.compactMap { key -> CleanableItem? in
            guard let group = groups[key] else { return nil }
            return mergeGroup(group, normalizedPath: key)
        }

        // 第二阶段：删除被目录候选完整覆盖的后代项
        let directoryPaths = merged
            .filter { Self.isDirectoryCandidate($0) }
            .map(\.path)
        if !directoryPaths.isEmpty {
            merged.removeAll { item in
                directoryPaths.contains { dir in
                    dir != item.path && item.path.hasPrefix(dir + "/")
                }
            }
        }

        return merged
    }

    /// 目录候选判定：身份明确为目录，或身份缺失（虚拟对象/读取失败）。
    /// 身份缺失时按目录处理是保守方向：避免同一子树被父子候选重复计数。
    private static func isDirectoryCandidate(_ item: CleanableItem) -> Bool {
        guard let identity = item.fileIdentity else { return true }
        return identity.kind == .directory
    }

    private func mergeGroup(_ group: [CleanableItem], normalizedPath: String) -> CleanableItem {
        let primary = group.min { lhs, rhs in
            Self.priority(of: lhs.category) < Self.priority(of: rhs.category)
        } ?? group[0]

        let tags = CleanableItem.normalizedTags(group.flatMap(\.evidenceTags))
        let sources = CleanableItem.normalizedSourceModules(group.flatMap(\.sourceModules))
        let identity = group.first(where: { $0.fileIdentity != nil })?.fileIdentity

        return CleanableItem(
            id: primary.id,
            path: normalizedPath,
            displayName: primary.displayName,
            size: group.map(\.size).max() ?? primary.size,
            allocatedSize: group.map(\.allocatedSize).max() ?? primary.allocatedSize,
            category: primary.category,
            subcategory: primary.subcategory,
            evidenceTags: tags,
            fileIdentity: identity,
            linkCount: group.map(\.linkCount).max() ?? 1,
            sourceModules: sources
        )
    }

    /// 固定优先级：ModuleIdentifier 声明顺序（与 ModuleRegistry 顺序一致）。
    private static func priority(of module: ModuleIdentifier) -> Int {
        ModuleIdentifier.allCases.firstIndex(of: module) ?? 0
    }
}
