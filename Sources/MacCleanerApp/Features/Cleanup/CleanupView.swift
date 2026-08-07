import SwiftUI
import MacCleanerCore

struct CleanupView: View {
    @Bindable var viewModel: CleanupViewModel
    let onDismiss: () -> Void
    @State private var showFailureDetails = false

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.state {
            case .idle:
                EmptyView()

            case let .cleaning(progress, current):
                cleaningContent(progress: progress, current: current)

            case let .done(summary):
                doneContent(summary: summary)

            case let .failed(message):
                failedContent(message: message)
            }
        }
        .padding(32)
        .frame(width: 460)
        .frame(minHeight: 300)
    }

    private func cleaningContent(progress: Double, current: String) -> some View {
        VStack(spacing: 20) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)

            Image(systemName: "trash")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse)

            Text("正在清理...")
                .font(.title3)
                .fontWeight(.semibold)

            Text("正在处理: \(current)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func doneContent(summary: CleanupSummary) -> some View {
        VStack(spacing: 16) {
            Image(systemName: summary.failureCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(summary.failureCount == 0 ? .green : .orange)

            Text("清理完成")
                .font(.title2)
                .fontWeight(.semibold)

            // 回收统计
            VStack(spacing: 6) {
                if summary.actualFreed > 0 {
                    HStack {
                        Text("已释放空间:")
                        SizeLabel(bytes: summary.actualFreed)
                            .fontWeight(.bold)
                    }
                    .font(.title3)
                }

                if summary.hasTrashedItems {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                        Text("已移到废纸篓")
                            .foregroundStyle(.secondary)
                        SizeLabel(bytes: summary.trashedSize)
                            .foregroundStyle(.secondary)
                            .fontWeight(.medium)
                        Text("（清空后释放空间）")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }

                if summary.hasDiscrepancy {
                    HStack(spacing: 4) {
                        Text("预计回收")
                            .foregroundStyle(.secondary)
                        SizeLabel(bytes: summary.expectedSize)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("差异 \(formatSize(summary.discrepancy))")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }

            // 成功/失败统计
            if summary.failureCount > 0 {
                VStack(spacing: 8) {
                    Divider()

                    HStack(spacing: 16) {
                        Label("\(summary.successCount) 项成功", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        Label("\(summary.failureCount) 项失败", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                    .font(.caption)

                    // 按原因分组显示失败
                    failureReasonsSummary(summary: summary)

                    if !summary.failedItems.isEmpty {
                        Button(showFailureDetails ? "收起详情" : "查看失败详情") {
                            showFailureDetails.toggle()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }

                    if showFailureDetails {
                        failureDetailsList(items: summary.failedItems)
                    }
                }
            }

            // 权限提示
            if summary.hasPermissionIssues {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.orange)
                    Text("部分文件因权限不足无法删除，请检查完全磁盘访问权限")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            Button("完成") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func failureReasonsSummary(summary: CleanupSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(summary.failuresByReason.keys), id: \.rawValue) { reason in
                let count = summary.failuresByReason[reason]?.count ?? 0
                HStack(spacing: 4) {
                    Image(systemName: iconForReason(reason))
                        .frame(width: 14)
                    Text("\(reason.localizedDescription) (\(count) 项)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func failureDetailsList(items: [FailedItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.prefix(20).enumerated()), id: \.offset) { _, item in
                    HStack {
                        Image(systemName: iconForReason(item.reason))
                            .foregroundStyle(.red)
                            .frame(width: 12)
                        Text(shortenPath(item.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(item.reason.localizedDescription)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
                if items.count > 20 {
                    Text("... 还有 \(items.count - 20) 项")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: 120)
        .padding(8)
        .background(.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func failedContent(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("清理失败")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("关闭") {
                onDismiss()
            }
        }
    }

    private func iconForReason(_ reason: FailureReason) -> String {
        switch reason {
        case .permissionDenied: return "lock.fill"
        case .fileInUse: return "person.fill"
        case .notFound: return "questionmark.circle"
        case .diskFull: return "externaldrive.fill"
        case .unsafeTarget, .identityChanged, .identityUnavailable:
            return "shield.slash.fill"
        case .unknown: return "exclamationmark.circle"
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = DiskScanner.homeDirectory
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func formatSize(_ bytes: Int64) -> String {
        let absBytes = abs(bytes)
        if absBytes < 1024 { return "\(bytes) B" }
        if absBytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if absBytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1024 / 1024) }
        return String(format: "%.2f GB", Double(bytes) / 1024 / 1024 / 1024)
    }
}
