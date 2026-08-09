import SwiftUI
import MacCleanerCore

struct ContentView: View {
    @Binding var onScanRequested: () -> Void
    let environment: AppEnvironment

    @State private var screen: Screen = .scan
    @State private var scanVM = ScanViewModel()
    @State private var resultsVM: ResultsViewModel?
    @State private var cleanupVM = CleanupViewModel()
    @State private var showCleanup = false
    @State private var showCleanConfirm = false
    @State private var pendingCleanItems: [CleanableItem] = []
    @State private var appUninstallerVM = AppUninstallerViewModel()
    @State private var duplicateFinderVM = DuplicateFinderViewModel()
    @State private var diskVizVM = DiskVisualizationViewModel()
    @State private var activityMonitorVM: ActivityMonitorViewModel

    init(onScanRequested: Binding<() -> Void>, environment: AppEnvironment) {
        _onScanRequested = onScanRequested
        self.environment = environment
        _activityMonitorVM = State(initialValue: ActivityMonitorViewModel(
            aiService: environment.aiService,
            subjectFactory: environment.subjectFactory
        ))
    }

    enum Screen: Equatable {
        case scan
        case summary
        case results
        case appUninstaller
        case duplicateFinder
        case diskVisualization
        case activityMonitor
        case aiSettings
    }

    var body: some View {
        Group {
            switch screen {
            case .scan:
                ScanView(viewModel: scanVM, onNavigate: { key in
                    switch key {
                    case "appUninstaller": screen = .appUninstaller
                    case "duplicateFinder": screen = .duplicateFinder
                    case "diskVisualization": screen = .diskVisualization
                    case "activityMonitor": screen = .activityMonitor
                    case "aiSettings": screen = .aiSettings
                    default: break
                    }
                })

            case .summary:
                ScanSummaryView(
                    results: scanVM.results,
                    onViewDetails: {
                        resultsVM = ResultsViewModel(
                            results: scanVM.results,
                            aiService: environment.aiService,
                            subjectFactory: environment.subjectFactory
                        )
                        screen = .results
                    },
                    onRescan: { rescan() },
                    onNavigate: { key in
                        switch key {
                        case "appUninstaller": screen = .appUninstaller
                        case "duplicateFinder": screen = .duplicateFinder
                        case "diskVisualization": screen = .diskVisualization
                        case "activityMonitor": screen = .activityMonitor
                        default: break
                        }
                    }
                )

            case .results:
                if let resultsVM {
                    ResultsView(
                        viewModel: resultsVM,
                        onClean: { items in
                            pendingCleanItems = items
                            showCleanConfirm = true
                        },
                        onBack: { screen = .summary }
                    )
                }

            case .appUninstaller:
                AppUninstallerView(
                    viewModel: appUninstallerVM,
                    onBack: returnFromTool
                )

            case .duplicateFinder:
                DuplicateFinderView(
                    viewModel: duplicateFinderVM,
                    onBack: returnFromTool
                )

            case .diskVisualization:
                DiskVisualizationView(
                    viewModel: diskVizVM,
                    onBack: returnFromTool
                )

            case .activityMonitor:
                ActivityMonitorView(
                    viewModel: activityMonitorVM,
                    onBack: returnFromTool
                )

            case .aiSettings:
                AISettingsView(
                    viewModel: environment.aiSettingsViewModel,
                    onBack: returnFromTool
                )
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        // 全局字号上调一档：所有语义字体（caption/callout/body…）随 Dynamic Type 放大
        .dynamicTypeSize(.large)
        .onChange(of: scanVM.phase) { _, newPhase in
            // 仅在用户仍停留在扫描页时自动跳转；
            // 扫描期间进入其他功能页（活动监视器、磁盘可视化等）不打断。
            if newPhase == .done, screen == .scan {
                screen = .summary
            }
        }
        .confirmationDialog(
            "确认清理",
            isPresented: $showCleanConfirm,
            titleVisibility: .visible
        ) {
            Button("开始清理（\(SizeFormatter.format(bytes: totalPendingSize))）", role: .destructive) {
                cleanupVM.reset()
                cleanupVM.clean(items: pendingCleanItems)
                showCleanup = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理 \(pendingCleanItems.count) 个项目，预计回收 \(SizeFormatter.format(bytes: totalPendingSize))")
        }
        .onAppear {
            onScanRequested = {
                rescan()
                scanVM.startStandardScan()
            }
        }
        .sheet(isPresented: $showCleanup) {
            CleanupView(viewModel: cleanupVM) {
                showCleanup = false
                rescan()
            }
        }
    }

    private var totalPendingSize: Int64 {
        // 与结果页同一口径：按 (device, inode) 去重，
        // 未集齐全部硬链接路径的对象不计入预计回收
        PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: pendingCleanItems,
            allKnownItems: resultsVM?.allItems ?? pendingCleanItems
        )
    }

    private func rescan() {
        resultsVM = nil
        screen = .scan
        scanVM.reset()
    }

    /// 从其他功能页返回时，保留后台扫描的真实状态：扫描中继续展示进度；
    /// 若扫描已在后台结束则直接展示摘要，避免回到看似空闲的首页。
    func returnFromTool() {
        screen = Self.screenWhenReturningFromTool(phase: scanVM.phase)
    }

    static func screenWhenReturningFromTool(phase: ScanViewModel.Phase) -> Screen {
        phase == .done ? .summary : .scan
    }
}
