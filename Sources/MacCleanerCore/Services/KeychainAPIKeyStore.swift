import Foundation
import Security

/// 可注入的 Keychain 后端，便于测试用内存实现替代真实 Security 调用。
protocol KeychainBackend: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// DeepSeek API Key 的 Keychain 存储。key 只写入 Keychain，
/// 不进入 JSON、UserDefaults 或日志；错误信息不携带 key 内容。
public struct KeychainAPIKeyStore: APIKeyManaging, APIKeyProviding {
    public static let service = "com.maccleaner.deepseek"
    public static let account = "api-key"

    private let backend: any KeychainBackend

    /// 生产入口：使用真实 Security Keychain。
    public init() {
        self.init(backend: SecurityKeychainBackend())
    }

    init(backend: any KeychainBackend) {
        self.backend = backend
    }

    public func isConfigured() throws -> Bool {
        guard let data = try backend.read(service: Self.service, account: Self.account),
              let key = String(data: data, encoding: .utf8) else {
            return false
        }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func set(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIKeyStoreError.invalidKey }
        try backend.write(Data(trimmed.utf8), service: Self.service, account: Self.account)
    }

    public func delete() throws {
        try backend.delete(service: Self.service, account: Self.account)
    }

    public func withAPIKey<T>(_ body: (String) throws -> T) throws -> T {
        guard let data = try backend.read(service: Self.service, account: Self.account),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            throw APIKeyStoreError.notConfigured
        }
        return try body(key)
    }
}

/// 基于 Security 框架的真实 Keychain 后端。
/// 使用 generic password，仅本设备解锁后可访问，不同步 iCloud。
struct SecurityKeychainBackend: KeychainBackend {
    func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw APIKeyStoreError.keychainFailure
        }
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw APIKeyStoreError.keychainFailure
            }
        } else if status != errSecSuccess {
            throw APIKeyStoreError.keychainFailure
        }
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychainFailure
        }
    }
}
