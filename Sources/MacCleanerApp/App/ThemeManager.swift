import SwiftUI

@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    enum AccentTheme: String, CaseIterable, Identifiable {
        case system = "system"
        case blue = "blue"
        case green = "green"
        case purple = "purple"
        case pink = "pink"
        case orange = "orange"
        case teal = "teal"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "跟随系统"
            case .blue:   return "蓝色"
            case .green:  return "绿色"
            case .purple: return "紫色"
            case .pink:   return "粉色"
            case .orange: return "橙色"
            case .teal:   return "青色"
            }
        }

        var color: Color? {
            switch self {
            case .system: return nil
            case .blue:   return .blue
            case .green:  return .green
            case .purple: return .purple
            case .pink:   return .pink
            case .orange: return .orange
            case .teal:   return .teal
            }
        }
    }

    var selectedTheme: AccentTheme {
        didSet { persistTheme() }
    }

    var accentColor: Color? {
        selectedTheme.color
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: "accentTheme") ?? "system"
        self.selectedTheme = AccentTheme(rawValue: stored) ?? .system
    }

    private func persistTheme() {
        UserDefaults.standard.set(selectedTheme.rawValue, forKey: "accentTheme")
    }
}
