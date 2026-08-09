import Foundation
import MacCleanerCore
import AppKit

/// 仅保存关联文件的展示总计；删除前的具体文件清单始终重新扫描并校验身份。
private final class AppUninstallerResidualTotalStore {
    private struct Entry: Codable {
        let path: String
        let bundleSize: Int64
        let residualSize: Int64
        let savedAt: Date
    }

    private let defaults: UserDefaults
    private let key = "appUninstaller.residualTotals.v1"
    private let validity: TimeInterval = 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func cachedResidualTotal(for app: InstalledApp, now: Date = .now) -> Int64? {
        guard let entry = entries()[cacheKey(for: app)],
              entry.path == app.path,
              entry.bundleSize == app.bundleSize,
              now.timeIntervalSince(entry.savedAt) < validity
        else { return nil }
        return entry.residualSize
    }

    func save(residualTotal: Int64, for app: InstalledApp, now: Date = .now) {
        var savedEntries = entries()
        savedEntries[cacheKey(for: app)] = Entry(
            path: app.path,
            bundleSize: app.bundleSize,
            residualSize: residualTotal,
            savedAt: now
        )
        persist(savedEntries)
    }

    func remove(for app: InstalledApp) {
        var savedEntries = entries()
        savedEntries.removeValue(forKey: cacheKey(for: app))
        persist(savedEntries)
    }

    private func cacheKey(for app: InstalledApp) -> String {
        "\(app.bundleID)|\(app.path)"
    }

    private func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: key),
              let savedEntries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return savedEntries
    }

    private func persist(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}

@Observable
@MainActor
final class AppUninstallerViewModel {
    enum Phase {
        case idle
        case loadingApps
        case ready
        case scanningResiduals
        case uninstalling
    }

    var phase: Phase = .idle
    var apps: [InstalledApp] = []
    var selectedApp: InstalledApp?
    var residuals: AppResidualFiles?
    private var residualTotalsByAppID: [UUID: Int64] = [:]
    private var residualCacheByAppID: [UUID: AppResidualFiles] = [:]
    var selectedResidualPaths: Set<String> = []
    var searchText = ""
    var report: UninstallReport?
    private(set) var residualPrefetchCompleted = 0
    private(set) var residualPrefetchTotal = 0

    private let service: any AppUninstalling
    private let residualTotalStore: AppUninstallerResidualTotalStore
    private var loadAppsTask: Task<Void, Never>?
    private var residualsTask: Task<Void, Never>?
    private var residualPrefetchTask: Task<Void, Never>?
    private var residualScanTasksByAppID: [UUID: Task<AppResidualFiles, Never>] = [:]
    private var residualPrefetchGeneration = UUID()
    private let residualPrefetchConcurrency = 2

    init(service: any AppUninstalling = AppUninstallerService()) {
        self.service = service
        self.residualTotalStore = AppUninstallerResidualTotalStore()
    }

