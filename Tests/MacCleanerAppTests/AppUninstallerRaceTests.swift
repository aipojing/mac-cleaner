import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

private func makeApp(_ bundleID: String) -> InstalledApp {
    InstalledApp(
        name: bundleID, bundleID: bundleID, version: "1.0",
        path: "/Applications/\(bundleID).app", bundleSize: 100, fileIdentity: nil
    )
}

private func makeResiduals(label: String) -> AppResidualFiles {
    let identity = FileIdentity(device: 1, inode: 2, kind: .regularFile)
    return AppResidualFiles(groups: [
        ResidualGroup(id: label, label: label, items: [
            ResidualItem(
                path: "/tmp/\(label).plist", name: "\(label).plist",
                size: 10, fileIdentity: identity
            ),
        ]),
    ])
}

/// 闸门控制的卸载服务 double：findResiduals 挂起直到测试显式放行，
/// 用于确定性地模拟 A/B 残留扫描乱序返回。
private actor GatedAppUninstalling: AppUninstalling {
    private var gates: [String: CheckedContinuation<AppResidualFiles, Never>] = [:]
    private let residualsByBundleID: [String: AppResidualFiles]
    private let scanDelayNanoseconds: UInt64
    private(set) var scanApplicationsCallCount = 0

    init(
        residualsByBundleID: [String: AppResidualFiles] = [:],
        scanDelayNanoseconds: UInt64 = 0
    ) {
        self.residualsByBundleID = residualsByBundleID
        self.scanDelayNanoseconds = scanDelayNanoseconds
    }

    func scanApplications() async -> [InstalledApp] {
        scanApplicationsCallCount += 1
        if scanDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: scanDelayNanoseconds)
        }
        return []
    }

    func findResiduals(for app: InstalledApp) async -> AppResidualFiles {
        await withCheckedContinuation { continuation in
            gates[app.bundleID] = continuation
        }
    }

    func uninstall(app: InstalledApp, residualItems: [ResidualItem]) async -> UninstallReport {
        UninstallReport(
            appName: app.name, appRemoved: false,
            residualsRemoved: 0, failures: 0, bytesMovedToTrash: 0
        )
    }

    /// 等待指定应用的残留扫描进入挂起状态。
    func waitForGate(_ bundleID: String) async {
        while gates[bundleID] == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 放行指定应用的残留扫描。
    func release(_ bundleID: String) {
        gates.removeValue(forKey: bundleID)?
            .resume(returning: residualsByBundleID[bundleID] ?? AppResidualFiles(groups: []))
    }
}

/// 按应用延迟返回的卸载服务 double：模拟慢扫描后返回。
private struct DelayedAppUninstalling: AppUninstalling {
    let delays: [String: UInt64]
    let residualsByBundleID: [String: AppResidualFiles]

    func scanApplications() async -> [InstalledApp] { [] }

    func findResiduals(for app: InstalledApp) async -> AppResidualFiles {
        if let delay = delays[app.bundleID] {
            try? await Task.sleep(nanoseconds: delay)
        }
        return residualsByBundleID[app.bundleID] ?? AppResidualFiles(groups: [])
    }

    func uninstall(app: InstalledApp, residualItems: [ResidualItem]) async -> UninstallReport {
        UninstallReport(
            appName: app.name, appRemoved: false,
            residualsRemoved: 0, failures: 0, bytesMovedToTrash: 0
        )
    }
}

/// 立即返回的计数服务：验证应用列表进入就绪态后会在后台补全残留总计，
/// 且用户随后点开同一应用会复用该结果。
private actor PrefetchingAppUninstalling: AppUninstalling {
    let apps: [InstalledApp]
    let residualsByBundleID: [String: AppResidualFiles]
    private(set) var residualScanCallCount = 0

    init(apps: [InstalledApp], residualsByBundleID: [String: AppResidualFiles]) {
        self.apps = apps
        self.residualsByBundleID = residualsByBundleID
    }

    func scanApplications() async -> [InstalledApp] { apps }

    func findResiduals(for app: InstalledApp) async -> AppResidualFiles {
        residualScanCallCount += 1
        return residualsByBundleID[app.bundleID] ?? AppResidualFiles(groups: [])
    }

    func uninstall(app: InstalledApp, residualItems: [ResidualItem]) async -> UninstallReport {
        UninstallReport(
            appName: app.name, appRemoved: false,
            residualsRemoved: 0, failures: 0, bytesMovedToTrash: 0
        )
    }
}

