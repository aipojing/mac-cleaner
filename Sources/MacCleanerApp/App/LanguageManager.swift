import SwiftUI

@Observable
final class LanguageManager {
    static let shared = LanguageManager()

    enum AppLanguage: String, CaseIterable, Identifiable {
        case system = "system"
        case zhHans = "zh-Hans"
        case en = "en"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "跟随系统"
            case .zhHans: return "简体中文"
            case .en:     return "English"
            }
        }

        /// SwiftUI `.environment(\.locale, _)` 对应的 Locale；`.system` 返回 nil 表示不覆盖
        var locale: Locale? {
            switch self {
            case .system: return nil
            case .zhHans: return Locale(identifier: "zh-Hans")
            case .en:     return Locale(identifier: "en")
            }
        }
    }

    private static let storageKey = "appLanguage"
    private static let appleLanguagesKey = "AppleLanguages"

    var selectedLanguage: AppLanguage {
        didSet {
            persist()
            applyToAppleLanguages()
        }
    }

    /// 当前实际生效的 Locale（跟随系统或用户覆盖）
    var effectiveLocale: Locale {
        selectedLanguage.locale ?? Locale.current
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey) ?? "system"
        self.selectedLanguage = AppLanguage(rawValue: stored) ?? .system
        applyToAppleLanguages()
    }

    private func persist() {
        UserDefaults.standard.set(selectedLanguage.rawValue, forKey: Self.storageKey)
    }

    /// 覆盖 AppleLanguages — 使 Bundle/系统 API 返回对应语言的本地化资源
    /// 注意：bundle 级的 NSLocalizedString 查找在应用首次加载后就缓存了，完全生效需要重启
    private func applyToAppleLanguages() {
        switch selectedLanguage {
        case .system:
            UserDefaults.standard.removeObject(forKey: Self.appleLanguagesKey)
        case .zhHans, .en:
            UserDefaults.standard.set([selectedLanguage.rawValue], forKey: Self.appleLanguagesKey)
        }
    }
}
