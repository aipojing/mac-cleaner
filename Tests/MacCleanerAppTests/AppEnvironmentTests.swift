import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

@MainActor
@Suite("App environment")
struct AppEnvironmentTests {
    @Test("AI 设置 VM 只创建一次，SettingsView body 重算不会丢失输入状态")
    func aiSettingsViewModelIsCreatedOnce() {
        let environment = AppEnvironment(
            aiService: RecordingAIService(),
            apiKeyStore: InMemoryAPIKeyStore(),
            privacyConsentStore: InMemoryAIPrivacyConsentStore(),
            connectionChecker: StubConnectionChecker(),
            assessmentCache: StubAssessmentCache(),
            deepSeekConfigurationStore: InMemoryDeepSeekConfigurationStore()
        )

        let first = environment.aiSettingsViewModel
        first.apiKeyInput = "sk-test-in-progress"

        #expect(environment.aiSettingsViewModel === first, "同一 environment 必须复用同一个 AI 设置 VM")
        #expect(environment.aiSettingsViewModel.apiKeyInput == "sk-test-in-progress")
    }
}
