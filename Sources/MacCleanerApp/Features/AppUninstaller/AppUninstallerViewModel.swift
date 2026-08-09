import Foundation
import MacCleanerCore
import AppKit

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
    var selectedResidualPaths: Set<String> = []
    var searchText = ""
    var report: UninstallReport?

    private let service: any AppUninstalling
    private var loadAppsTask: Task<Void, Never>?
    private var residualsTask: Task<Void, Never>?

    init(service: any AppUninstalling = AppUninstallerService()) {
        self.service = service
    }

    var filteredApps: [InstalledApp] {
        if searchText.isEmpty { return apps }
        let query = searchText.lowercased()
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    func loadApps() {
        // 重入保护：已有扫描在途时直接返回，避免重复扫描乱序写回。
        guard loadAppsTask == nil else { return }
        phase = .loadingApps
        loadAppsTask = Task {
            let result = await service.scanApplications()
            apps = result
            phase = .ready
            loadAppsTask = nil
        }
    }

    func selectApp(_ app: InstalledApp) {
        beginSelection(app)
        residualsTask = Task { await loadResiduals(for: app) }
    }

    /// 测试入口：同步等待残留扫描完成
    func selectAppForTesting(_ app: InstalledApp) async {
        beginSelection(app)
        await loadResiduals(for: app)
    }

    private func beginSelection(_ app: InstalledApp) {
        // 取消上一次残留扫描：任务取消 + 身份校验双保险，
        // 防止快速切换应用时旧扫描结果覆盖新选择（删错文件风险）。
        residualsTask?.cancel()
        residualsTask = nil
        selectedApp = app
        residuals = nil
        residualTotalsByAppID.removeValue(forKey: app.id)
        selectedResidualPaths = []
        report = nil
        phase = .scanningResiduals
    }

    private func loadResiduals(for app: InstalledApp) async {
        let result = await service.findResiduals(for: app)
        // 身份校验：扫描期间用户已改选其他应用时丢弃过期结果。
        guard !Task.isCancelled, selectedApp == app else { return }
        residuals = result
        residualTotalsByAppID[app.id] = result.totalSize
        // 残留默认不选中，等用户逐项显式勾选；
        // 身份缺失的条目保持未选中且禁止勾选。
        selectedResidualPaths = []
        phase = .ready
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
