import Foundation

/// 单次清理记录
public struct CleanupRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let modules: [ModuleCleanupSummary]
    public let totalExpected: Int64
    public let totalFreed: Int64
    public let totalItems: Int
    public let totalFailed: Int
    public let dryRun: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        modules: [ModuleCleanupSummary],
        totalExpected: Int64,
        totalFreed: Int64,
        totalItems: Int,
        totalFailed: Int,
        dryRun: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modules = modules
        self.totalExpected = totalExpected
        self.totalFreed = totalFreed
        self.totalItems = totalItems
        self.totalFailed = totalFailed
        self.dryRun = dryRun
    }
}

/// 单个模块的清理摘要
public struct ModuleCleanupSummary: Codable, Sendable {
    public let moduleID: String
    public let moduleName: String
    public let freed: Int64
    public let itemCount: Int
    public let failedCount: Int

    public init(moduleID: String, moduleName: String, freed: Int64, itemCount: Int, failedCount: Int) {
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.freed = freed
        self.itemCount = itemCount
        self.failedCount = failedCount
    }
}

/// 清理历史聚合统计
public struct CleanupStats: Sendable {
    public let totalRecords: Int
    public let cumulativeFreed: Int64
    public let lastCleanupDate: Date?
    public let topModulesByFreed: [(moduleID: String, moduleName: String, totalFreed: Int64)]

    /// 最近 N 天的每日释放量
    public let dailyFreed: [(date: Date, freed: Int64)]
}
