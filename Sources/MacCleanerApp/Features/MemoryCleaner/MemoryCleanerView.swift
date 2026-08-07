import SwiftUI
import MacCleanerCore

struct MemoryCleanerView: View {
    @Bindable var viewModel: MemoryCleanerViewModel
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            topBar
            Divider()

            // 内容
            ScrollView {
                VStack(spacing: 28) {
                    Spacer().frame(height: 8)
                    memoryGauge
                    statsGrid
                    actionSection
                    Spacer()
                }
                .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.startMonitoring() }
        .onDisappear { viewModel.stopMonitoring() }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Image(systemName: "memorychip")
                .foregroundStyle(.mint)
            Text("内存清理")
                .font(.headline)

            Spacer()

            if let info = viewModel.memoryInfo {
                Text("物理内存 \(formatBytes(info.physicalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 内存压力条

    private var memoryGauge: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("内存压力")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let info = viewModel.memoryInfo {
                GeometryReader { geo in
                    let width = geo.size.width
                    let total = Double(info.physicalBytes)
                    guard total > 0 else { return AnyView(EmptyView()) }

                    let segments: [(Color, Double)] = [
                        (.blue, Double(info.appMemoryBytes) / total),
                        (.orange, Double(info.wiredBytes) / total),
                        (.purple, Double(info.compressedBytes) / total),
                        (.green, Double(info.cachedBytes) / total),
                    ]

                    return AnyView(
                        HStack(spacing: 1) {
                            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(segment.0)
                                    .frame(width: max(2, width * segment.1))
                            }
                            // 剩余空间
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.15))
                        }
                    )
                }
                .frame(height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // 图例
                HStack(spacing: 16) {
                    legendItem(color: .blue, label: "App 内存")
                    legendItem(color: .orange, label: "联动内存")
                    legendItem(color: .purple, label: "被压缩")
                    legendItem(color: .green, label: "已缓存")
                    legendItem(color: Color.gray.opacity(0.3), label: "可用")
                }
                .font(.caption2)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
        }
    }

    // MARK: - 统计卡片网格

    private var statsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ], spacing: 12) {
            if let info = viewModel.memoryInfo {
                statCard(title: "物理内存", value: formatBytes(info.physicalBytes), color: .primary)
                statCard(title: "已使用", value: formatBytes(info.usedBytes), color: .red)
                statCard(title: "可用", value: formatBytes(info.freeBytes), color: .green)
                statCard(title: "App 内存", value: formatBytes(info.appMemoryBytes), color: .blue)
                statCard(title: "联动内存", value: formatBytes(info.wiredBytes), color: .orange)
                statCard(title: "被压缩", value: formatBytes(info.compressedBytes), color: .purple)
                statCard(title: "已缓存文件", value: formatBytes(info.cachedBytes), color: .green)
                statCard(title: "交换空间", value: formatBytes(info.swapUsedBytes), color: .pink)
            }
        }
    }

    private func statCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 操作区

    private var actionSection: some View {
        VStack(spacing: 12) {
            switch viewModel.phase {
            case .cleaning:
                ProgressView()
                    .controlSize(.large)
                Text("正在清理内存...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .done(let freedBytes):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                if freedBytes > 0 {
                    Text("已释放 \(formatBytes(freedBytes))")
                        .font(.headline)
                        .foregroundStyle(.green)
                } else {
                    Text("清理完成")
                        .font(.headline)
                        .foregroundStyle(.green)
                }

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("重试") {
                    Task { await viewModel.cleanMemory() }
                }
                .controlSize(.large)

            default:
                Button {
                    Task { await viewModel.cleanMemory() }
                } label: {
                    Text("清理内存")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .frame(width: 160, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
                .controlSize(.large)
                .disabled(viewModel.memoryInfo == nil)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: UInt64) -> String {
        SizeFormatter.format(bytes: Int64(min(bytes, UInt64(Int64.max))))
    }
}
