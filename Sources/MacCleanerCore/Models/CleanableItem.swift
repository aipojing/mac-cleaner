import Foundation

public struct CleanableItem: Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let displayName: String
    public let size: Int64
    /// 磁盘实际占用（st_blocks * 512）。默认等于 size；
    /// 物理空间统计与硬链接去重都以此为准。
    public let allocatedSize: Int64
    public let category: ModuleIdentifier
    public let subcategory: String?
    /// 原始事实标签：只描述对象是什么（cache、developer-tool、npm…），
    /// 不编码“安全”“危险”“推荐”“可删除”等判断。
    /// 初始化时去空、去重并按字典序固定，保证 AI 指纹稳定。
    public let evidenceTags: [String]
    /// 扫描时记录的文件对象身份（device/inode/类型）。
    /// nil 表示身份获取失败：可以展示，但执行删除时 guard 会拒绝。
    /// 虚拟对象（如模拟器 UDID 条目）没有文件系统身份，保持 nil。
    public let fileIdentity: FileIdentity?
    /// st_nlink：该 inode 的硬链接数量。用于估算实际可释放空间：
    /// 只有选中的已知路径数达到 linkCount，物理空间才真正释放。
    public let linkCount: UInt64
    /// 发现该候选的所有模块（按固定优先级排序）。主 category 是第一个元素；
    /// 跨模块重复路径合并后保留全部来源，供筛选和 AI evidence 使用。
    public let sourceModules: [ModuleIdentifier]

    /// 事实初始化器：扫描模块的唯一入口。只记录可验证事实，
    /// 不做风险或推荐判断。
    public init(
        path: String,
        displayName: String,
        size: Int64,
        category: ModuleIdentifier,
        subcategory: String? = nil,
        evidenceTags: [String] = [],
        fileIdentity: FileIdentity? = nil,
        allocatedSize: Int64? = nil,
        linkCount: UInt64 = 1,
        sourceModules: [ModuleIdentifier]? = nil
    ) {
        self.id = UUID()
        self.path = path
        self.displayName = displayName
        self.size = size
        self.allocatedSize = allocatedSize ?? size
        self.category = category
        self.subcategory = subcategory
        self.evidenceTags = Self.normalizedTags(evidenceTags)
        self.fileIdentity = fileIdentity
        self.linkCount = linkCount
        self.sourceModules = Self.normalizedSourceModules(sourceModules ?? [category])
    }

    /// 内部完整初始化器：复制或合并条目时保留同一 id。
    init(
        id: UUID,
        path: String,
        displayName: String,
        size: Int64,
        allocatedSize: Int64,
        category: ModuleIdentifier,
        subcategory: String?,
        evidenceTags: [String],
        fileIdentity: FileIdentity?,
        linkCount: UInt64,
        sourceModules: [ModuleIdentifier]
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.size = size
        self.allocatedSize = allocatedSize
        self.category = category
        self.subcategory = subcategory
        self.evidenceTags = evidenceTags
        self.fileIdentity = fileIdentity
        self.linkCount = linkCount
        self.sourceModules = sourceModules
    }

    /// 返回带指定身份的副本（同一 id）。
    public func withFileIdentity(_ identity: FileIdentity?) -> CleanableItem {
        CleanableItem(
            id: id,
            path: path,
            displayName: displayName,
            size: size,
            allocatedSize: allocatedSize,
            category: category,
            subcategory: subcategory,
            evidenceTags: evidenceTags,
            fileIdentity: identity,
            linkCount: linkCount,
            sourceModules: sourceModules
        )
    }

    /// 扫描阶段记录文件身份。已有身份时不重复读取；
    /// 读取失败（路径不存在、权限不足等）时返回 fileIdentity == nil 的副本，
    /// 可以展示，但删除 guard 会拒绝执行。
    public func recordingIdentity(via provider: any FileIdentityProviding) -> CleanableItem {
        guard fileIdentity == nil else { return self }
        let identity = try? provider.identity(at: path)
        return withFileIdentity(identity)
    }

    /// 经共享元数据索引记录身份：同一路径在索引生命周期内最多 lstat 一次。
    /// 语义与 `recordingIdentity(via: FileIdentityProviding)` 一致。
    public func recordingIdentity(via index: FileMetadataIndex) async -> CleanableItem {
        guard fileIdentity == nil else { return self }
        let identity = try? await index.metadata(at: path).identity
        return withFileIdentity(identity)
    }

    /// 标签规范化：去空白、去空、去重、按字典序固定。
    static func normalizedTags(_ tags: [String]) -> [String] {
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(cleaned)).sorted()
    }

    /// 来源模块规范化：去重并按 ModuleIdentifier 声明顺序固定，保证排序稳定。
    static func normalizedSourceModules(_ modules: [ModuleIdentifier]) -> [ModuleIdentifier] {
        let order = ModuleIdentifier.allCases
        return Array(Set(modules)).sorted { lhs, rhs in
            (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
        }
    }
}
