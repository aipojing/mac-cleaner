import Foundation

public struct ProgressBar {
    private let total: Int
    private let width: Int
    private var current: Int = 0

    public init(total: Int, width: Int = 30) {
        self.total = max(total, 1)
        self.width = width
    }

    public mutating func update(to value: Int, message: String = "") {
        current = value
        render(message: message)
    }

    public mutating func increment(message: String = "") {
        current += 1
        render(message: message)
    }

    public func finish(message: String = "完成") {
        let filled = String(repeating: "█", count: width)
        print("\r\(ANSIStyle.clearLine)\(ANSIStyle.green)[\(filled)] 100%\(ANSIStyle.reset) \(message)")
    }

    private func render(message: String) {
        let progress = Double(current) / Double(total)
        let filledCount = Int(progress * Double(width))
        let emptyCount = width - filledCount

        let filled = String(repeating: "█", count: filledCount)
        let empty = String(repeating: "░", count: emptyCount)
        let percent = Int(progress * 100)

        let color = percent < 50 ? ANSIStyle.yellow : ANSIStyle.green
        let truncatedMsg = String(message.prefix(40))

        print("\r\(ANSIStyle.clearLine)\(color)[\(filled)\(empty)] \(percent)%\(ANSIStyle.reset) \(truncatedMsg)", terminator: "")
        fflush(stdout)
    }
}
