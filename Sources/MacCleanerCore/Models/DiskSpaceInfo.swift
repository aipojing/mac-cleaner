import Foundation

public struct DiskSpaceInfo: Sendable {
    public let totalBytes: Int64
    public let freeBytes: Int64

    public var usedBytes: Int64 { totalBytes - freeBytes }
    public var freePercent: Double { totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) * 100 : 0 }
    public var usedPercent: Double { 100 - freePercent }

    public var formattedFree: String { SizeFormatter.format(bytes: freeBytes) }
    public var formattedUsed: String { SizeFormatter.format(bytes: usedBytes) }
    public var formattedTotal: String { SizeFormatter.format(bytes: totalBytes) }

    public init(totalBytes: Int64, freeBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    public static func current() throws -> DiskSpaceInfo {
        let url = URL(fileURLWithPath: "/")
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        return DiskSpaceInfo(totalBytes: total, freeBytes: free)
    }
}
