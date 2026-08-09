import AppKit
import Testing
@testable import DevClean

@MainActor
@Suite("Main window finder")
struct MainWindowFinderTests {
    @Test("未完成标签注册的 DevClean 窗口也会被复用")
    func findsUntaggedDevCleanWindow() {
        let window = NSWindow()
        window.title = "DevClean"

        #expect(MainWindowFinder.find(in: [window]) === window)
    }

    @Test("优先选择带主窗口标签的窗口")
    func prefersTaggedMainWindow() {
        let untagged = NSWindow()
        untagged.title = "DevClean"
        let tagged = NSWindow()
        tagged.identifier = MainWindowTagger.windowIdentifier

        #expect(MainWindowFinder.find(in: [untagged, tagged]) === tagged)
    }
}
