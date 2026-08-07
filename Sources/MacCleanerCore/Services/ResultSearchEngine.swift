import Foundation

/// 带权搜索、筛选和可操作性排序：纯函数，不访问网络、不改变选择状态。
///
/// 每个 token 取最佳字段分数后累加，所有 token 都必须命中：
/// - basename 精确 1000 / 前缀 750 / 包含 500
/// - tag / bundle ID 包含 350
/// - path 组件包含 200
/// - AI summary/explanation/evidence 文本包含 100
///
/// 分数相同按显式 sort mode 处理；风险与建议是两个独立筛选字段。
public struct ResultSearchEngine: Sendable {
    // 固定权重（产品约定，不得更改）
    static let basenameExactScore = 1000
    static let basenamePrefixScore = 750
    static let basenameContainsScore = 500
    static let tagOrBundleScore = 350
    static let pathComponentScore = 200
    static let aiTextScore = 100

    private let documents: [SearchDocument]

    public init(documents: [SearchDocument]) {
        self.documents = documents
    }

    public func search(_ query: ResultSearchQuery) -> [SearchDocument] {
        let tokens = SearchTextNormalizer.tokens(for: query.text)

        var scored: [(document: SearchDocument, score: Int)] = []
        scored.reserveCapacity(documents.count)

        for document in documents {
            guard passesFilters(document, query: query) else { continue }
            var total = 0
            var allHit = true
            for token in tokens {
                let score = Self.bestFieldScore(of: document, token: token)
                if score == 0 {
                    allHit = false
                    break
                }
                total += score
            }
            guard allHit else { continue }
            scored.append((document, total))
        }

        return sorted(scored, mode: query.sortMode).map(\.document)
    }

    // MARK: - 字段评分

    static func bestFieldScore(of document: SearchDocument, token: String) -> Int {
        let basename = document.normalizedBasename
        if basename == token { return basenameExactScore }
        if basename.hasPrefix(token) { return basenamePrefixScore }
        if basename.contains(token) { return basenameContainsScore }

        if document.normalizedTags.contains(where: { $0.contains(token) }) {
            return tagOrBundleScore
        }
        if let bundleID = document.normalizedBundleIdentifier, bundleID.contains(token) {
            return tagOrBundleScore
        }
        if document.normalizedPathComponents.contains(where: { $0.contains(token) }) {
            return pathComponentScore
        }
        if let aiText = document.normalizedAIText, aiText.contains(token) {
            return aiTextScore
        }
        return 0
    }

    // MARK: - 筛选

    private func passesFilters(_ document: SearchDocument, query: ResultSearchQuery) -> Bool {
        if !query.modules.isEmpty {
            guard let module = document.module, query.modules.contains(module) else { return false }
        }
        if !query.risks.isEmpty {
            guard let risk = document.risk, query.risks.contains(risk) else { return false }
        }
        if !query.recommendations.isEmpty {
            guard let recommendation = document.recommendation,
                  query.recommendations.contains(recommendation) else { return false }
        }
        if !query.assessmentStatuses.isEmpty {
            guard query.assessmentStatuses.contains(document.assessmentStatus) else { return false }
        }
        if let minimum = query.minimumAllocatedSize {
            guard document.allocatedSize >= minimum else { return false }
        }
        return true
    }

    // MARK: - 排序

    private func sorted(
        _ scored: [(document: SearchDocument, score: Int)],
        mode: ResultSortMode
    ) -> [(document: SearchDocument, score: Int)] {
        scored.sorted { lhs, rhs in
            switch mode {
            case .relevance:
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return relevanceTieBreak(lhs.document, rhs.document)
            case .actionability:
                let lr = Self.recommendationRank(lhs.document.recommendation)
                let rr = Self.recommendationRank(rhs.document.recommendation)
                if lr != rr { return lr > rr }
                let lk = Self.riskRank(lhs.document.risk)
                let rk = Self.riskRank(rhs.document.risk)
                if lk != rk { return lk > rk }
                return relevanceTieBreak(lhs.document, rhs.document)
            case .size:
                if lhs.document.allocatedSize != rhs.document.allocatedSize {
                    return lhs.document.allocatedSize > rhs.document.allocatedSize
                }
                return stableTieBreak(lhs.document, rhs.document)
            }
        }
    }

    private func relevanceTieBreak(_ lhs: SearchDocument, _ rhs: SearchDocument) -> Bool {
        let lc = Self.confidenceRank(lhs.confidence)
        let rc = Self.confidenceRank(rhs.confidence)
        if lc != rc { return lc > rc }
        if lhs.allocatedSize != rhs.allocatedSize {
            return lhs.allocatedSize > rhs.allocatedSize
        }
        return stableTieBreak(lhs, rhs)
    }

    private func stableTieBreak(_ lhs: SearchDocument, _ rhs: SearchDocument) -> Bool {
        if lhs.basename != rhs.basename { return lhs.basename < rhs.basename }
        return lhs.id < rhs.id
    }

    static func confidenceRank(_ confidence: AIConfidence?) -> Int {
        switch confidence {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case nil: return 0
        }
    }

    /// delete > inspect > keep > unknown > 无结果
    static func recommendationRank(_ recommendation: AIRecommendation?) -> Int {
        switch recommendation {
        case .delete: return 5
        case .inspect: return 4
        case .keep: return 3
        case .unknown: return 2
        case nil: return 0
        }
    }

    /// low > medium > high > critical > unknown > 无结果
    static func riskRank(_ risk: AIRiskLevel?) -> Int {
        switch risk {
        case .low: return 6
        case .medium: return 5
        case .high: return 4
        case .critical: return 3
        case .unknown: return 2
        case nil: return 0
        }
    }
}
