import Foundation
import Testing
@testable import DevClean

@Suite("Settings navigation")
struct SettingsNavigationTests {
    @Test("菜单栏选择 AI 设置后保存 AI 标签")
    func selectsAITab() throws {
        let suiteName = "SettingsNavigationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsNavigation.selectAI(in: defaults)

        #expect(SettingsNavigation.selectedTab(in: defaults) == .ai)
    }
}