    var filteredApps: [InstalledApp] {
        if searchText.isEmpty { return apps }
        let query = searchText.lowercased()
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    var isPrefetchingResidualTotals: Bool {
        residualPrefetchTotal > 0 && residualPrefetchCompleted < residualPrefetchTotal
    }

    func loadApps() {
        // 重入保护：已有扫描在途时直接返回，避免重复扫描乱序写回。
        guard loadAppsTask == nil else { return }
        stopBackgroundResidualPrefetch()
        residualTotalsByAppID = [:]
        residualCacheByAppID = [:]
        phase = .loadingApps
        loadAppsTask = Task {
            let result = await service.scanApplications()
            guard !Task.isCancelled else { return }
            apps = result
            phase = .ready
            loadAppsTask = nil
            for app in result {
                if let cachedTotal = residualTotalStore.cachedResidualTotal(for: app) {
                    residualTotalsByAppID[app.id] = cachedTotal
                }
            }
            startBackgroundResidualPrefetch(for: result.filter {
                residualTotalsByAppID[$0.id] == nil
            })
        }
    }

    /// 仅在卸载器页面可见时补全各应用的关联文件总计。
    /// 最多两个应用同时扫描：单个超大应用不会堵住整条队列，而全局 FTS 闸门
    /// 仍把实际目录遍历限制为两个，避免增加磁盘 IO 峰值。
    func stopBackgroundResidualPrefetch() {
        residualPrefetchGeneration = UUID()
        residualPrefetchTask?.cancel()
        residualPrefetchTask = nil
        residualPrefetchCompleted = 0
        residualPrefetchTotal = 0
    }

    func selectApp(_ app: InstalledApp) {
        beginSelection(app)
        if let cached = residualCacheByAppID[app.id] {
            applyResiduals(cached, for: app)
            return
        }
        residualsTask = Task { await loadResiduals(for: app) }
    }

    /// 测试入口：同步等待残留扫描完成
    func selectAppForTesting(_ app: InstalledApp) async {
        beginSelection(app)
        if let cached = residualCacheByAppID[app.id] {
            applyResiduals(cached, for: app)
            return
        }
        await loadResiduals(for: app)
    }

    private func beginSelection(_ app: InstalledApp) {
        // 取消上一次残留扫描：任务取消 + 身份校验双保险，
        // 防止快速切换应用时旧扫描结果覆盖新选择（删错文件风险）。
        residualsTask?.cancel()
        residualsTask = nil
        selectedApp = app
        residuals = nil
        selectedResidualPaths = []
        report = nil
        phase = .scanningResiduals
    }

    private func loadResiduals(for app: InstalledApp) async {
        let result = await cachedResiduals(for: app)
        // 身份校验：扫描期间用户已改选其他应用时丢弃过期结果。
        guard !Task.isCancelled, selectedApp == app else { return }
        applyResiduals(result, for: app)
    }

    private func applyResiduals(_ result: AppResidualFiles, for app: InstalledApp) {
        guard selectedApp == app else { return }
        residuals = result
        // 残留默认不选中，等用户逐项显式勾选；
        // 身份缺失的条目保持未选中且禁止勾选。
        selectedResidualPaths = []
        phase = .ready
    }

    private func cachedResiduals(for app: InstalledApp) async -> AppResidualFiles {
        if let cached = residualCacheByAppID[app.id] { return cached }

        let scanTask: Task<AppResidualFiles, Never>
        if let inFlight = residualScanTasksByAppID[app.id] {
            scanTask = inFlight
        } else {
            let service = service
            scanTask = Task.detached(priority: .utility) {
                await service.findResiduals(for: app)
            }
            residualScanTasksByAppID[app.id] = scanTask
        }

        let result = await scanTask.value
        residualScanTasksByAppID.removeValue(forKey: app.id)
        residualCacheByAppID[app.id] = result
        residualTotalsByAppID[app.id] = result.totalSize
        residualTotalStore.save(residualTotal: result.totalSize, for: app)
        return result
    }

    private func startBackgroundResidualPrefetch(for apps: [InstalledApp]) {
        guard !apps.isEmpty else { return }

        let generation = UUID()
        residualPrefetchGeneration = generation
        residualPrefetchCompleted = 0
        residualPrefetchTotal = apps.count
        residualPrefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runBackgroundResidualPrefetch(apps, generation: generation)
        }
    }

    private func runBackgroundResidualPrefetch(
        _ apps: [InstalledApp], generation: UUID
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var pendingApps = ArraySlice(apps)

            func scheduleNextApp() {
                guard let app = pendingApps.popFirst() else { return }
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.prefetchResidualTotal(for: app, generation: generation)
                }
            }

            for _ in 0..<min(residualPrefetchConcurrency, pendingApps.count) {
                scheduleNextApp()
            }

