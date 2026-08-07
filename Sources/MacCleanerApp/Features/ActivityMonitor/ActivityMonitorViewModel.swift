import Foundation
import MacCleanerCore
import os.log

private let logger = Logger(subsystem: "com.maccleaner.app", category: "ActivityMonitor")

/// 进程列表获取边界：测试用预制列表替代真实 ps。
protocol ProcessListFetching: Sendable {
    func fetchAll() async throws -> [RunningProcess]
}

/// 进程终止的本地拒绝原因。AI 结论无权影响终止裁决。
enum ProcessTerminationError: Error, Equatable, Sendable {
    /// 本地 guard 判定进程受保护（PID 复用、自身/helper、非法 PID）。
    case protectedProcess
    /// 无法解析进程身份，不可终止。
    case identityUnavailable
    /// 信号发送失败（权限等）。
    case failed
}

/// 进程终止边界：拒绝时不得发送任何信号。
protocol ProcessTerminating: Sendable {
    func terminate(_ process: RunningProcess, force: Bool) async -> ProcessTerminationError?
}

extension ProcessFetcher: ProcessListFetching, ProcessTerminating {
    func terminate(_ process: RunningProcess, force: Bool) async -> ProcessTerminationError? {
        guard process.identity != nil else { return .identityUnavailable }
        let success = force ? await forceKill(process) : await terminate(process)
        return success ? nil : .protectedProcess
    }
}

