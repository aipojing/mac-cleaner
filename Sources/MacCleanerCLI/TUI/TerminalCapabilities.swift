import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct TerminalCapabilities: Sendable {
    public let isInteractive: Bool
    public let supportsColor: Bool
    public let width: Int

    public init() {
        self.isInteractive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        self.supportsColor = ANSIStyle.isColorSupported
        self.width = Self.detectWidth()
    }

    private static func detectWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"],
           let width = Int(columns) {
            return width
        }
        return 80
    }
}
