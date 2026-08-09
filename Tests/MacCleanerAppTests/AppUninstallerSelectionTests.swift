import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

/// 内存卸载服务：返回固定残留，不触碰真实文件系统。
private struct StubAppUninstalling: AppUninstalling {
    let residuals: AppResidualFiles

    func scanApplications() async -> [InstalledApp] { [] }
    func findResiduals(for app: InstalledApp) async -> AppResidualFiles { residuals }
    func uninstall(app: InstalledApp, residualItems: [ResidualItem]) async -> UninstallReport {
        UninstallReport(
            appName: app.name, appRemoved: false,
            residualsRemoved: 0, failures: 0, bytesMovedToTrash: 0
        )
    }
}

@MainActor
@Suite("App uninstaller selection")
struct AppUninstallerSelectionTests {
    @Test("残留扫描完成后默认不选中任何项")
    func residualsNotSelectedByDefault() async {
        let identity = FileIdentity(device: 1, inode: 2, kind: .regularFile)
        let service = StubAppUninstalling(
            residuals: AppResidualFiles(groups: [
                ResidualGroup(id: "prefs", label: "Preferences", items: [
                    ResidualItem(path: "/tmp/a.plist", name: "a.plist", size: 10, fileIdentity: identity),
                    ResidualItem(path: "/tmp/b.plist", name: "b.plist", size: 20, fileIdentity: identity),
                ]),
            ])
        )
        let viewModel = AppUninstallerViewModel(service: service)
        let app = InstalledApp(
            name: "Demo", bundleID: "com.example.demo", version: "1.0",
            path: "/Applications/Demo.app", bundleSize: 100, fileIdentity: nil
        )

        await viewModel.selectAppForTesting(app)

        #expect(viewModel.residuals?.totalItemCount == 2)
        #expect(viewModel.selectedResidualPaths.isEmpty, "残留必须默认不选中，等待用户显式勾选")
    }

    @Test("已发现残留后，应用列表总计包含应用本体和残留")
    func appListTotalIncludesBundleAndResiduals() async {
        let identity = FileIdentity(device: 1, inode: 2, kind: .regularFile)
        let service = StubAppUninstalling(
            residuals: AppResidualFiles(groups: [
                ResidualGroup(id: "cache", label: "Caches", items: [
                    ResidualItem(path: "/tmp/cache", name: "cache", size: 30, fileIdentity: identity),
                ]),
            ])
        )
        let viewModel = AppUninstallerViewModel(service: service)
        let app = InstalledApp(
            name: "Demo", bundleID: "com.example.demo", version: "1.0",
            path: "/Applications/Demo.app", bundleSize: 100, fileIdentity: nil
        )

        await viewModel.selectAppForTesting(app)

        #expect(viewModel.displaySize(for: app) == 130)
        #expect(viewModel.hasScannedResidualTotal(for: app))
    }

    @Test("全选仅选择可验证的残留，并可再次取消全选")
    func selectAllResidualsOnlySelectsSafeItems() async {
        let identity = FileIdentity(device: 1, inode: 2, kind: .regularFile)
        let service = StubAppUninstalling(
            residuals: AppResidualFiles(groups: [
                ResidualGroup(id: "mixed", label: "Mixed", items: [
                    ResidualItem(path: "/tmp/safe-a", name: "safe-a", size: 10, fileIdentity: identity),
                    ResidualItem(path: "/tmp/unverifiable", name: "unverifiable", size: 20, fileIdentity: nil),
                    ResidualItem(path: "/tmp/safe-b", name: "safe-b", size: 30, fileIdentity: identity),
                ]),
            ])
        )
        let viewModel = AppUninstallerViewModel(service: service)
        let app = InstalledApp(
            name: "Demo", bundleID: "com.example.demo", version: "1.0",
            path: "/Applications/Demo.app", bundleSize: 100, fileIdentity: nil
        )

        await viewModel.selectAppForTesting(app)

        viewModel.toggleSelectAllResiduals()
        #expect(viewModel.selectedResidualPaths == ["/tmp/safe-a", "/tmp/safe-b"])
        #expect(viewModel.selectedResidualSize == 40)
        #expect(viewModel.areAllSelectableResidualsSelected)

        viewModel.toggleSelectAllResiduals()
        #expect(viewModel.selectedResidualPaths.isEmpty)
        #expect(!viewModel.areAllSelectableResidualsSelected)
    }
}
