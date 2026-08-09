import Foundation

/// 递归遍历类扫描共用的目录排除集合。
///
/// `.git`/`node_modules`/`Pods` 等目录内容体积大且由版本控制或包管理器
/// 自管理：`.git/objects/pack/*.pack` 在 repack 后常超 100MB，一旦被当作
/// 普通“大文件/重复文件”候选删除会直接损坏仓库。所有 fts 递归扫描
/// （大文件、重复文件等）统一使用这里的集合，避免各模块排除策略漂移。
public enum ScanTraversalExclusions {
    /// 版本控制与依赖目录：删除其中任何文件都会损坏仓库或工程。
    public static let repositoryDirectories: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", "Pods", "Carthage",
    ]

    /// 工具链缓存目录：由包管理器自管理，可重建但不作为普通候选展示。
    public static let toolchainCacheDirectories: Set<String> = [
        ".gradle", ".m2", ".npm", ".cocoapods", ".pub-cache", ".cargo",
    ]

    /// 递归扫描共用的完整排除集合。
    public static let common: Set<String> =
        repositoryDirectories.union(toolchainCacheDirectories)
}
