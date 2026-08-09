import SwiftUI

struct SettingsView: View {
    @Bindable var themeManager: ThemeManager
    @Bindable var languageManager: LanguageManager
    let environment: AppEnvironment
    @State private var showRestartHint = false
    @AppStorage(SettingsNavigation.selectedTabStorageKey) private var selectedTab = SettingsTab.appearance.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            appearanceTab
                .tabItem {
                    Label("外观", systemImage: "paintbrush")
                }
                .tag(SettingsTab.appearance.rawValue)

            languageTab
                .tabItem {
                    Label("语言", systemImage: "globe")
                }
                .tag(SettingsTab.language.rawValue)

            // VM 由 AppEnvironment 惰性持有，body 重算不会重建，
            // 正在输入的 API Key、连接状态、隐私弹窗状态得以保留。
            AISettingsView(viewModel: environment.aiSettingsViewModel)
            .tabItem {
                Label("AI", systemImage: "sparkles")
            }
            .tag(SettingsTab.ai.rawValue)
        }
        .frame(width: 420, height: 420)
    }

    // MARK: - 外观

    private var appearanceTab: some View {
        Form {
            Section("主题色") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(52)), count: 7), spacing: 10) {
                    ForEach(ThemeManager.AccentTheme.allCases) { theme in
                        themeCircle(theme)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("窗口外观") {
                Text("深色/浅色模式跟随系统设置")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link("打开系统外观设置", destination: URL(string: "x-apple.systempreferences:com.apple.preference.general")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func themeCircle(_ theme: ThemeManager.AccentTheme) -> some View {
        let isSelected = themeManager.selectedTheme == theme

        return Button {
            themeManager.selectedTheme = theme
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(theme.color ?? .accentColor)
                        .frame(width: 28, height: 28)

                    if theme == .system {
                        Circle()
                            .fill(
                                AngularGradient(
                                    colors: [.blue, .purple, .pink, .orange, .green, .blue],
                                    center: .center
                                )
                            )
                            .frame(width: 28, height: 28)
                    }

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                }

                Text(theme.displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 语言

    private var languageTab: some View {
        Form {
            Section("应用语言") {
                Picker("语言", selection: $languageManager.selectedLanguage) {
                    ForEach(LanguageManager.AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: languageManager.selectedLanguage) { _, _ in
                    showRestartHint = true
                }
            }

            Section {
                if showRestartHint {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已切换。主界面立即生效，系统菜单栏（文件/编辑/窗口）需重启应用。")
                            .font(.caption)
                    }
                } else {
                    Text("选择「跟随系统」时使用 macOS 系统语言。切换为中文或英文将覆盖系统设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Link("打开系统语言设置",
                     destination: URL(string: "x-apple.systempreferences:com.apple.preference.language")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
