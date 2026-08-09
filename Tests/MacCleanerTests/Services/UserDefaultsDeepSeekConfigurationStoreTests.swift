import Foundation
import Testing
@testable import MacCleanerCore

@Suite("DeepSeek 服务配置")
struct UserDefaultsDeepSeekConfigurationStoreTests {
    @Test("旧版默认的 Beta 地址自动迁移为公开地址")
    func migratesLegacyBetaBaseURL() throws {
        let suiteName = "UserDefaultsDeepSeekConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://api.deepseek.com/beta", forKey: UserDefaultsDeepSeekConfigurationStore.baseURLStorageKey)
        let store = UserDefaultsDeepSeekConfigurationStore(defaults: defaults)

        #expect(store.configuration().baseURL.absoluteString == "https://api.deepseek.com")
        #expect(defaults.string(forKey: UserDefaultsDeepSeekConfigurationStore.baseURLStorageKey) == "https://api.deepseek.com")
    }

    @Test("模型列表只提供文档支持的 Flash 和 Pro")
    func exposesSupportedModels() {
        #expect(DeepSeekModel.allCases.map(\.rawValue) == [
            "deepseek-v4-flash",
            "deepseek-v4-pro",
        ])
    }

    @Test("保存模型 ID 和 Base URL 后读取同一份配置")
    func persistsModelAndBaseURL() throws {
        let suiteName = "UserDefaultsDeepSeekConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsDeepSeekConfigurationStore(defaults: defaults)

        try store.update(
            model: " deepseek-v4-flash ",
            baseURL: "https://api.deepseek.com/beta/"
        )

        #expect(store.configuration() == .init(
            baseURL: URL(string: "https://api.deepseek.com/beta")!,
            model: "deepseek-v4-flash"
        ))
    }

    @Test("拒绝空模型 ID 和非 HTTPS Base URL")
    func rejectsInvalidValues() throws {
        let suiteName = "UserDefaultsDeepSeekConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsDeepSeekConfigurationStore(defaults: defaults)

        #expect(throws: DeepSeekConfigurationStoreError.invalidModel) {
            try store.update(model: "  ", baseURL: "https://api.deepseek.com/beta")
        }
        #expect(throws: DeepSeekConfigurationStoreError.invalidModel) {
            try store.update(model: "deepseek-custom", baseURL: "https://api.deepseek.com")
        }
        #expect(throws: DeepSeekConfigurationStoreError.invalidBaseURL) {
            try store.update(model: "deepseek-v4-pro", baseURL: "http://api.deepseek.com")
        }
    }
}
