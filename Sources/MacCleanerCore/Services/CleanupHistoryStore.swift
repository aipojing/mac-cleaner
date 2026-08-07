import Foundation

/// 清理历史持久化存储
public actor CleanupHistoryStore {
    public static let shared = CleanupHistoryStore()

    private var records: [CleanupRecord]
    private let storePath: String
    private let maxRecords: Int

    public init(storePath: String? = nil, maxRecords: Int = 500) {
        self.storePath = storePath ?? Self.defaultStorePath()
        self.maxRecords = maxRecords
        self.records = Self.load(from: self.storePath)
    }

    // MARK: - 写入

    /// 从 CleanupReport 数组创建并保存一条记录
    public func record(reports: [CleanupReport], dryRun: Bool = false) {
        let modules = reports.map { report in
            ModuleCleanupSummary(
                moduleID: report.module.rawValue,
                moduleName: report.module.displayName,
                freed: report.actualFreed,
                itemCount: report.successCount,
                failedCount: report.failureCount
            )
        }

        let record = CleanupRecord(
            modules: modules,
            totalExpected: reports.reduce(0) { $0 + $1.expectedSize },
            totalFreed: reports.reduce(0) { $0 + $1.actualFreed },
            totalItems: reports.reduce(0) { $0 + $1.successCount },
            totalFailed: reports.reduce(0) { $0 + $1.failureCount },
            dryRun: dryRun
        )

        records.append(record)

        // 保留最近 maxRecords 条
        if records.count > maxRecords {
            records = Array(records.suffix(maxRecords))
        }

        save()
    }

    // MARK: - 查询

    public var allRecords: [CleanupRecord] {
        records.sorted { $0.timestamp > $1.timestamp }
    }

    public var recordCount: Int { records.count }

    /// 累计释放空间
    public var cumulativeFreed: Int64 {
        records.filter { !$0.dryRun }.reduce(0) { $0 + $1.totalFreed }
    }

    /// 最近一次清理时间
    public var lastCleanupDate: Date? {
        records.filter { !$0.dryRun }.max(by: { $0.timestamp < $1.timestamp })?.timestamp
    }

    /// 聚合统计
    public func stats(days: Int = 30) -> CleanupStats {
        let realRecords = records.filter { !$0.dryRun }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let recentRecords = realRecords.filter { $0.timestamp >= cutoff }

        // 按模块聚合
        var moduleFreed: [String: (name: String, freed: Int64)] = [:]
        for record in realRecords {
            for module in record.modules {
                let existing = moduleFreed[module.moduleID]
                moduleFreed[module.moduleID] = (
                    name: module.moduleName,
                    freed: (existing?.freed ?? 0) + module.freed
                )
            }
        }
        let topModules = moduleFreed
            .map { (moduleID: $0.key, moduleName: $0.value.name, totalFreed: $0.value.freed) }
            .sorted { $0.totalFreed > $1.totalFreed }

        // 按日聚合
        let calendar = Calendar.current
        var dailyMap: [DateComponents: Int64] = [:]
        for record in recentRecords {
            let dayComponents = calendar.dateComponents([.year, .month, .day], from: record.timestamp)
            dailyMap[dayComponents, default: 0] += record.totalFreed
        }
        let dailyFreed = dailyMap
            .compactMap { components, freed -> (date: Date, freed: Int64)? in
                guard let date = calendar.date(from: components) else { return nil }
                return (date: date, freed: freed)
            }
            .sorted { $0.date < $1.date }

        return CleanupStats(
            totalRecords: realRecords.count,
            cumulativeFreed: cumulativeFreed,
            lastCleanupDate: lastCleanupDate,
            topModulesByFreed: topModules,
            dailyFreed: dailyFreed
        )
    }

    // MARK: - 持久化

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }

        let dir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
    }

    private static func load(from path: String) -> [CleanupRecord] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CleanupRecord].self, from: data)) ?? []
    }

    private static func defaultStorePath() -> String {
        let home = DiskScanner.homeDirectory
        return "\(home)/Library/Application Support/MacCleaner/cleanup-history.json"
    }
}
