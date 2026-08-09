import Foundation

/// DeepSeek 请求配置的读取边界。client 在每次请求前读取它，
/// 因而设置页保存后无需重启应用即可生效。
public protocol DeepSeekConfigurationProviding: Sendable {
    func configuration() -> DeepSeekConfiguration
}

/// DeepSeek 请求配置的保存边界。
public protocol DeepSeekConfigurationManaging: DeepSeekConfigurationProviding {
    func update(model: String, baseURL: String) throws
}

public enum DeepSeekConfigurationStoreError: Error, Equatable, Sendable {
    case invalidModel
    case invalidBaseURL
}

/// 将模型 ID 与 Base URL 保存至本机应用偏好。
/// API Key 使用独立的 `UserDefaultsAPIKeyStore`，避免被配置项意外覆盖。
public final class UserDefaultsDeepSeekConfigurationStore: DeepSeekConfigurationManaging, @unchecked Sendable {
    public static let modelStorageKey = "deepSeekModel"
    public static let baseURLStorageKey = "deepSeekBaseURL"
    private static let completedPublicBaseURLMigrationKey = "deepSeekCompletedPublicBaseURLMigration"
    private static let legacyDefaultBaseURL = "https://api.deepseek.com/beta"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func configuration() -> DeepSeekConfiguration {
        let storedModel = defaults.string(forKey: Self.modelStorageKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = storedModel
            .flatMap(DeepSeekModel.init(rawValue:))?
            .rawValue ?? DeepSeekConfiguration.defaultModel

        let storedBaseURL = migratedBaseURL()
        let baseURL = Self.normalizedBaseURL(storedBaseURL) ?? DeepSeekConfiguration.defaultBaseURL

        return DeepSeekConfiguration(baseURL: baseURL, model: model)
    }

    public func update(model: String, baseURL: String) throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeepSeekModel(rawValue: trimmedModel) != nil else {
            throw DeepSeekConfigurationStoreError.invalidModel
        }
        guard let normalizedBaseURL = Self.normalizedBaseURL(baseURL) else {
            throw DeepSeekConfigurationStoreError.invalidBaseURL
        }

        defaults.set(trimmedModel, forKey: Self.modelStorageKey)
        defaults.set(normalizedBaseURL.absoluteString, forKey: Self.baseURLStorageKey)
        defaults.set(true, forKey: Self.completedPublicBaseURLMigrationKey)
    }

    private func migratedBaseURL() -> String? {
        let storedBaseURL = defaults.string(forKey: Self.baseURLStorageKey)
        guard !defaults.bool(forKey: Self.completedPublicBaseURLMigrationKey) else {
            return storedBaseURL
        }

        defaults.set(true, forKey: Self.completedPublicBaseURLMigrationKey)
        guard storedBaseURL == Self.legacyDefaultBaseURL else {
            return storedBaseURL
        }

        let publicBaseURL = DeepSeekConfiguration.defaultBaseURL.absoluteString
        defaults.set(publicBaseURL, forKey: Self.baseURLStorageKey)
        return publicBaseURL
    }

    private static func normalizedBaseURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }

        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        return url
    }
}
