import Foundation
import MacCleanerCore

@Observable
@MainActor
final class ResultsViewModel {
    static let analysisBatchSize = 10

    let results: [ScanResult]
    var selectedItemIDs: Set<UUID>
    var selectedModuleID: ModuleIdentifier?

    // MARK: - 搜索与筛选（纯本地：不调用 AI，不改变选择状态）

    var searchText: String = "" {
        didSet { scheduleSearchUpdate() }
    }
    var selectedModules: Set<ModuleIdentifier> = [] {
        didSet { scheduleSearchUpdate() }
    }
    var selectedRisks: Set<AIRiskLevel> = [] {
        didSet { scheduleSearchUpdate() }
    }
    var selectedRecommendations: Set<AIRecommendation> = [] {
        didSet { scheduleSearchUpdate() }
    }
    var selectedAssessmentStatuses: Set<AssessmentStatus> = [] {
        didSet { scheduleSearchUpdate() }
    }
    var minimumAllocatedSize: Int64? = nil {
        didSet { scheduleSearchUpdate() }
    }
    var sortMode: ResultSortMode = .relevance {
        didSet { scheduleSearchUpdate() }
    }
    /// 搜索 + 筛选 + 排序后的可见条目。搜索未激活时等于全部条目。
    private(set) var visibleItems: [CleanableItem] = []
    private var searchTask: Task<Void, Never>?

