import SwiftUI
import MacCleanerCore

struct ContentView: View {
    @Binding var onScanRequested: () -> Void
    let environment: AppEnvironment
    @Environment(\.openSettings) private var openSettings

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
    @State private var memoryCleanerVM = MemoryCleanerViewModel()
    @State private var activityMonitorVM: ActivityMonitorViewModel

    init(onScanRequested: Binding<() -> Void>, environment: AppEnvironment) {
        _onScanRequested = onScanRequested
        self.environment = environment
        _activityMonitorVM = State(initialValue: ActivityMonitorViewModel(
            aiService: environment.aiService,
            subjectFactory: environment.subjectFactory
        ))
    }

    enum Screen {
        case scan
        case summary
        case results
        case appUninstaller
        case duplicateFinder
        case diskVisualization
        case memoryCleaner
        case activityMonitor
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
                    case "memoryCleaner": screen = .memoryCleaner
                    case "activityMonitor": screen = .activityMonitor
                    case "aiSettings":
                        SettingsNavigation.selectAI()
                        openSettings()
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
                        case "memoryCleaner": screen = .memoryCleaner
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
                    onBack: { screen = .scan }
                )

            case .duplicateFinder:
                DuplicateFinderView(
                    viewModel: duplicateFinderVM,
                    onBack: { screen = .scan }
                )

            case .diskVisualization:
                DiskVisualizationView(
                    viewModel: diskVizVM,
                    onBack: { screen = .scan }
                )

            case .memoryCleaner:
                MemoryCleanerView(
                    viewModel: memoryCleanerVM,
                    onBack: { screen = .scan }
                )

            case .activityMonitor:
                ActivityMonitorView(
                    viewModel: activityMonitorVM,
                    onBack: { screen = .scan }
                )
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        // 全局字号上调一档：所有语义字体（caption/callout/body…）随 Dynamic Type 放大
        .dynamicTypeSize(.large)
        .onChange(of: scanVM.phase) { _, newPhase in
            if newPhase == .done {
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
                scanVM.startScan()
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
}
