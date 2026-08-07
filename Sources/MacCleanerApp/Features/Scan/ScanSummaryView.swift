import SwiftUI
import Charts
import MacCleanerCore

struct ScanSummaryView: View {
    let results: [ScanResult]
    let onViewDetails: () -> Void
    let onRescan: () -> Void
    var onNavigate: ((String) -> Void)?

    @State private var permissionReport: PermissionDiagnosticReport?
    @State private var showPermissionDetail = false
    @State private var historyStats: CleanupStats?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 40)

                // 权限诊断横幅
                if let report = permissionReport, report.deniedCount > 0 {
                    permissionBanner(report: report)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 16)
                }

                // 大数字
                VStack(spacing: 10) {
                    GradientIconBadge(icon: "checkmark", size: 64)

                    Text("扫描完成")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("发现可清理")
                            .font(.title2)
                        Text(SizeFormatter.format(bytes: totalSize))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.accentGradient)
                    }

                    Text("共 \(totalItemCount) 个候选项目")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer().frame(height: 24)

                // 分类卡片 - 自适应列数
                categoryCardsGrid
                    .padding(.horizontal, 40)

                // 清理历史统计
                if let stats = historyStats, stats.totalRecords > 0 {
                    historyDashboard(stats)
                        .padding(.horizontal, 40)
                        .padding(.top, 16)
                }

                Spacer().frame(height: 28)

                // 操作按钮
                HStack(spacing: 16) {
                    Button {
                        onRescan()
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.large)

                    Button {
                        onViewDetails()
                    } label: {
                        Text("查看详情")
                            .fontWeight(.semibold)
                            .frame(width: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
                    .controlSize(.large)
                }

                Spacer().frame(height: 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if permissionReport == nil {
                Task.detached {
                    let report = PermissionDiagnostic().diagnose()
                    await MainActor.run {
                        permissionReport = report
                    }
                }
            }
            if historyStats == nil {
                Task {
                    historyStats = await CleanupHistoryStore.shared.stats(days: 30)
                }
            }
        }
    }

    private var categoryCardsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: min(results.count, 3)), spacing: 12) {
            ForEach(results, id: \.module) { result in
                categoryCard(result: result)
            }
        }
    }

    private func categoryCard(result: ScanResult) -> some View {
        VStack(spacing: 8) {
            Image(systemName: result.module.sfSymbol)
                .font(.title2)
                .foregroundStyle(result.module.color)

            Text(result.module.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)

            Text(SizeFormatter.format(bytes: result.totalSize))
                .font(.callout)
                .fontWeight(.semibold)
                .monospacedDigit()

            Text("\(result.items.count) 项")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 权限诊断横幅

    private func permissionBanner(report: PermissionDiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: report.hasFullDiskAccess ? "exclamationmark.triangle" : "lock.shield")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(report.hasFullDiskAccess
                         ? "\(report.deniedCount) 个目录无法访问"
                         : "完全磁盘访问未开启")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("扫描结果可能不完整，\(report.affectedModules.map(\.displayName).joined(separator: "、")) 模块受影响")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button("查看详情") {
                    showPermissionDetail = true
                }
                .font(.caption)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showPermissionDetail) {
            VStack {
                PermissionDiagnosticView()
                    .frame(width: 500, height: 500)
                HStack {
                    Spacer()
                    Button("关闭") { showPermissionDetail = false }
                        .padding()
                }
            }
        }
    }

    // MARK: - 清理历史统计

    private func historyDashboard(_ stats: CleanupStats) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                // 累计释放
                statCard(
                    icon: "arrow.up.trash",
                    color: .green,
                    title: "累计释放",
                    value: SizeFormatter.format(bytes: stats.cumulativeFreed),
                    subtitle: "共 \(stats.totalRecords) 次清理"
                )

                // 最近清理
                statCard(
                    icon: "clock.arrow.circlepath",
                    color: .blue,
                    title: "上次清理",
                    value: stats.lastCleanupDate.map { relativeDate($0) } ?? "暂无",
                    subtitle: stats.dailyFreed.last.map { "释放 \(SizeFormatter.format(bytes: $0.freed))" } ?? ""
                )

                // Top 模块
                if let top = stats.topModulesByFreed.first {
                    statCard(
                        icon: "chart.bar",
                        color: .orange,
                        title: "最大来源",
                        value: top.moduleName,
                        subtitle: "累计 \(SizeFormatter.format(bytes: top.totalFreed))"
                    )
                }
            }

            // 趋势图
            if stats.dailyFreed.count >= 2 {
                trendChart(dailyFreed: stats.dailyFreed)
            }

            // Top 5 模块
            if stats.topModulesByFreed.count >= 2 {
                topModulesBar(modules: Array(stats.topModulesByFreed.prefix(5)))
            }
        }
    }

    private func statCard(icon: String, color: Color, title: String, value: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .fontWeight(.semibold)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func trendChart(dailyFreed: [(date: Date, freed: Int64)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("近 30 天清理趋势")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart(dailyFreed, id: \.date) { entry in
                BarMark(
                    x: .value("日期", entry.date, unit: .day),
                    y: .value("释放", Double(entry.freed) / 1_073_741_824) // bytes → GB
                )
                .foregroundStyle(.green.gradient)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let gb = value.as(Double.self) {
                            Text(String(format: "%.1f GB", gb))
                        }
                    }
                }
            }
            .frame(height: 120)
        }
        .padding(12)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func topModulesBar(modules: [(moduleID: String, moduleName: String, totalFreed: Int64)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("释放空间 Top 5")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart(modules, id: \.moduleID) { module in
                BarMark(
                    x: .value("释放", Double(module.totalFreed) / 1_073_741_824),
                    y: .value("模块", module.moduleName)
                )
                .foregroundStyle(.blue.gradient)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let gb = value.as(Double.self) {
                            Text(String(format: "%.1f GB", gb))
                        }
                    }
                }
            }
            .frame(height: CGFloat(modules.count) * 28 + 20)
        }
        .padding(12)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var totalSize: Int64 {
        // 集合级总量按 (device, inode) 去重：同一硬链接对象
        // 即使分布在不同模块结果中也只计一次
        PhysicalSizeCalculator.uniqueAllocatedBytes(in: results.flatMap(\.items))
    }

    private var totalItemCount: Int {
        results.reduce(0) { $0 + $1.items.count }
    }
}
