import Foundation

/// API Key 的本机应用偏好存储。
///
/// 此存储不会访问系统钥匙串，因此保存或读取时不会触发钥匙串授权。
/// API Key 会以明文保存在当前用户的应用偏好中，只应在用户明确选择
/// 免钥匙串存储的场景下使用。
public final class UserDefaultsAPIKeyStore: APIKeyManaging, APIKeyProviding, @unchecked Sendable {
    public static let storageKey = "aiAPIKey"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isConfigured() throws -> Bool {
        guard let key = defaults.string(forKey: Self.storageKey) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func set(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIKeyStoreError.invalidKey }
        defaults.set(trimmed, forKey: Self.storageKey)
    }

    public func delete() throws {
        defaults.removeObject(forKey: Self.storageKey)
    }

    public func withAPIKey<T>(_ body: (String) throws -> T) throws -> T {
        guard let key = defaults.string(forKey: Self.storageKey), !key.isEmpty else {
            throw APIKeyStoreError.notConfigured
        }
        return try body(key)
    }
}