    /// 搜索或任意筛选处于激活状态。
    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || !selectedModules.isEmpty
            || !selectedRisks.isEmpty
            || !selectedRecommendations.isEmpty
            || !selectedAssessmentStatuses.isEmpty
            || minimumAllocatedSize != nil
    }

    // MARK: - AI 状态（独立于选择状态，永不修改 selectedItemIDs）

    /// 按条目索引的 AI 判断状态。缓存命中自动展示但不联网；
    /// 缓存缺失显示“未分析”，只有用户显式点击才请求。
    var assessmentStates: [UUID: AIAssessmentState] = [:]
    var isBatchAnalyzing = false
    private(set) var batchAnalyzingItemIDs: Set<UUID> = []

    private let aiService: any AIAnalysisServing
    private let subjectFactory: AIAssessmentSubjectFactory
    private var analysisGeneration: UInt64 = 0

    init(
        results: [ScanResult],
        aiService: any AIAnalysisServing,
        subjectFactory: AIAssessmentSubjectFactory = AIAssessmentSubjectFactory()
    ) {
        self.results = results
        self.aiService = aiService
        self.subjectFactory = subjectFactory
        // 产品原则：所有扫描结果默认不选中，只有用户主动操作才改变选择状态。
        self.selectedItemIDs = CleanupSelectionPolicy.initialSelection(
            from: results.flatMap(\.items)
        )
        self.selectedModuleID = results.first?.module
        self.visibleItems = results.flatMap(\.items)
    }

    var allItems: [CleanableItem] {
        results.flatMap(\.items)
    }

    var selectedItems: [CleanableItem] {
        allItems.filter { selectedItemIDs.contains($0.id) }
    }

    /// 选中项预计可释放的物理空间：按 (device, inode) 去重，
    /// 未集齐全部硬链接路径的对象不计入。
    var totalSelectedSize: Int64 {
        PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: selectedItems,
            allKnownItems: allItems
        )
    }

    /// 分组标题使用的已选空间。跨模块共享同一 inode 时，物理空间只归属
    /// 一个固定优先级模块，因此所有模块小计之和始终等于 totalSelectedSize。
    func selectedSize(for moduleID: ModuleIdentifier) -> Int64 {
        PhysicalSizeCalculator.estimatedReclaimableBytesByModule(
            selected: selectedItems,
            allKnownItems: allItems
        )[moduleID, default: 0]
    }

    var selectedCount: Int {
        selectedItemIDs.count
    }

    /// 全部候选的物理占用：硬链接按 inode 去重，跨模块重复路径已合并。
    var totalSize: Int64 {
        PhysicalSizeCalculator.uniqueAllocatedBytes(in: allItems)
    }

    var itemsForCurrentModule: [CleanableItem] {
        guard let moduleID = selectedModuleID else { return [] }
        return results.first { $0.module == moduleID }?.items ?? []
    }

    // MARK: - AI 加载与显式分析

    /// 未分析且可请求批量分析的条目数（缓存缺失 + 无旧结果的失败项）。
    var unanalyzedCount: Int {
        allItems.filter { item in
            switch assessmentStates[item.id] {
            case .notAnalyzed:
                return true
            case let .failed(_, previous):
                return previous == nil
            default:
                return false
            }
        }.count
    }

    /// 顶部批量动作本次实际提交的数量。限制为单个 DeepSeek 请求的
    /// 最大条目数，避免把整页候选一次性切成无反馈的加载状态。
    var nextAnalysisBatchCount: Int {
        min(unanalyzedCount, Self.analysisBatchSize)
    }

    func isPartOfBatchAnalysis(_ item: CleanableItem) -> Bool {
        batchAnalyzingItemIDs.contains(item.id)
    }

    /// 结果页出现后调用：只读本地缓存，绝不触发网络请求。
    func loadCachedAssessments() async {
        let pairs = subjectPairs(for: allItems)
        let states = await aiService.states(for: pairs.map(\.subject))
        for (item, subject) in pairs {
            if let state = states[subject.subjectID] {
                assessmentStates[item.id] = state
            } else {
                assessmentStates[item.id] = .notAnalyzed
            }
        }
        updateVisibleItems()
    }

    /// 用户点击单项“AI 分析”。缓存命中项不重复请求。
    func analyzeItem(_ item: CleanableItem) async {
        guard let subject = subject(for: item) else { return }
        assessmentStates[item.id] = .loading(previous: assessmentStates[item.id]?.assessment)
        updateVisibleItems()
        let states = await aiService.analyze([subject], forceRefresh: false)
        if let state = states[subject.subjectID] {
            assessmentStates[item.id] = state
        }
        updateVisibleItems()
    }

    /// 用户点击“AI 重新检查”：强制联网，失败保留旧结果。
    func reanalyzeItem(_ item: CleanableItem) async {
        guard let subject = subject(for: item) else { return }
        assessmentStates[item.id] = .loading(previous: assessmentStates[item.id]?.assessment)
        updateVisibleItems()
        let states = await aiService.analyze([subject], forceRefresh: true)
        if let state = states[subject.subjectID] {
            assessmentStates[item.id] = state
        }
        updateVisibleItems()
    }

    /// 用户点击批量按钮：每次最多分析下一批 10 个未判断项，
    /// 已有缓存不重查，批次外条目仍可单独分析。不改变任何选择状态。
    func analyzeMissingItems() async {
        guard !isBatchAnalyzing else { return }
        let targets = Array(allItems.filter { item in
            switch assessmentStates[item.id] {
            case .notAnalyzed:
                return true
            case let .failed(_, previous):
                return previous == nil
            default:
                return false
            }
        }.prefix(Self.analysisBatchSize))
        let pairs = subjectPairs(for: targets)
        guard !pairs.isEmpty else { return }

        let generationAtStart = analysisGeneration
        isBatchAnalyzing = true
        batchAnalyzingItemIDs = Set(pairs.map(\.item.id))
        for (item, _) in pairs {
            assessmentStates[item.id] = .loading(previous: assessmentStates[item.id]?.assessment)
        }
        updateVisibleItems()

        let states = await aiService.analyze(pairs.map(\.subject), forceRefresh: false)
        guard generationAtStart == analysisGeneration else { return }
        for (item, subject) in pairs {
            if let state = states[subject.subjectID] {
                assessmentStates[item.id] = state
            } else {
                assessmentStates[item.id] = .notAnalyzed
            }
        }
        isBatchAnalyzing = false
        batchAnalyzingItemIDs.removeAll()
        updateVisibleItems()
    }

    /// 用户取消批量分析：停止后续批次。
    func cancelAIAnalysis() async {
        analysisGeneration &+= 1
        isBatchAnalyzing = false
        batchAnalyzingItemIDs.removeAll()
        for (id, state) in assessmentStates {
            if case let .loading(previous) = state {
                assessmentStates[id] = previous.map { .cached($0) } ?? .notAnalyzed
            }
        }
        updateVisibleItems()
        await aiService.cancelCurrentAnalysis()
    }

    // MARK: - 本地可执行性（仅用于展示，执行时 guard 仍是最终裁决）

    /// 本地执行护栏的轻量预判：无扫描身份或符号链接目标
    /// 在执行时一定会被 guard 拒绝。AI 结论无权改变此结果。
    static func isLocallyExecutable(_ item: CleanableItem) -> Bool {
        guard let identity = item.fileIdentity else { return false }
        return identity.kind != .symbolicLink
    }

    // MARK: - 搜索引擎接入

    /// 测试入口：跳过 150ms debounce 立即重算可见条目。
    func updateSearchResultsImmediatelyForTesting() {
        searchTask?.cancel()
        updateVisibleItems()
    }

    /// 重置全部搜索与筛选条件；只清筛选，绝不清选择状态。
    func resetFilters() {
        searchTask?.cancel()
        searchText = ""
        selectedModules = []
        selectedRisks = []
        selectedRecommendations = []
        selectedAssessmentStatuses = []
        minimumAllocatedSize = nil
        sortMode = .relevance
        updateVisibleItems()
    }

    /// 输入 150ms debounce；新输入取消上次 search task。
    private func scheduleSearchUpdate() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.updateVisibleItems()
        }
    }

    /// 纯本地搜索：只读取内存中的事实和已有 AI 状态，
    /// 不调用 DeepSeek，不读取文件系统，不改变选择状态。
    private func updateVisibleItems() {
        let query = ResultSearchQuery(
            text: searchText,
            modules: selectedModules,
            risks: selectedRisks,
            recommendations: selectedRecommendations,
            assessmentStatuses: selectedAssessmentStatuses,
            minimumAllocatedSize: minimumAllocatedSize,
            sortMode: sortMode
        )
        let items = allItems
        let engine = ResultSearchEngine(documents: searchDocuments(for: items))
        let matched = engine.search(query)
        let byID = Dictionary(items.map { ($0.id.uuidString, $0) }) { first, _ in first }
        visibleItems = matched.compactMap { byID[$0.id] }
    }

    /// 由当前事实和已有 AI 状态构建搜索文档。AI 状态变化时重建。
    private func searchDocuments(for items: [CleanableItem]) -> [SearchDocument] {
        items.map { item in
            let assessment = assessmentStates[item.id]?.assessment
            return SearchDocument(
                id: item.id.uuidString,
                basename: (item.path as NSString).lastPathComponent,
                path: item.path,
                tags: item.evidenceTags + [item.displayName],
                bundleIdentifier: nil,
                aiText: assessment.map {
                    ([$0.summary, $0.explanation] + $0.evidence).joined(separator: " ")
                },
                module: item.category,
                allocatedSize: item.allocatedSize,
                risk: assessment?.risk,
                recommendation: assessment?.recommendation,
                confidence: assessment?.confidence,
                assessmentStatus: AssessmentStatus(assessmentStates[item.id])
            )
        }
    }

    // MARK: - 私有

    private func subject(for item: CleanableItem) -> AIAssessmentSubject? {
        try? subjectFactory.cleanupSubject(for: item)
    }

    private func subjectPairs(for items: [CleanableItem]) -> [(item: CleanableItem, subject: AIAssessmentSubject)] {
        items.compactMap { item in
            guard let subject = subject(for: item) else { return nil }
            return (item, subject)
        }
    }

    // MARK: - 选择操作

    func toggleModule(_ moduleID: ModuleIdentifier) {
        let items = results.first { $0.module == moduleID }?.items ?? []
        let allSelected = items.allSatisfy { selectedItemIDs.contains($0.id) }
        if allSelected {
            for item in items {
                selectedItemIDs.remove(item.id)
            }
        } else {
            for item in items {
                // 本地不可执行的项不自动全选
                if Self.isLocallyExecutable(item) {
                    selectedItemIDs.insert(item.id)
                }
            }
        }
    }

    func toggleItem(_ item: CleanableItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    /// 用户主动点击“全选可清理项”。只选择本地可执行性检查通过的项，
    /// 不依据 AI 结论或静态推荐。
    func selectAllEligible() {
        selectedItemIDs = CleanupSelectionPolicy.selectAll(
            from: allItems,
            isEligible: Self.isLocallyExecutable
        )
    }

    func deselectAll() {
        selectedItemIDs.removeAll()
    }

    func isSelected(_ item: CleanableItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }
}
