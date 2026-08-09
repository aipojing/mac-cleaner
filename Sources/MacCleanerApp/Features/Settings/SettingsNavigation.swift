import Foundation

enum SettingsTab: String {
    case appearance
    case language
    case ai
}

enum SettingsNavigation {
    static let selectedTabStorageKey = "settingsSelectedTab"

    static func selectedTab(in defaults: UserDefaults = .standard) -> SettingsTab {
        guard let rawValue = defaults.string(forKey: selectedTabStorageKey),
              let tab = SettingsTab(rawValue: rawValue) else {
            return .appearance
        }
        return tab
    }

    static func selectAI(in defaults: UserDefaults = .standard) {
        defaults.set(SettingsTab.ai.rawValue, forKey: selectedTabStorageKey)
    }
}
