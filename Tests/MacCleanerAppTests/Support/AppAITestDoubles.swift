import Foundation
import MacCleanerCore
@testable import DevClean

enum TestDoubleError: Error, Equatable {
    case offline
}

/// 记录调用的 AI 服务 double：用于断言扫描、刷新等自动路径
/// 只读缓存状态、从不触发 analyze 网络请求。
actor RecordingAIService: AIAnalysisServing {
    private var cannedStates: [String: AIAssessmentState]
    private let result: AIAssessment?
    private let refreshError: (any Error)?

    private(set) var stateLookupCount = 0
    private(set) var analysisCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var lastForceRefresh: Bool?
    private(set) var analyzedSubjectIDs: [[String]] = []

    init(
        states: [String: AIAssessmentState] = [:],
        result: AIAssessment? = nil,
        refreshError: (any Error)? = nil
    ) {
        cannedStates = states
        self.result = result
        self.refreshError = refreshError
    }

    func setState(_ state: AIAssessmentState, for subjectID: String) {
        cannedStates[subjectID] = state
    }

    func state(for subject: AIAssessmentSubject) async throws -> AIAssessmentState {
        stateLookupCount += 1
        return cannedStates[subject.subjectID] ?? .notAnalyzed
    }

    func states(for subjects: [AIAssessmentSubject]) async -> [String: AIAssessmentState] {
        stateLookupCount += 1
        var result: [String: AIAssessmentState] = [:]
        for subject in subjects {
            result[subject.subjectID] = cannedStates[subject.subjectID] ?? .notAnalyzed
        }
        return result
    }

    func analyze(
        _ subjects: [AIAssessmentSubject],
        forceRefresh: Bool
    ) async -> [String: AIAssessmentState] {
        analysisCallCount += 1
        lastForceRefresh = forceRefresh
        analyzedSubjectIDs.append(subjects.map(\.subjectID))
        var states: [String: AIAssessmentState] = [:]
        for subject in subjects {
            if forceRefresh, refreshError != nil {
                // 重查失败：保留旧缓存结果
                states[subject.subjectID] = .failed(
                    message: "网络连接失败",
                    previous: cannedStates[subject.subjectID]?.assessment
                )
            } else if let result {
                states[subject.subjectID] = .fresh(result)
            } else {
                states[subject.subjectID] = cannedStates[subject.subjectID] ?? .notAnalyzed
            }
        }
        return states
    }

    func cancelCurrentAnalysis() {
        cancelCallCount += 1
    }
}

/// 内存 API Key double：不接触真实持久化存储。
final class InMemoryAPIKeyStore: APIKeyManaging, APIKeyProviding, @unchecked Sendable {
    private var key: String?

    init(key: String? = nil) {
        self.key = key
    }

    func isConfigured() throws -> Bool {
        guard let key else { return false }
        return !key.isEmpty
    }

    func set(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIKeyStoreError.invalidKey }
        self.key = trimmed
    }

    func delete() throws {
        key = nil
    }

    func withAPIKey<T>(_ body: (String) throws -> T) throws -> T {
        guard let key else { throw APIKeyStoreError.notConfigured }
        return try body(key)
    }
}

final class InMemoryDeepSeekConfigurationStore: DeepSeekConfigurationManaging, @unchecked Sendable {
    private var current: DeepSeekConfiguration

    init(configuration: DeepSeekConfiguration = DeepSeekConfiguration()) {
        self.current = configuration
    }

    func configuration() -> DeepSeekConfiguration {
        current
    }

    func update(model: String, baseURL: String) throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekConfigurationStoreError.invalidModel
        }
        guard let url = URL(string: baseURL), url.scheme == "https", url.host != nil else {
            throw DeepSeekConfigurationStoreError.invalidBaseURL
        }
        current = DeepSeekConfiguration(baseURL: url, model: model)
    }
}

/// 内存隐私同意 double。
actor InMemoryAIPrivacyConsentStore: AIPrivacyConsentStoring {
    private var version: Int?

    init(hasConsented: Bool = false, version: Int = 1) {
        self.version = hasConsented ? version : nil
    }

    func acceptedVersion() -> Int? {
        version
    }

    func accept(version: Int) {
        self.version = version
    }

    func reset() {
        version = nil
    }
}

/// 预制结果的连接检查 double。
actor StubConnectionChecker: DeepSeekConnectionChecking {
    private let result: Result<Void, any Error>
    private(set) var callCount = 0

    init(result: Result<Void, any Error> = .success(())) {
        self.result = result
    }

    func checkConnection() async throws {
        callCount += 1
        try result.get()
    }
}

/// 预制统计的缓存 double：不接触真实缓存文件。
actor StubAssessmentCache: AIAssessmentCacheStatsProviding {
    private var cannedStats: AIAssessmentCache.Stats
    private(set) var removeAllCount = 0

    init(stats: AIAssessmentCache.Stats = AIAssessmentCache.Stats(recordCount: 3, byteCount: 1_024)) {
        cannedStats = stats
    }

    func stats() -> AIAssessmentCache.Stats {
        cannedStats
    }

    func removeAll() {
        removeAllCount += 1
        cannedStats = AIAssessmentCache.Stats(recordCount: 0, byteCount: 0)
    }
}

/// 预制进程列表的 fetcher double：不调用真实 ps。
struct StubProcessListFetcher: ProcessListFetching {
    let processes: [RunningProcess]

    func fetchAll() async throws -> [RunningProcess] {
        processes
    }
}

/// 记录信号的终止服务 double：拒绝时不发送任何信号。
actor RecordingTerminationService: ProcessTerminating {
    private let result: ProcessTerminationError?
    private(set) var signalCount = 0
    private(set) var attempts: [(pid: Int32, force: Bool)] = []

    init(result: ProcessTerminationError? = nil) {
        self.result = result
    }

    func terminate(_ process: RunningProcess, force: Bool) async -> ProcessTerminationError? {
        attempts.append((process.id, force))
        if let result { return result }
        signalCount += 1
        return nil
    }
}
