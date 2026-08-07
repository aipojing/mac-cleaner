import Foundation

/// 定时扫描服务：后台周期扫描 + 低磁盘空间检测
public actor ScheduledScanService {
    public static let shared = ScheduledScanService()

    private var config: ScheduledScanConfig
    private var scanTask: Task<Void, Never>?
    private let storePath: String
    private let exclusionManager: any ExclusionManaging

    /// 最近一次扫描的候选占用空间（不含任何推荐/可安全回收判断）
    private(set) public var lastScanCandidateBytes: Int64 = 0
    /// 最近一次扫描结果
    private(set) public var lastScanResults: [ScanResult] = []

    public init(storePath: String? = nil, exclusionManager: any ExclusionManaging = ExclusionManager.shared) {
        self.storePath = storePath ?? Self.defaultStorePath()
        self.exclusionManager = exclusionManager
        self.config = Self.loadConfig(from: self.storePath)
    }

    // MARK: - 配置

    public var currentConfig: ScheduledScanConfig { config }

    public func updateConfig(_ newConfig: ScheduledScanConfig) {
        config = newConfig
        saveConfig()
        if newConfig.enabled {
            startSchedule()
        } else {
            stopSchedule()
        }
    }

    // MARK: - 调度

    public func startIfEnabled() {
        guard config.enabled else { return }
        startSchedule()
    }

    private func startSchedule() {
        scanTask?.cancel()
        let interval = config.intervalSeconds
        scanTask = Task {
            while !Task.isCancelled {
                // 计算距下次扫描的等待时间
                let sleepSeconds: Int
                if let lastScan = config.lastScanDate {
                    let elapsed = Date().timeIntervalSince(lastScan)
                    let remaining = Double(interval) - elapsed
                    if remaining <= 0 {
                        await performBackgroundScan()
                        sleepSeconds = interval
                    } else {
                        sleepSeconds = max(1, Int(remaining))
                    }
                } else {
                    await performBackgroundScan()
                    sleepSeconds = interval
                }

                try? await Task.sleep(for: .seconds(sleepSeconds))
            }
        }
    }

    private func stopSchedule() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - 后台扫描

    private func performBackgroundScan() async {
        let results = await scanAndFilter(modules: ModuleRegistry.availableModules())

        lastScanResults = results
        lastScanCandidateBytes = PhysicalSizeCalculator.uniqueAllocatedBytes(
            in: results.flatMap(\.items)
        )
        config = config.withLastScanDate(Date())
        saveConfig()

        // 检查低磁盘空间
        if config.notifyOnLowSpace {
            await checkLowDiskSpace()
        }
    }

    /// 测试入口：扫描指定模块、应用统一排除过滤并记录候选统计
    func performScanForTesting(modules: [any CleanerModule]) async -> [ScanResult] {
        let results = await scanAndFilter(modules: modules)
        lastScanResults = results
        lastScanCandidateBytes = PhysicalSizeCalculator.uniqueAllocatedBytes(
            in: results.flatMap(\.items)
        )
        return results
    }

    /// 通过统一 coordinator 并行扫描模块，并对每个结果应用统一排除过滤器
    private func scanAndFilter(modules: [any CleanerModule]) async -> [ScanResult] {
        let filter = ScanResultFilter(exclusionManager: exclusionManager)
        let coordinator = ScanCoordinator(modules: modules)

        // 模块失败由 coordinator 跳过；整体取消时后台扫描返回空
        guard let scanned = try? await coordinator.scan() else { return [] }

        var results: [ScanResult] = []
        for result in scanned {
            results.append(await filter.apply(to: result))
        }
        return results
    }

    private func checkLowDiskSpace() async {
        let monitor = DiskSpaceMonitor.shared
        await monitor.refresh()
        guard let info = await monitor.current else { return }

        if info.freePercent < config.lowSpaceThresholdPercent {
            await sendLowSpaceNotification(
                freeSpace: info.formattedFree,
                candidateBytes: lastScanCandidateBytes
            )
        }
    }

    private func sendLowSpaceNotification(freeSpace: String, candidateBytes: Int64) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        if settings.authorizationStatus != .authorized {
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge])) ?? false
            guard granted else { return }
        }

        let content = UNMutableNotificationContent()
        content.title = "磁盘空间不足"
        content.body = "剩余 \(freeSpace)，发现候选占用空间 \(SizeFormatter.format(bytes: candidateBytes))"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "low-space-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
        #endif
    }

    // MARK: - 持久化

    private func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(config) else { return }

        let dir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
    }

    private static func loadConfig(from path: String) -> ScheduledScanConfig {
        guard let data = FileManager.default.contents(atPath: path) else { return .disabled }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ScheduledScanConfig.self, from: data)) ?? .disabled
    }

    private static func defaultStorePath() -> String {
        let home = DiskScanner.homeDirectory
        return "\(home)/Library/Application Support/MacCleaner/scheduled-scan.json"
    }
}

#if canImport(UserNotifications)
import UserNotifications
#endif
