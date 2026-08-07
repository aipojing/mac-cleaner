import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

extension AISettingsViewModel {
    static func fixture(
        keyStore: InMemoryAPIKeyStore = InMemoryAPIKeyStore(),
        consentStore: InMemoryAIPrivacyConsentStore = InMemoryAIPrivacyConsentStore(),
        connectionChecker: StubConnectionChecker = StubConnectionChecker(),
        cache: StubAssessmentCache = StubAssessmentCache()
    ) -> AISettingsViewModel {
        AISettingsViewModel(
            keyStore: keyStore,
            consentStore: consentStore,
            connectionChecker: connectionChecker,
            cache: cache
        )
    }
}

@MainActor
@Suite("AI settings view model")
struct AISettingsViewModelTests {
    @Test("载入设置不回填明文 key")
    func neverLoadsPlaintextKey() async {
        let keyStore = InMemoryAPIKeyStore(key: "sk-existing")
        let viewModel = AISettingsViewModel.fixture(keyStore: keyStore)
        await viewModel.load()
        #expect(viewModel.isConfigured)
        #expect(viewModel.apiKeyInput.isEmpty)
    }

    @Test("保存前必须确认完整路径发送说明")
    func requiresPrivacyConsent() async throws {
        let consent = InMemoryAIPrivacyConsentStore(hasConsented: false)
        let keyStore = InMemoryAPIKeyStore()
        let viewModel = AISettingsViewModel.fixture(
            keyStore: keyStore,
            consentStore: consent
        )
        viewModel.apiKeyInput = "sk-new"
        await viewModel.saveKey()
        #expect(viewModel.presentPrivacyConsent)
        #expect(!(try keyStore.isConfigured()))
    }

    @Test("取消隐私说明不保存 key")
    func cancelConsentKeepsKeyUnsaved() async throws {
        let consent = InMemoryAIPrivacyConsentStore(hasConsented: false)
        let keyStore = InMemoryAPIKeyStore()
        let viewModel = AISettingsViewModel.fixture(
            keyStore: keyStore,
            consentStore: consent
        )
        viewModel.apiKeyInput = "sk-new"
        await viewModel.saveKey()
        viewModel.cancelPrivacyConsent()
        #expect(!viewModel.presentPrivacyConsent)
        #expect(!(try keyStore.isConfigured()))
    }

    @Test("同意并保存后写入 key 且输入框清空")
    func acceptConsentSavesAndClearsInput() async throws {
        let consent = InMemoryAIPrivacyConsentStore(hasConsented: false)
        let keyStore = InMemoryAPIKeyStore()
        let viewModel = AISettingsViewModel.fixture(
            keyStore: keyStore,
            consentStore: consent
        )
        viewModel.apiKeyInput = "sk-new"
        await viewModel.saveKey()
        await viewModel.acceptPrivacyConsentAndSave()
        #expect(try keyStore.isConfigured())
        #expect(viewModel.apiKeyInput.isEmpty)
        #expect(viewModel.isConfigured)
        #expect(!viewModel.presentPrivacyConsent)
        #expect(await consent.acceptedVersion() == 1)
    }

    @Test("已同意说明时保存不再弹出确认")
    func consentedSaveSkipsPrompt() async throws {
        let consent = InMemoryAIPrivacyConsentStore(hasConsented: true, version: 1)
        let keyStore = InMemoryAPIKeyStore()
        let viewModel = AISettingsViewModel.fixture(
            keyStore: keyStore,
            consentStore: consent
        )
        viewModel.apiKeyInput = "sk-new"
        await viewModel.saveKey()
        #expect(!viewModel.presentPrivacyConsent)
        #expect(try keyStore.isConfigured())
    }

    @Test("连接测试不发送本地文件或进程信息")
    func connectionCheckUsesMetadataFreeEndpoint() async {
        let checker = StubConnectionChecker(result: .success(()))
        let viewModel = AISettingsViewModel.fixture(connectionChecker: checker)
        await viewModel.testConnection()
        #expect(await checker.callCount == 1)
        #expect(viewModel.connectionState == .success)
    }

    @Test("连接失败展示可读错误")
    func connectionFailureShowsMessage() async {
        let checker = StubConnectionChecker(result: .failure(DeepSeekClientError.authentication))
        let viewModel = AISettingsViewModel.fixture(connectionChecker: checker)
        await viewModel.testConnection()
        #expect(viewModel.connectionState == .failed("API Key 无效，请检查设置"))
    }

    @Test("删除 key 不影响缓存，清空缓存不影响 key")
    func deleteKeyAndClearCacheAreIndependent() async throws {
        let keyStore = InMemoryAPIKeyStore(key: "sk-existing")
        let cache = StubAssessmentCache()
        let viewModel = AISettingsViewModel.fixture(keyStore: keyStore, cache: cache)
        await viewModel.load()

        await viewModel.deleteKey()
        #expect(!(try keyStore.isConfigured()))
        #expect(await cache.removeAllCount == 0)

        await viewModel.clearCache()
        #expect(await cache.removeAllCount == 1)
    }
}
