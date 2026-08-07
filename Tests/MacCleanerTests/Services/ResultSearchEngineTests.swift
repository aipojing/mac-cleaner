import Testing
import Foundation
@testable import MacCleanerCore

extension SearchDocument {
    /// 测试构造：默认路径不含查询词，各字段独立指定。
    static func fixture(
        id: String,
        basename: String? = nil,
        path: String? = nil,
        tags: [String] = [],
        bundleIdentifier: String? = nil,
        aiText: String? = nil,
        module: ModuleIdentifier? = nil,
        allocatedSize: Int64 = 0,
        risk: AIRiskLevel? = nil,
        recommendation: AIRecommendation? = nil,
        confidence: AIConfidence? = nil,
        assessmentStatus: AssessmentStatus = .notAnalyzed
    ) -> SearchDocument {
        SearchDocument(
            id: id,
            basename: basename ?? id,
            path: path ?? "/tmp/\(id)",
            tags: tags,
            bundleIdentifier: bundleIdentifier,
            aiText: aiText,
            module: module,
            allocatedSize: allocatedSize,
            risk: risk,
            recommendation: recommendation,
            confidence: confidence,
            assessmentStatus: assessmentStatus
        )
    }
}

@Suite("Result search engine")
struct ResultSearchEngineTests {
    @Test("basename 精确匹配排在路径和 AI 文本匹配之前")
    func appliesFieldWeights() {
        let engine = ResultSearchEngine(documents: [
            .fixture(id: "exact", basename: "npm"),
            .fixture(id: "path", path: "/Caches/npm/data"),
            .fixture(id: "ai", aiText: "npm 缓存"),
        ])
        #expect(engine.search(.init(text: "npm")).map(\.id) == ["exact", "path", "ai"])
    }

    @Test("中文、大小写和宽字符规范化后可搜索")
    func normalizesText() {
        let engine = ResultSearchEngine(documents: [
            .fixture(id: "one", basename: "Ｃａｃｈｅ", tags: ["开发工具缓存"]),
        ])
        #expect(engine.search(.init(text: "cache")).map(\.id) == ["one"])
        #expect(engine.search(.init(text: "开发 缓存")).map(\.id) == ["one"])
    }

    @Test("无 AI 结果仍可按事实搜索")
    func worksWithoutAssessment() {
        let engine = ResultSearchEngine(documents: [.fixture(id: "one", path: "/tmp/cache", aiText: nil)])
        #expect(engine.search(.init(text: "cache")).count == 1)
    }

    @Test("所有 token 都必须命中")
    func allTokensMustMatch() {
        let engine = ResultSearchEngine(documents: [
            .fixture(id: "both", basename: "npm", tags: ["缓存"]),
            .fixture(id: "partial", basename: "npm"),
        ])
        #expect(engine.search(.init(text: "npm 缓存")).map(\.id) == ["both"])
    }

    @Test("风险、建议、分析状态、模块和最小大小可组合筛选")
    func combinesFilters() {
        let query = ResultSearchQuery(
            text: "",
            modules: [.xcode],
            risks: [.low],
            recommendations: [.delete],
            assessmentStatuses: [.cached, .fresh],
            minimumAllocatedSize: 1_000
        )
        let matching = SearchDocument.fixture(
            id: "matching", module: .xcode, allocatedSize: 2_000,
            risk: .low, recommendation: .delete, assessmentStatus: .cached
        )
        let nonMatching = SearchDocument.fixture(
            id: "nonMatching", module: .xcode, allocatedSize: 50,
            risk: .high, recommendation: .keep, assessmentStatus: .notAnalyzed
        )
        let result = ResultSearchEngine(documents: [matching, nonMatching]).search(query)
        #expect(result.map(\.id) == ["matching"])
    }

    @Test("可操作性排序：delete+low 排在 keep+high 之前")
    func actionabilitySort() {
        let engine = ResultSearchEngine(documents: [
            .fixture(id: "keep-high", risk: .high, recommendation: .keep),
            .fixture(id: "delete-low", risk: .low, recommendation: .delete),
            .fixture(id: "inspect-medium", risk: .medium, recommendation: .inspect),
            .fixture(id: "unknown"),
        ])
        let result = engine.search(.init(text: "", sortMode: .actionability))
        #expect(result.map(\.id) == ["delete-low", "inspect-medium", "keep-high", "unknown"])
    }

    @Test("大小排序按实际占用降序")
    func sizeSort() {
        let engine = ResultSearchEngine(documents: [
            .fixture(id: "small", allocatedSize: 100),
            .fixture(id: "large", allocatedSize: 10_000),
            .fixture(id: "medium", allocatedSize: 1_000),
        ])
        let result = engine.search(.init(text: "", sortMode: .size))
        #expect(result.map(\.id) == ["large", "medium", "small"])
    }

    @Test("重复运行结果顺序一致")
    func stableOrder() {
        let documents = (0..<100).map { index in
            SearchDocument.fixture(
                id: "doc\(index)",
                basename: "cache\(index % 7)",
                allocatedSize: Int64((index * 7919) % 5000)
            )
        }
        let engine = ResultSearchEngine(documents: documents)
        let first = engine.search(.init(text: "cache")).map(\.id)
        let second = engine.search(.init(text: "cache")).map(\.id)
        #expect(first == second)
        #expect(!first.isEmpty)
    }
}