            while await group.next() != nil {
                guard !Task.isCancelled,
                      residualPrefetchGeneration == generation
                else {
                    group.cancelAll()
                    break
                }
                scheduleNextApp()
            }
        }

        guard !Task.isCancelled,
              residualPrefetchGeneration == generation
        else { return }
        residualPrefetchTask = nil
    }

    private func prefetchResidualTotal(for app: InstalledApp, generation: UUID) async {
        guard !Task.isCancelled,
              residualPrefetchGeneration == generation
        else { return }

        _ = await cachedResiduals(for: app)

        guard !Task.isCancelled,
              residualPrefetchGeneration == generation
        else { return }
        residualPrefetchCompleted += 1
    }

    func selectAppFromURL(_ url: URL) {
        let path = url.path
        guard path.hasSuffix(".app"),
              let match = apps.first(where: { $0.path == path })
        else { return }
        selectApp(match)
    }

    func toggleResidual(_ item: ResidualItem) {
        // 身份缺失的条目不允许选择：无法验证目标是否仍是扫描时的对象。
        guard item.fileIdentity != nil else { return }
        if selectedResidualPaths.contains(item.path) {
            selectedResidualPaths.remove(item.path)
        } else {
            selectedResidualPaths.insert(item.path)
        }
    }

    /// 条目是否可被选择（具备扫描身份）。
    func canSelect(_ item: ResidualItem) -> Bool {
        item.fileIdentity != nil
    }

    func isResidualSelected(_ item: ResidualItem) -> Bool {
        selectedResidualPaths.contains(item.path)
    }

    /// 可安全移入废纸篓的残留路径；无身份信息的项目永远不会进入全选范围。
    private var selectableResidualPaths: Set<String> {
        guard let residuals else { return [] }
        return Set(
            residuals.groups.flatMap(\.items)
                .filter { $0.fileIdentity != nil }
                .map(\.path)
        )
    }

    var selectableResidualCount: Int {
        selectableResidualPaths.count
    }

    var selectedSelectableResidualCount: Int {
        selectedResidualPaths.intersection(selectableResidualPaths).count
    }

    var hasSelectableResiduals: Bool {
        !selectableResidualPaths.isEmpty
    }

    var areAllSelectableResidualsSelected: Bool {
        let selectablePaths = selectableResidualPaths
        return !selectablePaths.isEmpty && selectablePaths.isSubset(of: selectedResidualPaths)
    }

    /// 在全选和取消全选间切换，且仅作用于可验证身份的残留项。
    func toggleSelectAllResiduals() {
        let selectablePaths = selectableResidualPaths
        guard !selectablePaths.isEmpty else { return }

        if selectablePaths.isSubset(of: selectedResidualPaths) {
            selectedResidualPaths.subtract(selectablePaths)
        } else {
            selectedResidualPaths.formUnion(selectablePaths)
        }
    }

    /// 应用本体加上已扫描到的关联文件。未扫描过时只返回应用本体大小。
    func displaySize(for app: InstalledApp) -> Int64 {
        app.bundleSize + (residualTotalsByAppID[app.id] ?? 0)
    }

    func hasScannedResidualTotal(for app: InstalledApp) -> Bool {
        residualTotalsByAppID[app.id] != nil
    }

    var selectedResidualSize: Int64 {
        guard let residuals else { return 0 }
        return residuals.groups.flatMap(\.items)
            .filter { selectedResidualPaths.contains($0.path) }
            .reduce(0) { $0 + $1.size }
    }

    func uninstall() {
        guard let app = selectedApp, let residuals else { return }
        phase = .uninstalling

        let selected = residuals.groups.flatMap(\.items)
            .filter { selectedResidualPaths.contains($0.path) }

        Task.detached {
            let result = await self.service.uninstall(app: app, residualItems: selected)
            await MainActor.run {
                self.report = result
                self.apps.removeAll { $0.id == app.id }
                self.residualTotalsByAppID.removeValue(forKey: app.id)
                self.residualCacheByAppID.removeValue(forKey: app.id)
                self.residualTotalStore.remove(for: app)
                self.selectedApp = nil
                self.residuals = nil
                self.phase = .ready
            }
        }
    }

    func appIcon(for app: InstalledApp) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.path)
    }
}
