import SwiftUI
import MacCleanerCore

struct MenuBarPopoverView: View {
    @Bindable var viewModel: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            // 磁盘空间环形图
            if let info = viewModel.diskSpace {
                diskRing(info: info)
            } else {
                ProgressView()
                    .frame(height: 120)
            }

            // 低空间警告
            if viewModel.isLowSpace {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("磁盘空间不足！")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            // 候选占用空间提示
            if viewModel.hasCandidateSpace {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.orange)
                    Text("发现候选占用空间 \(SizeFormatter.format(bytes: viewModel.candidateBytes))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            // 定时扫描开关
            Toggle(isOn: Binding(
                get: { viewModel.isScheduledScanEnabled },
                set: { viewModel.toggleScheduledScan(enabled: $0) }
            )) {
                Label("定时扫描", systemImage: "clock.arrow.circlepath")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            // 操作按钮
            VStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("打开 DevClean", systemImage: "window.shade.open")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear {
            viewModel.start()
        }
    }

    private func diskRing(info: DiskSpaceInfo) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 12)

                Circle()
                    .trim(from: 0, to: CGFloat(info.usedPercent / 100))
                    .stroke(
                        ringColor(percent: info.usedPercent),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 2) {
                    Text(info.formattedFree)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("可用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, height: 100)

            HStack(spacing: 20) {
                legendItem(color: ringColor(percent: info.usedPercent),
                          label: "已使用", value: info.formattedUsed)
                legendItem(color: .gray.opacity(0.3),
                          label: "总容量", value: info.formattedTotal)
            }
            .font(.caption)
        }
    }

    private func legendItem(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
    }

    private func ringColor(percent: Double) -> Color {
        if percent > 90 { return .red }
        if percent > 75 { return .orange }
        return .blue
    }
}
