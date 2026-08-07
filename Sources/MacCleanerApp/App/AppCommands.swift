import SwiftUI

struct AppCommands: Commands {
    @Binding var scanAction: () -> Void

    var body: some Commands {
        // 替换默认 New Window
        CommandGroup(replacing: .newItem) {
            Button("新建扫描") {
                scanAction()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // Cmd+, 由 Settings scene 自动注册，无需重复
    }
}
