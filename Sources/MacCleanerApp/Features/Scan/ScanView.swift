import SwiftUI
import MacCleanerCore

struct ScanView: View {
    @Bindable var viewModel: ScanViewModel
    var onNavigate: ((String) -> Void)?
    @AppStorage(LargeFileThreshold.storageKey) private var largeFileMinimumSizeMB = LargeFileThreshold.default.rawValue

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
            Divider()
            rightPanel
        }
    }

    // MARK: - 左侧：核心扫描入口

    private var leftPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            if isScanning {
                scanningState
            } else {
                idleState
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Brand.accent.opacity(0.08), Color.clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }

    private var idleState: some View {
        VStack(spacing: 20) {
            GradientIconBadge(icon: "sparkle.magnifyingglass", size: 88)

            VStack(spacing: 6) {
                Text("畅快清理，清爽一下")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("欢迎使用 DevClean")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.startScan()
            } label: {
                Text("开始扫描")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .frame(width: 160, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.accent)
            .controlSize(.large)
        }
    }

    private var scanningState: some View {
        VStack(spacing: 24) {
            // 累计发现大小
            VStack(spacing: 8) {
                Text(SizeFormatter.format(bytes: viewModel.totalDiscoveredSize))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.accentGradient)
                    .contentTransition(.numericText())

                Text("已发现可清理")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // 已完成模块列表
            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.completedModules, id: \.self) { moduleID in
                    if let result = viewModel.results.first(where: { $0.module == moduleID }) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text(moduleID.displayName)
                                .font(.caption)
                            Spacer()
                            Text(SizeFormatter.format(bytes: result.totalSize))
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                }
            }
            .frame(width: 240)

            Spacer().frame(height: 4)

            // "正在扫描" + 取消按钮
            HStack {
                Text("正在扫描")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("取消") {
                    viewModel.cancel()
                }
                .controlSize(.small)
            }
            .frame(width: 320)

            // 当前扫描文件路径
            Text(shortScanPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 320, alignment: .leading)
                .animation(.none, value: shortScanPath)

            // 大文件实时候选预览（只读，扫描完成后才进入既有结果与清理流程）
            if viewModel.isLargeFileScan && !viewModel.liveLargeFileItems.isEmpty {
                liveLargeFilePreview
            }

            // 进度条
            if case let .scanning(completed, total) = viewModel.phase {
                ProgressView(value: Double(completed), total: Double(total))
                    .frame(width: 320)
                    .tint(Brand.accent)
            }
        }
    }

    /// 大文件扫描中的只读实时预览：最多 5 行，不含任何清理入口。
    private var liveLargeFilePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时发现 · 扫描中")
                .font(.callout)
                .fontWeight(.semibold)
            Text("已发现 \(viewModel.liveLargeFileMatchCount) 个大文件，排名会持续更新")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(viewModel.liveLargeFileItems.prefix(5), id: \.path) { item in
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(SizeFormatter.format(bytes: item.allocatedSize))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
            }

            Text("扫描完成后可查看全部结果并选择清理")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(
            Color(.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .brandCard(cornerRadius: 12)
    }

    private var shortScanPath: String {
        let path = viewModel.currentScanPath
        guard !path.isEmpty else { return " " }
        let home = DiskScanner.homeDirectory
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - 右侧：工具卡片网格

    private var rightPanel: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
            ], spacing: 16) {
                toolCard(
                    icon: "trash", colors: [.red, .orange],
                    title: "应用卸载器",
                    subtitle: "彻底卸载应用及残留文件",
                    key: "appUninstaller"
                )
                toolCard(
                    icon: "doc.on.doc", colors: [.pink, .purple],
                    title: "重复文件清理",
                    subtitle: "查找内容一样的文件",
                    key: "duplicateFinder"
                )
                toolCard(
                    icon: "chart.pie", colors: [.blue, .cyan],
                    title: "磁盘空间分析",
                    subtitle: "深度分析存储情况",
                    key: "diskVisualization"
                )
                largeFilesToolCard
                toolCard(
                    icon: "memorychip", colors: [.mint, .teal],
                    title: "内存清理",
                    subtitle: "释放内存压力，加速系统",
                    key: "memoryCleaner"
                )
                toolCard(
                    icon: "waveform.badge.magnifyingglass", colors: [.purple, .indigo],
                    title: "活动监视器",
                    subtitle: "查看进程用途，安全终止",
                    key: "activityMonitor"
                )
            }
            .padding(24)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    private var largeFilesToolCard: some View {
        Menu {
            Text("阈值越高，候选越少，扫描通常更快。")
                .foregroundStyle(.secondary)
            Divider()

            ForEach(LargeFileThreshold.allCases) { threshold in
                Button("扫描 \(threshold.displayName) 以上的文件\(threshold == selectedLargeFileThreshold ? "（当前）" : "")") {
                    largeFileMinimumSizeMB = threshold.rawValue
                    startLargeFileScan(with: threshold)
                }
            }
        } label: {
            VStack(spacing: 10) {
                GradientIconBadge(icon: "doc.badge.gearshape", size: 56, colors: [.orange, .yellow])

                Text("大文件清理")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text("查找 \(selectedLargeFileThreshold.displayName) 以上的文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .brandCard()
        }
        .menuStyle(.borderlessButton)
    }

    private func toolCard(icon: String, colors: [Color], title: String, subtitle: String, key: String) -> some View {
        Button {
            onNavigate?(key)
        } label: {
            VStack(spacing: 10) {
                GradientIconBadge(icon: icon, size: 56, colors: colors)

                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .brandCard()
        }
        .buttonStyle(BrandCardButtonStyle())
    }

    private var selectedLargeFileThreshold: LargeFileThreshold {
        LargeFileThreshold(rawValue: largeFileMinimumSizeMB) ?? .default
    }

    private func startLargeFileScan(with threshold: LargeFileThreshold) {
        viewModel.selectedModuleIDs = [.largeFiles]
        viewModel.startScan(
            largeFileMinimumAllocatedSize: threshold.minimumAllocatedSize
        )
    }

    private var isScanning: Bool {
        if case .scanning = viewModel.phase { return true }
        return false
    }
}