/// 首个应用的关联文件扫描长时间运行时，验证它不能阻塞后续应用的总计补全。
private actor SlowFirstPrefetchingAppUninstalling: AppUninstalling {
    let apps: [InstalledApp]
    private let slowBundleID: String
    private var slowGate: CheckedContinuation<Void, Never>?

    init(apps: [InstalledApp], slowBundleID: String) {
        self.apps = apps
        self.slowBundleID = slowBundleID
    }

    func scanApplications() async -> [InstalledApp] { apps }

    func findResiduals(for app: InstalledApp) async -> AppResidualFiles {
        if app.bundleID == slowBundleID {
            await withCheckedContinuation { continuation in
                slowGate = continuation
            }
        }
        return makeResiduals(label: app.bundleID)
    }

    func uninstall(app: InstalledApp, residualItems: [ResidualItem]) async -> UninstallReport {
        UninstallReport(
            appName: app.name, appRemoved: false,
            residualsRemoved: 0, failures: 0, bytesMovedToTrash: 0
        )
    }

    func waitForSlowScan() async {
        while slowGate == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func releaseSlowScan() {
        slowGate?.resume()
        slowGate = nil
    }
}

@MainActor
@Suite("App uninstaller residual scan race")
struct AppUninstallerRaceTests {
    @Test("快速切换应用时，后返回的旧扫描结果不得覆盖新选择")
    func staleResidualsDoNotOverrideNewSelection() async {
        let appA = makeApp("com.example.a")
        let appB = makeApp("com.example.b")
        let service = GatedAppUninstalling(residualsByBundleID: [
            "com.example.a": makeResiduals(label: "A-residual"),
            "com.example.b": makeResiduals(label: "B-residual"),
        ])
        let viewModel = AppUninstallerViewModel(service: service)

        viewModel.selectApp(appA)
        await service.waitForGate("com.example.a")

        // A 扫描在途时改选 B：A 的任务应被取消，B 开始扫描
        viewModel.selectApp(appB)
        await service.waitForGate("com.example.b")

        // B 先返回并写回；A 后返回（乱序），其结果必须被丢弃
        await service.release("com.example.b")
        await service.release("com.example.a")

        // 等待两个任务收尾
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.selectedApp == appB)
        #expect(
            viewModel.residuals?.groups.first?.label == "B-residual",
            "A 的残留列表不得覆盖 B 的状态，否则 uninstall 会用 B + A 的路径删错文件"
        )
        #expect(viewModel.phase == .ready)
    }

    @Test("直接等待的测试入口下，乱序返回同样被身份校验拦截")
    func staleResidualsDroppedViaIdentityCheck() async {
        let appA = makeApp("com.example.a")
        let appB = makeApp("com.example.b")
        let service = DelayedAppUninstalling(
            delays: ["com.example.a": 300_000_000],
            residualsByBundleID: [
                "com.example.a": makeResiduals(label: "A-residual"),
                "com.example.b": makeResiduals(label: "B-residual"),
            ]
        )
        let viewModel = AppUninstallerViewModel(service: service)

        async let staleScan: Void = viewModel.selectAppForTesting(appA)
        // 让 A 的扫描进入等待后再改选 B
        try? await Task.sleep(nanoseconds: 50_000_000)
        await viewModel.selectAppForTesting(appB)
        await staleScan

        #expect(viewModel.selectedApp == appB)
        #expect(viewModel.residuals?.groups.first?.label == "B-residual")
    }

    @Test("loadApps 在扫描在途时重入会被跳过")
    func loadAppsSkipsWhileInFlight() async {
        let service = GatedAppUninstalling(scanDelayNanoseconds: 100_000_000)
        let viewModel = AppUninstallerViewModel(service: service)

        viewModel.loadApps()
        viewModel.loadApps()

        for _ in 0..<200 {
            if viewModel.phase == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.phase == .ready)
        let count = await service.scanApplicationsCallCount
        #expect(count == 1, "重入的 loadApps 不得发起第二次应用扫描")
    }

    @Test("后台补全总计后打开同一应用复用结果")
    func prefetchesResidualTotalsAndReusesCachedDetails() async {
        let app = makeApp("com.example.prefetch.\(UUID().uuidString)")
        let service = PrefetchingAppUninstalling(
            apps: [app],
            residualsByBundleID: [app.bundleID: makeResiduals(label: "prefetched")]
        )
        let viewModel = AppUninstallerViewModel(service: service)

        viewModel.loadApps()
        for _ in 0..<200 where !viewModel.hasScannedResidualTotal(for: app) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.phase == .ready, "应用列表应先可用，不等待后台补全")
        #expect(viewModel.displaySize(for: app) == 110)
        #expect(await service.residualScanCallCount == 1)

        await viewModel.selectAppForTesting(app)

        #expect(viewModel.residuals?.groups.first?.label == "prefetched")
        #expect(await service.residualScanCallCount == 1, "打开已预扫的应用不得重复遍历磁盘")
    }

    @Test("单个大应用补全缓慢时，后续应用仍会继续显示总计")
    func slowPrefetchDoesNotBlockLaterApps() async {
        let slowApp = makeApp("com.example.slow.\(UUID().uuidString)")
        let fastApp = makeApp("com.example.fast.\(UUID().uuidString)")
        let service = SlowFirstPrefetchingAppUninstalling(
            apps: [slowApp, fastApp],
            slowBundleID: slowApp.bundleID
        )
        let viewModel = AppUninstallerViewModel(service: service)

        viewModel.loadApps()
        await service.waitForSlowScan()

        for _ in 0..<100 where !viewModel.hasScannedResidualTotal(for: fastApp) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(
            viewModel.hasScannedResidualTotal(for: fastApp),
            "慢应用扫描在途时，后续应用不应始终卡在 0/N"
        )

        await service.releaseSlowScan()
    }

    @Test("重开卸载器会复用当天的关联文件总计")
    func reusesPersistedResidualTotalAcrossViewModels() async {
        let app = makeApp("com.example.persisted.\(UUID().uuidString)")
        let service = PrefetchingAppUninstalling(
            apps: [app],
            residualsByBundleID: [app.bundleID: makeResiduals(label: "persisted")]
        )

        let firstViewModel = AppUninstallerViewModel(service: service)
        firstViewModel.loadApps()
        for _ in 0..<200 where !firstViewModel.hasScannedResidualTotal(for: app) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let secondViewModel = AppUninstallerViewModel(service: service)
        secondViewModel.loadApps()
        for _ in 0..<200 where !secondViewModel.hasScannedResidualTotal(for: app) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(secondViewModel.displaySize(for: app) == 110)
        #expect(
            await service.residualScanCallCount == 1,
            "同一应用的当天总计已落盘时，重新打开卸载器不应再遍历关联目录"
        )
    }
}
