import Foundation
import MacCleanerCore

public enum ANSIStyle {
    public static let reset = "\u{001B}[0m"
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"
    public static let underline = "\u{001B}[4m"

    public static let red = "\u{001B}[31m"
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let blue = "\u{001B}[34m"
    public static let magenta = "\u{001B}[35m"
    public static let cyan = "\u{001B}[36m"
    public static let white = "\u{001B}[37m"
    public static let gray = "\u{001B}[90m"

    public static let bgRed = "\u{001B}[41m"
    public static let bgGreen = "\u{001B}[42m"
    public static let bgYellow = "\u{001B}[43m"
    public static let bgBlue = "\u{001B}[44m"

    public static let clearLine = "\u{001B}[2K"
    public static let cursorUp = "\u{001B}[A"
    public static let hideCursor = "\u{001B}[?25l"
    public static let showCursor = "\u{001B}[?25h"

    public static func colorForSize(_ bytes: Int64) -> String {
        switch bytes {
        case ..<(50 * 1024 * 1024): return green
        case ..<(500 * 1024 * 1024): return yellow
        default: return red
        }
    }

    public static func coloredSize(_ bytes: Int64) -> String {
        let color = colorForSize(bytes)
        return "\(color)\(SizeFormatter.format(bytes: bytes))\(reset)"
    }

    public static func styled(_ text: String, _ styles: String...) -> String {
        let prefix = styles.joined()
        return "\(prefix)\(text)\(reset)"
    }

    public static var isColorSupported: Bool {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        return isatty(STDOUT_FILENO) != 0
    }
}
