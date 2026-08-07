import Foundation
import MacCleanerCore

extension SizeFormatter {
    public static func coloredFormat(bytes: Int64) -> String {
        ANSIStyle.coloredSize(bytes)
    }
}
