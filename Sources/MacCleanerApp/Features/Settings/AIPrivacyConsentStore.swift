import Foundation

/// AI 隐私说明的版本化同意状态。说明变化时递增版本以重新提示；
/// 同意记录独立于 API Key 存储，不写入 Keychain。
protocol AIPrivacyConsentStoring: Sendable {
    func acceptedVersion() async -> Int?
    func accept(version: Int) async
    func reset() async
}

/// 生产实现：独立 UserDefaults key，不与 API Key 存在同一存储。
actor UserDefaultsAIPrivacyConsentStore: AIPrivacyConsentStoring {
    static let storageKey = "aiPrivacyConsentVersion"
    /// 当前隐私说明版本。
    static let currentVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func acceptedVersion() -> Int? {
        defaults.object(forKey: Self.storageKey) as? Int
    }

    func accept(version: Int) {
        defaults.set(version, forKey: Self.storageKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}
