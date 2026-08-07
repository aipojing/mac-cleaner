import SwiftUI

@main
struct MacCleanerApp: App {
    @State private var environment = AppEnvironment.production()
    @State private var menuBarVM = MenuBarViewModel()
    @State private var themeManager = ThemeManager.shared
    @State private var languageManager = LanguageManager.shared
    @State private var scanAction: () -> Void = {}

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(onScanRequested: $scanAction, environment: environment)
                .tint(themeManager.accentColor)
                .environment(\.locale, languageManager.effectiveLocale)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 600)
        .commands {
            AppCommands(scanAction: $scanAction)
        }

        Settings {
            SettingsView(themeManager: themeManager, languageManager: languageManager, environment: environment)
                .environment(\.locale, languageManager.effectiveLocale)
        }

        MenuBarExtra {
            MenuBarPopoverView(viewModel: menuBarVM)
        } label: {
            Label(menuBarVM.menuBarLabel, systemImage: "internaldrive")
        }
        .menuBarExtraStyle(.window)
    }
}
