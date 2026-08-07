import Foundation
import Testing
@testable import MacCleanerCore

@Suite("API key store")
struct KeychainAPIKeyStoreTests {
    @Test("设置后只暴露 configured 状态")
    func configurationStatus() throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainAPIKeyStore(backend: backend)
        try store.set("sk-user-secret")

        #expect(try store.isConfigured())
        #expect(backend.lastWrite?.service == "com.maccleaner.deepseek")
        #expect(backend.lastWrite?.account == "api-key")
    }

    @Test("空白 key 被拒绝，删除后状态清空")
    func rejectsBlankAndDeletes() throws {
        let store = KeychainAPIKeyStore(backend: InMemoryKeychainBackend())
        #expect(throws: APIKeyStoreError.invalidKey) { try store.set("   ") }
        #expect(throws: APIKeyStoreError.invalidKey) { try store.set("") }
        try store.set("sk-valid")
        try store.delete()
        #expect(!(try store.isConfigured()))
    }

    @Test("重复设置覆盖旧值")
    func setOverwrites() throws {
        let store = KeychainAPIKeyStore(backend: InMemoryKeychainBackend())
        try store.set("sk-first")
        try store.set("sk-second")
        let value = try store.withAPIKey { $0 }
        #expect(value == "sk-second")
    }

    @Test("withAPIKey 只在闭包内暴露 key，未配置时抛错")
    func withAPIKeyScoping() throws {
        let store = KeychainAPIKeyStore(backend: InMemoryKeychainBackend())
        #expect(throws: APIKeyStoreError.notConfigured) {
            _ = try store.withAPIKey { $0 }
        }
        try store.set("sk-scoped")
        let length = try store.withAPIKey { $0.count }
        #expect(length == "sk-scoped".count)
    }

    @Test("错误描述不携带 key 内容")
    func errorsDoNotLeakKey() throws {
        let store = KeychainAPIKeyStore(backend: InMemoryKeychainBackend())
        do {
            _ = try store.withAPIKey { $0 }
            Issue.record("应当抛出 notConfigured")
        } catch {
            #expect(!String(describing: error).contains("sk-"))
        }
    }
}
