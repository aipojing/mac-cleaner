import AppKit

@MainActor
enum MainWindowFinder {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("devclean.main")

    /// 优先通过稳定标识匹配；窗口刚创建、尚未完成 view 注册时，回退到产品标题，
    /// 避免菜单栏“打开”按钮再次创建主窗口。
    static func find(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier == windowIdentifier }
            ?? windows.first { $0.title == "DevClean" && $0.styleMask.contains(.titled) }
    }
}
