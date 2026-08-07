import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct SelectionList {
    public struct Item {
        public let label: String
        public let detail: String?
        public let sizeText: String?
        public var isSelected: Bool

        public init(label: String, detail: String? = nil, sizeText: String? = nil, isSelected: Bool = false) {
            self.label = label
            self.detail = detail
            self.sizeText = sizeText
            self.isSelected = isSelected
        }
    }

    public static func run(title: String, items: inout [Item]) -> [Int] {
        guard !items.isEmpty else { return [] }

        var cursor = 0
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)

        var raw = originalTermios
        raw.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        print(ANSIStyle.hideCursor, terminator: "")

        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
            print(ANSIStyle.showCursor, terminator: "")
        }

        func renderList() {
            // Move cursor up to re-render
            if cursor >= 0 {
                for _ in 0..<(items.count + 2) {
                    print("\(ANSIStyle.cursorUp)\(ANSIStyle.clearLine)", terminator: "")
                }
            }

            print("\(ANSIStyle.bold)\(title)\(ANSIStyle.reset)")
            print("\(ANSIStyle.dim)↑/↓ 移动  空格 切换  a 全选  n 全不选  回车 确认\(ANSIStyle.reset)")

            for (i, item) in items.enumerated() {
                let pointer = i == cursor ? "\(ANSIStyle.cyan)❯\(ANSIStyle.reset)" : " "
                let checkbox = item.isSelected
                    ? "\(ANSIStyle.green)✔\(ANSIStyle.reset)"
                    : "\(ANSIStyle.dim)○\(ANSIStyle.reset)"
                let sizeInfo = item.sizeText.map { "  \($0)" } ?? ""
                let label = i == cursor
                    ? "\(ANSIStyle.bold)\(item.label)\(ANSIStyle.reset)"
                    : item.label
                print(" \(pointer) \(checkbox) \(label)\(sizeInfo)")
            }
        }

        // Initial render
        print(String(repeating: "\n", count: items.count + 2), terminator: "")
        renderList()

        while true {
            var byte: UInt8 = 0
            let bytesRead = read(STDIN_FILENO, &byte, 1)
            guard bytesRead == 1 else { continue }

            switch byte {
            case 0x1B: // Escape sequence
                var seq: [UInt8] = [0, 0]
                let r1 = read(STDIN_FILENO, &seq[0], 1)
                let r2 = read(STDIN_FILENO, &seq[1], 1)
                if r1 == 1, r2 == 1, seq[0] == 0x5B {
                    switch seq[1] {
                    case 0x41: // Up
                        cursor = max(0, cursor - 1)
                    case 0x42: // Down
                        cursor = min(items.count - 1, cursor + 1)
                    default:
                        break
                    }
                }
            case 0x20: // Space - toggle
                items[cursor].isSelected.toggle()
            case 0x61, 0x41: // 'a' or 'A' - select all
                for i in items.indices { items[i].isSelected = true }
            case 0x6E, 0x4E: // 'n' or 'N' - deselect all
                for i in items.indices { items[i].isSelected = false }
            case 0x0A, 0x0D: // Enter - confirm
                print("")
                return items.enumerated().compactMap { $0.element.isSelected ? $0.offset : nil }
            case 0x03: // Ctrl+C
                print("")
                return []
            default:
                break
            }

            renderList()
        }
    }
}
