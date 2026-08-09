import Foundation
import MacCleanerCore

/// AI 设置状态机。只公开配置状态与输入框，从不回读 key 明文；
/// 保存成功后立即清空输入框。删除 key 与清空缓存是两个独立操作，
/// 互不影响。
@Observable
@MainActor
final class AISettingsViewModel {
    enum ConnectionState: Equatable {
        case idle
        case testing
        case success
        case failed(String)
    }

    var apiKeyInput: String = ""
    var isConfigured: Bool = false
    var connectionState: ConnectionState = .idle
    var cacheStats: AIAssessmentCache.Stats?
    var presentPrivacyConsent: Bool = false
    var errorMessage: String?
    var modelInput: String
    var baseURLInput: String
    var serviceConfigurationErrorMessage: String?

    private let keyStore: any APIKeyManaging
    private let consentStore: any AIPrivacyConsentStoring
    private let connectionChecker: any DeepSeekConnectionChecking
    private let cache: any AIAssessmentCacheStatsProviding
    private let configurationStore: any DeepSeekConfigurationManaging

    init(
        keyStore: any APIKeyManaging,
        consentStore: any AIPrivacyConsentStoring,
        connectionChecker: any DeepSeekConnectionChecking,
        cache: any AIAssessmentCacheStatsProviding,
        configurationStore: any DeepSeekConfigurationManaging
    ) {
        self.keyStore = keyStore
        self.consentStore = consentStore
        self.connectionChecker = connectionChecker
        self.cache = cache
        self.configurationStore = configurationStore
        let configuration = configurationStore.configuration()
        self.modelInput = configuration.model
        self.baseURLInput = configuration.baseURL.absoluteString
    }

    /// 载入配置状态和缓存统计。绝不回读 key 明文。
    func load() async {
        isConfigured = (try? keyStore.isConfigured()) ?? false
        cacheStats = try? await cache.stats()
        connectionState = .idle
        errorMessage = nil
        serviceConfigurationErrorMessage = nil
        let configuration = configurationStore.configuration()
        modelInput = configuration.model
        baseURLInput = configuration.baseURL.absoluteString
    }

    /// 保存 key 前必须确认完整路径发送说明。
    /// 未同意当前版本说明时弹出确认，不写入 key。
    func saveKey() async {
        guard !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入 API Key"
            return
        }
        let accepted = await consentStore.acceptedVersion()
        guard accepted == UserDefaultsAIPrivacyConsentStore.currentVersion else {
            presentPrivacyConsent = true
            return
        }
        await persistKey()
    }

    /// 用户点击“同意并保存”：记录 consent version 后保存 key。
    func acceptPrivacyConsentAndSave() async {
        await consentStore.accept(version: UserDefaultsAIPrivacyConsentStore.currentVersion)
        presentPrivacyConsent = false
        await persistKey()
    }

    /// 用户取消隐私说明：不保存 key。
    func cancelPrivacyConsent() {
        presentPrivacyConsent = false
    }

    /// 连接测试：最小请求，不发送本地文件或进程信息。
    func testConnection() async {
        connectionState = .testing
        do {
            try await connectionChecker.checkConnection()
            connectionState = .success
        } catch let error as DeepSeekClientError {
            connectionState = .failed(Self.describe(error))
        } catch {
            connectionState = .failed("网络连接失败")
        }
    }

    /// 删除 key。不删除缓存。
    func deleteKey() async {
        try? keyStore.delete()
        isConfigured = false
        connectionState = .idle
    }

    /// 清空缓存。不删除 key。
    func clearCache() async {
        try? await cache.removeAll()
        cacheStats = try? await cache.stats()
    }

    /// 保存模型 ID 和 Base URL；client 会在下一次请求时读取最新值。
    func saveServiceConfiguration() {
        do {
            try configurationStore.update(model: modelInput, baseURL: baseURLInput)
            let configuration = configurationStore.configuration()
            modelInput = configuration.model
            baseURLInput = configuration.baseURL.absoluteString
            serviceConfigurationErrorMessage = nil
            connectionState = .idle
        } catch let error as DeepSeekConfigurationStoreError {
            switch error {
            case .invalidModel:
                serviceConfigurationErrorMessage = "请输入模型 ID"
            case .invalidBaseURL:
                serviceConfigurationErrorMessage = "请输入有效的 HTTPS Base URL"
            }
        } catch {
            serviceConfigurationErrorMessage = "保存服务配置失败，请重试"
        }
    }

    // MARK: - 私有

    private func persistKey() async {
        do {
            try keyStore.set(apiKeyInput)
            apiKeyInput = ""
            isConfigured = true
            errorMessage = nil
        } catch {
            errorMessage = "保存失败，请重试"
        }
    }

    private static func describe(_ error: DeepSeekClientError) -> String {
        switch error {
        case .authentication:
            return "API Key 无效，请检查设置"
        case .rateLimited:
            return "请求过于频繁，请稍后重试"
        case .serviceUnavailable:
            return "AI 服务暂时不可用"
        case let .httpStatus(status):
            return "请求失败（HTTP \(status)）"
        case .transport:
            return "网络连接失败"
        case .invalidResponse:
            return "服务返回无法识别"
        }
    }
}
