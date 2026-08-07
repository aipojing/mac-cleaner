import Foundation

public struct TableRenderer {
    public struct Column {
        public let header: String
        public let minWidth: Int
        public let alignment: Alignment

        public enum Alignment {
            case left, right
        }

        public init(header: String, minWidth: Int = 0, alignment: Alignment = .left) {
            self.header = header
            self.minWidth = minWidth
            self.alignment = alignment
        }
    }

    public static func render(columns: [Column], rows: [[String]]) {
        var widths = columns.map { max($0.header.count, $0.minWidth) }

        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], stripANSI(cell).count)
            }
        }

        // Header
        let headerLine = columns.enumerated().map { i, col in
            pad(col.header, width: widths[i], alignment: col.alignment)
        }.joined(separator: "  ")
        print("\(ANSIStyle.bold)\(headerLine)\(ANSIStyle.reset)")

        // Separator
        let separator = widths.map { String(repeating: "─", count: $0) }.joined(separator: "──")
        print("\(ANSIStyle.dim)\(separator)\(ANSIStyle.reset)")

        // Rows
        for row in rows {
            let line = row.enumerated().map { i, cell in
                guard i < widths.count else { return cell }
                return pad(cell, width: widths[i], alignment: columns[i].alignment)
            }.joined(separator: "  ")
            print(line)
        }
    }

    private static func pad(_ text: String, width: Int, alignment: Column.Alignment) -> String {
        let visibleLength = stripANSI(text).count
        let padding = max(0, width - visibleLength)
        switch alignment {
        case .left:
            return text + String(repeating: " ", count: padding)
        case .right:
            return String(repeating: " ", count: padding) + text
        }
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }
}
