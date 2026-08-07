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
    var selectedResidualPaths: Set<String> = []
    var searchText = ""
    var report: UninstallReport?

    private let service: any AppUninstalling

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
        phase = .loadingApps
        Task {
            let result = await service.scanApplications()
            apps = result
            phase = .ready
        }
    }

    func selectApp(_ app: InstalledApp) {
        selectedApp = app
        residuals = nil
        selectedResidualPaths = []
        report = nil
        phase = .scanningResiduals

        Task { await loadResiduals(for: app) }
    }

    /// 测试入口：同步等待残留扫描完成
    func selectAppForTesting(_ app: InstalledApp) async {
        selectedApp = app
        residuals = nil
        selectedResidualPaths = []
        report = nil
        phase = .scanningResiduals
        await loadResiduals(for: app)
    }

    private func loadResiduals(for app: InstalledApp) async {
        let result = await service.findResiduals(for: app)
        residuals = result
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
