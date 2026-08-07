import Foundation
import MacCleanerCore

/// App 层 AI 服务边界：只暴露状态查询、显式分析和取消。
/// `state`/`states` 只读 Keychain 配置状态与本地缓存，不触发网络请求；
/// `analyze` 必须由用户显式动作触发。
protocol AIAnalysisServing: Sendable {
    func state(for subject: AIAssessmentSubject) async throws -> AIAssessmentState
    func states(for subjects: [AIAssessmentSubject]) async -> [String: AIAssessmentState]
    @discardableResult
    func analyze(_ subjects: [AIAssessmentSubject], forceRefresh: Bool) async -> [String: AIAssessmentState]
    func cancelCurrentAnalysis() async
}

extension AIAnalysisCoordinator: AIAnalysisServing {}

/// 设置页依赖的缓存统计/清空边界。只暴露统计和清空，
/// 不暴露单条结论内容。
protocol AIAssessmentCacheStatsProviding: Sendable {
    func stats() async throws -> AIAssessmentCache.Stats
    func removeAll() async throws
}

extension AIAssessmentCache: AIAssessmentCacheStatsProviding {}

/// 唯一 App 组合根：生产环境只创建一次，通过构造参数传给
/// 需要 AI 的 view model；Preview 和测试传入内存 doubles。
@MainActor
final class AppEnvironment {
    let aiService: any AIAnalysisServing
    let subjectFactory: AIAssessmentSubjectFactory
    let apiKeyStore: any APIKeyManaging
    let privacyConsentStore: any AIPrivacyConsentStoring
    let connectionChecker: any DeepSeekConnectionChecking
    let assessmentCache: any AIAssessmentCacheStatsProviding

    init(
        aiService: any AIAnalysisServing,
        subjectFactory: AIAssessmentSubjectFactory = AIAssessmentSubjectFactory(),
        apiKeyStore: any APIKeyManaging,
        privacyConsentStore: any AIPrivacyConsentStoring,
        connectionChecker: any DeepSeekConnectionChecking,
        assessmentCache: any AIAssessmentCacheStatsProviding
    ) {
        self.aiService = aiService
        self.subjectFactory = subjectFactory
        self.apiKeyStore = apiKeyStore
        self.privacyConsentStore = privacyConsentStore
        self.connectionChecker = connectionChecker
        self.assessmentCache = assessmentCache
    }

    static func production() -> AppEnvironment {
        let keyStore = KeychainAPIKeyStore()
        let cache = AIAssessmentCache()
        let client = DeepSeekAssessmentClient(
            configuration: DeepSeekConfiguration(),
            keyStore: keyStore,
            transport: URLSessionHTTPTransport()
        )
        return AppEnvironment(
            aiService: AIAnalysisCoordinator(
                provider: client,
                cache: cache,
                keyManager: keyStore
            ),
            apiKeyStore: keyStore,
            privacyConsentStore: UserDefaultsAIPrivacyConsentStore(),
            connectionChecker: client,
            assessmentCache: cache
        )
    }
}
