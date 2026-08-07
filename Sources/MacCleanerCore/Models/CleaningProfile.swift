import Foundation

/// 清理方案：预定义的模块组合。只筛选模块，不筛选条目——
/// 无 AI/本地判断时无法兑现“仅安全项”之类的条目级含义。
public struct CleaningProfile: Identifiable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    /// 包含的模块（nil 表示所有模块）
    public let moduleIDs: [String]?
    /// 是否为内置方案（不可删除）
    public let isBuiltIn: Bool
    /// 图标名称
    public let icon: String

    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        moduleIDs: [String]? = nil,
        isBuiltIn: Bool = false,
        icon: String = "doc.text"
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.moduleIDs = moduleIDs
        self.isBuiltIn = isBuiltIn
        self.icon = icon
    }

    /// 过滤模块列表
    public func filterModules(_ allModules: [ModuleIdentifier]) -> [ModuleIdentifier] {
        guard let ids = moduleIDs else { return allModules }
        let idSet = Set(ids)
        return allModules.filter { idSet.contains($0.rawValue) }
    }

    // MARK: - 内置方案

    /// 开发环境瘦身：所有开发相关缓存
    public static let devSlimDown = CleaningProfile(
        name: "开发环境瘦身",
        description: "扫描所有开发工具缓存、Xcode 产物和 Docker 数据候选",
        moduleIDs: ["dev-caches", "xcode", "simulators", "ai-caches", "docker"],
        isBuiltIn: true,
        icon: "hammer.fill"
    )

    /// 发版前清理：所有模块
    public static let preRelease = CleaningProfile(
        name: "发版前清理",
        description: "发布前扫描所有模块的候选占用空间",
        moduleIDs: nil,
        isBuiltIn: true,
        icon: "shippingbox.fill"
    )

    /// 日志清理：只扫描日志和诊断报告
    public static let logsOnly = CleaningProfile(
        name: "日志清理",
        description: "扫描系统日志、诊断报告和应用日志候选",
        moduleIDs: ["system-logs"],
        isBuiltIn: true,
        icon: "doc.plaintext"
    )

    /// 所有内置方案
    public static let builtInProfiles: [CleaningProfile] = [
        .devSlimDown, .preRelease, .logsOnly,
    ]
}
