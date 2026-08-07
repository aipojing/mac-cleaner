import Foundation

extension Int64 {
    public var formattedSize: String {
        SizeFormatter.format(bytes: self)
    }
}

public struct SizeFormatter: Sendable {
    private static let units: [(String, Int64)] = [
        ("TB", 1024 * 1024 * 1024 * 1024),
        ("GB", 1024 * 1024 * 1024),
        ("MB", 1024 * 1024),
        ("KB", 1024),
    ]

    public static func format(bytes: Int64) -> String {
        if bytes == 0 { return "0 B" }

        for (unit, threshold) in units {
            if bytes >= threshold {
                let value = Double(bytes) / Double(threshold)
                if value >= 100 {
                    return String(format: "%.0f %@", value, unit)
                } else if value >= 10 {
                    return String(format: "%.1f %@", value, unit)
                } else {
                    return String(format: "%.2f %@", value, unit)
                }
            }
        }
        return "\(bytes) B"
    }
}
