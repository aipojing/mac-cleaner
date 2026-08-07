import Foundation

public struct SystemLogsModule: CleanerModule {
    public let identifier = ModuleIdentifier.systemLogs
    public let displayName = "系统日志"
    public let description = "应用日志、诊断报告和崩溃日志"

    private let scanner = DiskScanner()
    private let home: String
    /// 只清理超过此天数的日志
    private let staleThresholdDays: Int
    private let identityProvider: any FileIdentityProviding

    public init(
        homeDirectory: URL? = nil,
        staleThresholdDays: Int = 30,
        identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider()
    ) {
        self.home = homeDirectory?.path ?? DiskScanner.homeDirectory
        self.staleThresholdDays = staleThresholdDays
        self.identityProvider = identityProvider
    }

    public func isAvailable() -> Bool {
        scanner.directoryExists(at: "\(home)/Library/Logs")
    }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()
        let limiter = context.fileTaskLimiter

        let items = await withTaskGroup(of: [CleanableItem].self) { group in
            group.addTask { (try? await limiter.withPermit { self.scanUserLogs() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanDiagnosticReports() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanCrashReports() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanSpindumpReports() }) ?? [] }

            var all: [CleanableItem] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        // 取消时子任务返回空结果；此处传播取消，不输出残缺结果。
        try Task.checkCancellation()

        return ScanResult(
            module: .systemLogs,
            items: await context.recordIdentities(of: items),
            scanDuration: Date().timeIntervalSince(start)
        )
    }

    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        Deleter().delete(items: items, module: .systemLogs, dryRun: dryRun, useTrash: false)
    }

    /// 由专用扫描器处理的目录，scanUserLogs 跳过这些避免重复计算
    private var excludedFromUserLogs: Set<String> {
        ["DiagnosticReports", "Spindump", "Spin Reports"]
    }

    // MARK: - 用户日志（排除由其他扫描器负责的子目录）

    private func scanUserLogs() -> [CleanableItem] {
        let logsPath = "\(home)/Library/Logs"
        guard scanner.directoryExists(at: logsPath) else { return [] }

        var items: [CleanableItem] = []

        let dirs = scanner.subdirectories(at: logsPath)
        let sizes = scanner.directorySizesBatch(paths: dirs)

        for dir in dirs {
            let name = (dir as NSString).lastPathComponent
            if excludedFromUserLogs.contains(name) { continue }

            let size = sizes[dir] ?? 0
            guard size > 1024 * 1024 else { continue }

            items.append(CleanableItem(
                path: dir,
                displayName: "日志/\(name)",
                size: size,
                category: .systemLogs,
                subcategory: "user-logs",
                evidenceTags: ["log", "diagnostic"]
            ))
        }

        return items
    }

    // MARK: - 诊断报告（排除 Retired 子目录，由 scanCrashReports 单独处理）

    private func scanDiagnosticReports() -> [CleanableItem] {
        let reportPath = "\(home)/Library/Logs/DiagnosticReports"
        guard scanner.directoryExists(at: reportPath) else { return [] }

        // 只枚举直接子项，跳过 Retired（由 scanCrashReports 单独处理）。
        // 每个子项单独生成 CleanableItem：扫描目标与删除目标粒度一致，
        // 避免"扫描子项、删除父目录"的越界风险。
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: reportPath) else { return [] }

        var items: [CleanableItem] = []
        for entry in contents where entry != "Retired" {
            let entryPath = (reportPath as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryPath, isDirectory: &isDir) else { continue }

            let size: Int64
            if isDir.boolValue {
                size = scanner.directorySize(at: entryPath)
            } else {
                let attrs = try? fm.attributesOfItem(atPath: entryPath)
                size = attrs?[.size] as? Int64 ?? 0
            }
            guard size > 0 else { continue }

            items.append(CleanableItem(
                path: entryPath,
                displayName: "诊断报告/\(entry)",
                size: size,
                category: .systemLogs,
                subcategory: "diagnostic-reports",
                evidenceTags: ["log", "diagnostic"]
            ))
        }

        return items
    }

    // MARK: - 已归档崩溃报告（Retired 子目录的直接子项）

    private func scanCrashReports() -> [CleanableItem] {
        let retiredPath = "\(home)/Library/Logs/DiagnosticReports/Retired"
        guard scanner.directoryExists(at: retiredPath) else { return [] }

        // 枚举 Retired 的直接子项，逐项生成候选：
        // 与诊断报告扫描保持相同的扫描/删除粒度，不把 Retired 目录本身作为删除目标。
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: retiredPath) else { return [] }

        var items: [CleanableItem] = []
        for entry in contents {
            let entryPath = (retiredPath as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryPath, isDirectory: &isDir) else { continue }

            let size: Int64
            if isDir.boolValue {
                size = scanner.directorySize(at: entryPath)
            } else {
                let attrs = try? fm.attributesOfItem(atPath: entryPath)
                size = attrs?[.size] as? Int64 ?? 0
            }
            guard size > 0 else { continue }

            items.append(CleanableItem(
                path: entryPath,
                displayName: "已归档崩溃报告/\(entry)",
                size: size,
                category: .systemLogs,
                subcategory: "retired-crashes",
                evidenceTags: ["log", "diagnostic"]
            ))
        }

        return items
    }

    // MARK: - Spindump（独立目录，不在 DiagnosticReports 下）

    private func scanSpindumpReports() -> [CleanableItem] {
        let paths = [
            ("\(home)/Library/Logs/Spindump", "Spindump 报告"),
            ("\(home)/Library/Logs/Spin Reports", "Spin Reports"),
        ]

        var items: [CleanableItem] = []
        for (path, name) in paths {
            guard scanner.directoryExists(at: path) else { continue }
            let size = scanner.directorySize(at: path)
            guard size > 0 else { continue }
            items.append(CleanableItem(
                path: path,
                displayName: name,
                size: size,
                category: .systemLogs,
                subcategory: "spindump",
                evidenceTags: ["log", "diagnostic"]
            ))
        }

        return items
    }
}
