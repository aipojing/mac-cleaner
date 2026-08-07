import Foundation

/// 排除规则类型
public enum ExclusionType: String, Codable, Sendable {
    /// glob 路径模式匹配（如 "*/DerivedData/MyProject-*"）
    case pathPattern = "path_pattern"
    /// 最近 N 天内修改的文件不清理
    case recency = "recency"
    /// 低于指定大小（字节）不展示
    case minSize = "min_size"
    /// 永久保留标记（用户明确标记"不要删"的路径）
    case permanentKeep = "permanent_keep"
}

/// 单条排除规则
public struct ExclusionRule: Identifiable, Codable, Sendable {
    public let id: UUID
    public let type: ExclusionType
    /// 规则描述（用户可读）
    public let label: String
    /// 路径模式（pathPattern 和 permanentKeep 类型使用）
    public let pattern: String?
    /// 天数阈值（recency 类型使用）
    public let days: Int?
    /// 字节数阈值（minSize 类型使用）
    public let minBytes: Int64?
    /// 适用的模块（nil 表示所有模块）
    public let modules: [String]?
    /// 是否启用
    public let enabled: Bool
    /// 创建时间
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        type: ExclusionType,
        label: String,
        pattern: String? = nil,
        days: Int? = nil,
        minBytes: Int64? = nil,
        modules: [String]? = nil,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.pattern = pattern
        self.days = days
        self.minBytes = minBytes
        self.modules = modules
        self.enabled = enabled
        self.createdAt = createdAt
    }

    /// 创建路径模式排除规则
    public static func pathExclusion(pattern: String, label: String, modules: [String]? = nil) -> ExclusionRule {
        ExclusionRule(type: .pathPattern, label: label, pattern: pattern, modules: modules)
    }

    /// 创建最近 N 天排除规则
    public static func recencyExclusion(days: Int, label: String, modules: [String]? = nil) -> ExclusionRule {
        ExclusionRule(type: .recency, label: label, days: days, modules: modules)
    }

    /// 创建最小大小排除规则
    public static func minSizeExclusion(bytes: Int64, label: String, modules: [String]? = nil) -> ExclusionRule {
        ExclusionRule(type: .minSize, label: label, minBytes: bytes, modules: modules)
    }

    /// 创建永久保留规则
    public static func permanentKeep(path: String, label: String) -> ExclusionRule {
        ExclusionRule(type: .permanentKeep, label: label, pattern: path)
    }

    /// 返回禁用后的新副本
    public func disabled() -> ExclusionRule {
        ExclusionRule(
            id: id, type: type, label: label,
            pattern: pattern, days: days, minBytes: minBytes,
            modules: modules, enabled: false, createdAt: createdAt
        )
    }

    /// 返回启用后的新副本
    public func withEnabled(_ enabled: Bool) -> ExclusionRule {
        ExclusionRule(
            id: id, type: type, label: label,
            pattern: pattern, days: days, minBytes: minBytes,
            modules: modules, enabled: enabled, createdAt: createdAt
        )
    }
}

/// 排除规则集合配置
public struct ExclusionConfig: Codable, Sendable {
    public var rules: [ExclusionRule]
    public let version: Int

    public init(rules: [ExclusionRule] = [], version: Int = 1) {
        self.rules = rules
        self.version = version
    }

    public static let empty = ExclusionConfig()
}