@Observable
@MainActor
final class ActivityMonitorViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case monitoring
        case failed(String)
    }

    enum SortKey: String, CaseIterable {
        case memory = "内存"
        case cpu    = "CPU"
        case name   = "名称"
    }

    // MARK: - Published state

    var phase: Phase = .idle
    var processes: [RunningProcess] = []
    var searchText: String = "" {
        didSet { scheduleSearchUpdate() }
    }
    /// AI 分析状态 / 风险 / 建议筛选（只读已有状态，不触发分析）。
    var selectedAssessmentStatuses: Set<AssessmentStatus> = [] {
        didSet { scheduleSearchUpdate() }
    }
    var selectedRisks: Set<AIRiskLevel> = [] {
        didSet { scheduleSearchUpdate() }
    }
    var selectedRecommendations: Set<AIRecommendation> = [] {
        didSet { scheduleSearchUpdate() }
    }
    var sortKey: SortKey = .memory {
        didSet { scheduleSearchUpdate() }
    }
    var sortAscending: Bool = false {
        didSet { scheduleSearchUpdate() }
    }
    /// 搜索 + 筛选 + 排序后的可见进程。
    private(set) var filteredProcesses: [RunningProcess] = []
    private var searchTask: Task<Void, Never>?
    var selectedProcess: RunningProcess? = nil
    var showKillConfirm: Bool = false
    var pendingKillProcess: RunningProcess? = nil
    var pendingForceKill: Bool = false
    var lastError: String? = nil
    var terminationError: ProcessTerminationError? = nil

    // MARK: - AI 状态（按 fingerprint 索引，独立于进程列表刷新）

    /// 按进程 fingerprint 索引的 AI 判断状态。刷新只读取
    /// 首次出现的 fingerprint 的本地缓存，绝不自动联网。
    private(set) var assessmentStates: [String: AIAssessmentState] = [:]
    /// pid → fingerprint 映射，供 UI 按进程查状态。
    private var fingerprints: [Int32: String] = [:]
    private var subjects: [Int32: AIAssessmentSubject] = [:]
    var isBatchAnalyzing = false

    // MARK: - Private

    private let fetcher: any ProcessListFetching
    private let terminationService: any ProcessTerminating
    private let aiService: any AIAnalysisServing
    private let subjectFactory: AIAssessmentSubjectFactory
    private var refreshTask: Task<Void, Never>?

    init(
        fetcher: any ProcessListFetching = ProcessFetcher(),
        terminationService: (any ProcessTerminating)? = nil,
        aiService: any AIAnalysisServing,
        subjectFactory: AIAssessmentSubjectFactory = AIAssessmentSubjectFactory()
    ) {
        self.fetcher = fetcher
        self.terminationService = terminationService ?? ProcessFetcher()
        self.aiService = aiService
        self.subjectFactory = subjectFactory
    }

    // MARK: - Computed

    /// 搜索引擎接入：文本匹配覆盖名称、路径、用户、PID 和已有 AI 文本；
    /// AI 状态/风险/建议筛选只读取已有状态。纯本地，不调用 DeepSeek。
    private func updateFilteredProcesses() {
        let query = ResultSearchQuery(
            text: searchText,
            risks: selectedRisks,
            recommendations: selectedRecommendations,
            assessmentStatuses: selectedAssessmentStatuses,
            sortMode: .relevance
        )
        let engine = ResultSearchEngine(documents: searchDocuments(for: processes))
        let matched = engine.search(query)
        let byPID = Dictionary(processes.map { ($0.id, $0) }) { first, _ in first }
        var result = matched.compactMap { Int32($0.id) }.compactMap { byPID[$0] }

        // 排序：CPU / 内存 / 名称（保持既有行为）
        result.sort { a, b in
            let cmp: Bool
            switch sortKey {
            case .memory: cmp = a.residentMemoryBytes > b.residentMemoryBytes
            case .cpu:    cmp = a.cpuPercent > b.cpuPercent
            case .name:   cmp = a.name.localizedCompare(b.name) == .orderedAscending
            }
            return sortAscending ? !cmp : cmp
        }

        filteredProcesses = result
    }

    /// 由进程事实和已有 AI 状态构建搜索文档。
    private func searchDocuments(for processes: [RunningProcess]) -> [SearchDocument] {
        processes.map { process in
            let assessment = assessmentState(for: process)?.assessment
            return SearchDocument(
                id: String(process.id),
                basename: process.name,
                path: process.path,
                tags: [process.user, String(process.id)],
                bundleIdentifier: process.identity?.bundleIdentifier,
                aiText: assessment.map {
                    ([$0.summary, $0.explanation] + $0.evidence).joined(separator: " ")
                },
                module: nil,
                allocatedSize: Int64(process.residentMemoryBytes),
                risk: assessment?.risk,
                recommendation: assessment?.recommendation,
                confidence: assessment?.confidence,
                assessmentStatus: AssessmentStatus(assessmentState(for: process))
            )
        }
    }

    /// 测试入口：跳过 150ms debounce 立即重算可见进程。
    func updateSearchResultsImmediatelyForTesting() {
        searchTask?.cancel()
        updateFilteredProcesses()
    }

    /// 输入 150ms debounce；新输入取消上次 search task。
    private func scheduleSearchUpdate() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.updateFilteredProcesses()
        }
    }

    var totalMemoryUsage: UInt64 {
        filteredProcesses.reduce(0) { $0 + $1.residentMemoryBytes }
    }

    var processCount: Int {
        filteredProcesses.count
    }

    var isFiltered: Bool {
        !searchText.isEmpty
            || !selectedAssessmentStatuses.isEmpty
            || !selectedRisks.isEmpty
            || !selectedRecommendations.isEmpty
    }

    var totalProcessCount: Int {
        processes.count
    }

    /// 未分析且可请求批量分析的进程数。
    var unanalyzedCount: Int {
        processes.filter { process in
            switch assessmentState(for: process) {
            case .notAnalyzed, .none:
                return true
            case let .failed(_, previous):
                return previous == nil
            default:
                return false
            }
        }.count
    }

    /// 按进程查询 AI 状态。
    func assessmentState(for process: RunningProcess) -> AIAssessmentState? {
        guard let fingerprint = fingerprints[process.id] else { return nil }
        return assessmentStates[fingerprint]
    }

    // MARK: - Actions

    func startMonitoring() {
        refreshTask?.cancel()
        phase = .loading

        refreshTask = Task {
            do {
                let result = try await fetcher.fetchAll()
                processes = result
                await updateAIStates()
                phase = .monitoring
                logger.notice("loaded \(result.count) processes")
            } catch {
                phase = .failed(error.localizedDescription)
                logger.error("fetch failed: \(error.localizedDescription)")
                return
            }

            // 每 3 秒自动刷新；只读新 fingerprint 的本地缓存，不联网
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                do {
                    let result = try await fetcher.fetchAll()
                    // 保持选中状态
                    let selectedPID = selectedProcess?.id
                    processes = result
                    await updateAIStates()
                    if let pid = selectedPID {
                        selectedProcess = result.first { $0.id == pid }
                    }
                } catch {
                    logger.warning("refresh failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopMonitoring() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        do {
            let result = try await fetcher.fetchAll()
            processes = result
            await updateAIStates()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 刷新后对首次出现的 fingerprint 只调用 `state(for:)` 读缓存；
    /// 同一 fingerprint 不重复读取；已退出进程的内存 UI 状态被移除。
    private func updateAIStates() async {
        var newFingerprints: [Int32: String] = [:]
        var newSubjects: [Int32: AIAssessmentSubject] = [:]
        var unseen: [AIAssessmentSubject] = []

        for process in processes {
            guard let subject = try? subjectFactory.processSubject(for: process) else { continue }
            newFingerprints[process.id] = subject.fingerprint
            newSubjects[process.id] = subject
            if assessmentStates[subject.fingerprint] == nil {
                unseen.append(subject)
            }
        }

        for subject in unseen {
            if let state = try? await aiService.state(for: subject) {
                assessmentStates[subject.fingerprint] = state
            }
        }

        // 移除已退出进程的内存 UI 状态
        let liveFingerprints = Set(newFingerprints.values)
        assessmentStates = assessmentStates.filter { liveFingerprints.contains($0.key) }
        fingerprints = newFingerprints
        subjects = newSubjects

        // 进程或 AI 缓存状态变化后重算可见列表（纯本地）
        updateFilteredProcesses()
    }

    /// 用户点击单项“AI 分析此进程”。
    func analyze(_ process: RunningProcess) async {
        guard let subject = subjects[process.id] else { return }
        assessmentStates[subject.fingerprint] = .loading(
            previous: assessmentStates[subject.fingerprint]?.assessment
        )
        updateFilteredProcesses()
        let states = await aiService.analyze([subject], forceRefresh: false)
        if let state = states[subject.subjectID] {
            assessmentStates[subject.fingerprint] = state
        }
        updateFilteredProcesses()
    }

    /// 用户点击“AI 重新检查”：强制联网，失败保留旧结果。
    func reanalyze(_ process: RunningProcess) async {
        guard let subject = subjects[process.id] else { return }
        assessmentStates[subject.fingerprint] = .loading(
            previous: assessmentStates[subject.fingerprint]?.assessment
        )
        updateFilteredProcesses()
        let states = await aiService.analyze([subject], forceRefresh: true)
        if let state = states[subject.subjectID] {
            assessmentStates[subject.fingerprint] = state
        }
        updateFilteredProcesses()
    }

    /// 用户点击批量按钮：只分析未判断进程，已有缓存不重查。
    func analyzeMissingProcesses() async {
        let targets = processes.compactMap { process -> AIAssessmentSubject? in
            guard let subject = subjects[process.id] else { return nil }
            switch assessmentStates[subject.fingerprint] {
            case .notAnalyzed, .none:
                return subject
            case let .failed(_, previous):
                return previous == nil ? subject : nil
            default:
                return nil
            }
        }
        guard !targets.isEmpty else { return }

        isBatchAnalyzing = true
        for subject in targets {
            assessmentStates[subject.fingerprint] = .loading(
                previous: assessmentStates[subject.fingerprint]?.assessment
            )
        }
        let states = await aiService.analyze(targets, forceRefresh: false)
        for subject in targets {
            if let state = states[subject.subjectID] {
                assessmentStates[subject.fingerprint] = state
            }
        }
        isBatchAnalyzing = false
        updateFilteredProcesses()
    }

    /// 用户取消批量分析：停止后续批次。
    func cancelAIAnalysis() async {
        await aiService.cancelCurrentAnalysis()
        isBatchAnalyzing = false
        for (fingerprint, state) in assessmentStates {
            if case let .loading(previous) = state {
                assessmentStates[fingerprint] = previous.map { .cached($0) } ?? .notAnalyzed
            }
        }
        updateFilteredProcesses()
    }

    // MARK: - 终止（始终经过本地 guard，AI 结果只作解释信息）

    /// 请求终止进程（快照进程信息，弹出确认对话框）
    func requestKill(pid: Int32, force: Bool = false) {
        pendingKillProcess = processes.first { $0.id == pid }
        pendingForceKill = force
        showKillConfirm = true
    }

    /// 确认终止进程（终止前由 guard 重新验证进程身份）
    func confirmKill() {
        guard let proc = pendingKillProcess else { return }
        let force = pendingForceKill

        pendingKillProcess = nil
        pendingForceKill = false
        showKillConfirm = false

        Task {
            await requestTermination(proc, force: force)
        }
    }

    /// 执行终止：本地 guard 是唯一裁决；AI 建议不参与。
    /// 拒绝时不发送任何信号，只记录错误。
    func requestTermination(_ process: RunningProcess, force: Bool = false) async {
        let error = await terminationService.terminate(process, force: force)
        terminationError = error
        if let error {
            lastError = "无法终止进程 \(process.id)：\(Self.describe(error))"
            logger.error("failed to kill pid \(process.id)")
        } else {
            logger.notice("terminated pid \(process.id) (force=\(force))")
            processes = processes.filter { $0.id != process.id }
            updateFilteredProcesses()
            if selectedProcess?.id == process.id {
                selectedProcess = nil
            }
        }
    }

    func cancelKill() {
        pendingKillProcess = nil
        pendingForceKill = false
        showKillConfirm = false
    }

    private static func describe(_ error: ProcessTerminationError) -> String {
        switch error {
        case .protectedProcess:
            return "本地安全校验未通过"
        case .identityUnavailable:
            return "无法验证进程身份"
        case .failed:
            return "权限不足或进程身份已变化"
        }
    }
}
