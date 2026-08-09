import Foundation

/// App 中可选的大文件扫描阈值，持久化为 MB 整数以便跨启动沿用。
enum LargeFileThreshold: Int, CaseIterable, Identifiable {
    case megabytes100 = 100
    case megabytes200 = 200
    case megabytes500 = 500
    case gigabyte1 = 1024

    static let storageKey = "largeFileMinimumSizeMB"
    static let `default` = LargeFileThreshold.megabytes100

    var id: Int { rawValue }

    var displayName: String {
        rawValue >= 1024 ? "\(rawValue / 1024) GB" : "\(rawValue) MB"
    }

    var minimumAllocatedSize: Int64 {
        Int64(rawValue) * 1024 * 1024
    }
}
