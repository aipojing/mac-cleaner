import AppKit
import SwiftUI

struct MainWindowTagger: NSViewRepresentable {
    static let windowIdentifier = MainWindowFinder.windowIdentifier

    func makeNSView(context: Context) -> TaggingView {
        TaggingView()
    }

    func updateNSView(_ nsView: TaggingView, context: Context) {}

    final class TaggingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = MainWindowTagger.windowIdentifier
        }
    }
}
