import Foundation

/// 定时扫描配置
public struct ScheduledScanConfig: Codable, Sendable {
    /// 是否启用定时扫描
    public let enabled: Bool
    /// 扫描间隔（秒）
    public let intervalSeconds: Int
    /// 低磁盘空间阈值（百分比，低于此值触发通知）
    public let lowSpaceThresholdPercent: Double
    /// 是否启用低磁盘空间通知
    public let notifyOnLowSpace: Bool
    /// 上次扫描时间
    public let lastScanDate: Date?

    public init(
        enabled: Bool = false,
        intervalSeconds: Int = 86400,
        lowSpaceThresholdPercent: Double = 10,
        notifyOnLowSpace: Bool = true,
        lastScanDate: Date? = nil
    ) {
        self.enabled = enabled
        self.intervalSeconds = intervalSeconds
        self.lowSpaceThresholdPercent = lowSpaceThresholdPercent
        self.notifyOnLowSpace = notifyOnLowSpace
        self.lastScanDate = lastScanDate
    }

    /// 每日扫描
    public static let daily = ScheduledScanConfig(enabled: true, intervalSeconds: 86400)
    /// 每周扫描
    public static let weekly = ScheduledScanConfig(enabled: true, intervalSeconds: 604800)
    /// 已禁用
    public static let disabled = ScheduledScanConfig(enabled: false)

    public func withLastScanDate(_ date: Date) -> ScheduledScanConfig {
        ScheduledScanConfig(
            enabled: enabled,
            intervalSeconds: intervalSeconds,
            lowSpaceThresholdPercent: lowSpaceThresholdPercent,
            notifyOnLowSpace: notifyOnLowSpace,
            lastScanDate: date
        )
    }

    public func withEnabled(_ enabled: Bool) -> ScheduledScanConfig {
        ScheduledScanConfig(
            enabled: enabled,
            intervalSeconds: intervalSeconds,
            lowSpaceThresholdPercent: lowSpaceThresholdPercent,
            notifyOnLowSpace: notifyOnLowSpace,
            lastScanDate: lastScanDate
        )
    }
}
