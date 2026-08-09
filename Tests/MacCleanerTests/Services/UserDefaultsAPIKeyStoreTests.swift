import Foundation
import Testing
@testable import MacCleanerCore

@Suite("UserDefaults API key store")
struct UserDefaultsAPIKeyStoreTests {
    @Test("API Key 写入本机应用偏好，不触碰系统钥匙串")
    func writesKeyToUserDefaults() throws {
        let suiteName = "UserDefaultsAPIKeyStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsAPIKeyStore(defaults: defaults)
        try store.set("  sk-local-only  ")

        #expect(defaults.string(forKey: UserDefaultsAPIKeyStore.storageKey) == "sk-local-only")
        #expect(try store.withAPIKey { $0 } == "sk-local-only")
    }

    @Test("删除 API Key 会清空本机应用偏好")
    func deletesStoredKey() throws {
        let suiteName = "UserDefaultsAPIKeyStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsAPIKeyStore(defaults: defaults)
        try store.set("sk-local-only")
        try store.delete()

        #expect(defaults.object(forKey: UserDefaultsAPIKeyStore.storageKey) == nil)
        #expect(!(try store.isConfigured()))
    }
}
