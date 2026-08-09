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
    /// 记录身份时同步捕获的内容指纹：lstat 的 st_mtimespec（纳秒）。
    /// 不参与 FileIdentity 判等（硬链接去重不受影响）；仅供删除前的
    /// 内容漂移检测。nil 表示未捕获（旧构造点或读取失败），漂移检测跳过。
    public let recordedModificationNanoseconds: Int64?
    /// 记录身份时同步捕获的 lstat st_size（逻辑大小），用途同上。
    public let recordedContentSize: Int64?

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
        sourceModules: [ModuleIdentifier]? = nil,
        recordedModificationNanoseconds: Int64? = nil,
        recordedContentSize: Int64? = nil
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
        self.recordedModificationNanoseconds = recordedModificationNanoseconds
        self.recordedContentSize = recordedContentSize
    }

    /// 内部完整初始化器：复制或合并条目时保留同一 id。
    /// 内容指纹字段给默认值以保持既有调用点（如 CandidateMerger）兼容；
    /// 合并条目未传递时指纹为 nil，漂移检测对该条目跳过。
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
        sourceModules: [ModuleIdentifier],
        recordedModificationNanoseconds: Int64? = nil,
        recordedContentSize: Int64? = nil
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
        self.recordedModificationNanoseconds = recordedModificationNanoseconds
        self.recordedContentSize = recordedContentSize
    }

    /// 返回带指定身份的副本（同一 id），保留已有内容指纹。
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
            sourceModules: sourceModules,
            recordedModificationNanoseconds: recordedModificationNanoseconds,
            recordedContentSize: recordedContentSize
        )
    }

    /// 返回带指定身份与内容指纹的副本（同一 id）。
    private func withRecordedSnapshot(
        identity: FileIdentity?,
        modificationNanoseconds: Int64?,
        contentSize: Int64?
    ) -> CleanableItem {
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
            sourceModules: sourceModules,
            recordedModificationNanoseconds: modificationNanoseconds,
            recordedContentSize: contentSize
        )
    }

    /// 扫描阶段记录文件身份，并同步捕获内容指纹（mtime 纳秒 + size）
    /// 供删除前的内容漂移检测。已有身份时不重复读取；
    /// 读取失败（路径不存在、权限不足等）时返回 fileIdentity == nil 的副本，
    /// 可以展示，但删除 guard 会拒绝执行。
    public func recordingIdentity(via provider: any FileIdentityProviding) -> CleanableItem {
        guard fileIdentity == nil else { return self }
        guard let identity = try? provider.identity(at: path) else {
            return withRecordedSnapshot(identity: nil, modificationNanoseconds: nil, contentSize: nil)
        }
        // 该协议只提供身份；指纹经 POSIX lstat 尽力捕获，失败保持 nil
        // （测试桩的虚拟路径不影响确定性，漂移检测会跳过该条目）。
        let metadata = try? POSIXFileMetadataProvider().metadataSync(
            at: POSIXFileMetadataProvider.normalized(path)
        )
        return withRecordedSnapshot(
            identity: identity,
            modificationNanoseconds: metadata?.modificationTimeNanoseconds,
            contentSize: metadata?.logicalSize
        )
    }

    /// 经共享元数据索引记录身份与内容指纹：同一路径在索引生命周期内最多
    /// lstat 一次。语义与 `recordingIdentity(via: FileIdentityProviding)` 一致。
    public func recordingIdentity(via index: FileMetadataIndex) async -> CleanableItem {
        guard fileIdentity == nil else { return self }
        guard let metadata = try? await index.metadata(at: path) else {
            return withRecordedSnapshot(identity: nil, modificationNanoseconds: nil, contentSize: nil)
        }
        return withRecordedSnapshot(
            identity: metadata.identity,
            modificationNanoseconds: metadata.modificationTimeNanoseconds,
            contentSize: metadata.logicalSize
        )
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
