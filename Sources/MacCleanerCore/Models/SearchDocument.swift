import Foundation

/// AI 分析状态（搜索筛选维度之一）。
public enum AssessmentStatus: String, CaseIterable, Sendable {
    case notConfigured, notAnalyzed, cached, loading, fresh, failed
}

/// 搜索结果排序模式。排序只用于展示，不推导选择或执行。
public enum ResultSortMode: String, CaseIterable, Sendable {
    case relevance, actionability, size
}

/// 搜索查询：文本 + 可组合筛选 + 排序。
public struct ResultSearchQuery: Sendable {
    public var text: String
    public var modules: Set<ModuleIdentifier>
    public var risks: Set<AIRiskLevel>
    public var recommendations: Set<AIRecommendation>
    public var assessmentStatuses: Set<AssessmentStatus>
    public var minimumAllocatedSize: Int64?
    public var sortMode: ResultSortMode

    public init(
        text: String,
        modules: Set<ModuleIdentifier> = [],
        risks: Set<AIRiskLevel> = [],
        recommendations: Set<AIRecommendation> = [],
        assessmentStatuses: Set<AssessmentStatus> = [],
        minimumAllocatedSize: Int64? = nil,
        sortMode: ResultSortMode = .relevance
    ) {
        self.text = text
        self.modules = modules
        self.risks = risks
        self.recommendations = recommendations
        self.assessmentStatuses = assessmentStatuses
        self.minimumAllocatedSize = minimumAllocatedSize
        self.sortMode = sortMode
    }
}

/// 预规范化搜索文档：构建一次，后续查询不再触碰文件系统。
///
/// 文档在扫描结果或 AI 状态变化时重建；搜索、排序、筛选和列表滚动
/// 都只读取内存中的事实和已有 AI 文本，不调用 DeepSeek。
public struct SearchDocument: Identifiable, Sendable {
    public let id: String
    public let basename: String
    public let path: String
    public let tags: [String]
    public let bundleIdentifier: String?
    public let aiText: String?
    public let module: ModuleIdentifier?
    public let allocatedSize: Int64
    public let risk: AIRiskLevel?
    public let recommendation: AIRecommendation?
    public let confidence: AIConfidence?
    public let assessmentStatus: AssessmentStatus

    // 规范化后的匹配字段（初始化时计算一次）
    let normalizedBasename: String
    let normalizedPathComponents: [String]
    let normalizedTags: [String]
    let normalizedBundleIdentifier: String?
    let normalizedAIText: String?

    public init(
        id: String,
        basename: String,
        path: String,
        tags: [String],
        bundleIdentifier: String?,
        aiText: String?,
        module: ModuleIdentifier?,
        allocatedSize: Int64,
        risk: AIRiskLevel?,
        recommendation: AIRecommendation?,
        confidence: AIConfidence?,
        assessmentStatus: AssessmentStatus
    ) {
        self.id = id
        self.basename = basename
        self.path = path
        self.tags = tags
        self.bundleIdentifier = bundleIdentifier
        self.aiText = aiText
        self.module = module
        self.allocatedSize = allocatedSize
        self.risk = risk
        self.recommendation = recommendation
        self.confidence = confidence
        self.assessmentStatus = assessmentStatus

        self.normalizedBasename = SearchTextNormalizer.normalize(basename)
        self.normalizedPathComponents = path
            .split(separator: "/")
            .map { SearchTextNormalizer.normalize(String($0)) }
        self.normalizedTags = tags.map { SearchTextNormalizer.normalize($0) }
        self.normalizedBundleIdentifier = bundleIdentifier.map { SearchTextNormalizer.normalize($0) }
        self.normalizedAIText = aiText.map { SearchTextNormalizer.normalize($0) }
    }
}

/// 文本规范化：兼容分解 + 全角折叠 + 变音符不敏感 + 大小写折叠。
/// 文档与查询走同一套规范化，保证中文、全角和大小写都可搜索。
public enum SearchTextNormalizer {
    public static func normalize(_ text: String) -> String {
        (text as NSString)
            .decomposedStringWithCompatibilityMapping
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                locale: nil
            )
    }

    /// 查询规范化一次后按空白拆 token。
    public static func tokens(for query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }
}

extension AssessmentStatus {
    /// 由 AI 状态映射搜索筛选维度；nil（尚无状态）视为未分析。
    public init(_ state: AIAssessmentState?) {
        switch state {
        case .notConfigured: self = .notConfigured
        case .notAnalyzed, .none: self = .notAnalyzed
        case .cached: self = .cached
        case .loading: self = .loading
        case .fresh: self = .fresh
        case .failed: self = .failed
        }
    }
}
