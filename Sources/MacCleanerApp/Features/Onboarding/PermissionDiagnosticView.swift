import SwiftUI
import MacCleanerCore

struct PermissionDiagnosticView: View {
    @State private var report: PermissionDiagnosticReport?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            if let report {
                fdaStatusSection(report: report)
                directoryListSection(report: report)

                if !report.affectedModules.isEmpty {
                    affectedModulesSection(report: report)
                }
            } else if isRunning {
                ProgressView("正在检测权限...")
                    .frame(maxWidth: .infinity)
            } else {
                Button("运行权限诊断") {
                    runDiagnostic()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .onAppear {
            if report == nil { runDiagnostic() }
        }
    }

    private var headerSection: some View {
        HStack {
            Image(systemName: "stethoscope")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("权限诊断")
                    .font(.headline)
                Text("检测哪些目录因权限限制无法扫描")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if report != nil {
                Button {
                    runDiagnostic()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRunning)
            }
        }
    }

    private func fdaStatusSection(report: PermissionDiagnosticReport) -> some View {
        HStack(spacing: 12) {
            Image(systemName: report.hasFullDiskAccess ? "checkmark.shield.fill" : "xmark.shield.fill")
                .font(.title3)
                .foregroundStyle(report.hasFullDiskAccess ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(report.hasFullDiskAccess ? "完全磁盘访问已开启" : "完全磁盘访问未开启")
                    .font(.subheadline)
                    .fontWeight(.medium)

                if !report.hasFullDiskAccess {
                    Text("部分目录可能无法扫描，扫描结果将不完整")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !report.hasFullDiskAccess {
                Button("去开启") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            (report.hasFullDiskAccess ? Color.green : Color.orange).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func directoryListSection(report: PermissionDiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("目录访问状态")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("可访问 \(report.accessibleCount) / 不可访问 \(report.deniedCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(report.results) { result in
                        directoryRow(result: result)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }

    private func directoryRow(result: DirectoryAccessResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconForStatus(result.status))
                .foregroundStyle(colorForStatus(result.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.displayName)
                    .font(.caption)
                Text(shortenPath(result.path))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(labelForStatus(result.status))
                .font(.caption2)
                .foregroundStyle(colorForStatus(result.status))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(colorForStatus(result.status).opacity(0.1), in: Capsule())
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func affectedModulesSection(report: PermissionDiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("受影响的扫描模块")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 8) {
                ForEach(Array(report.affectedModules), id: \.rawValue) { module in
                    Label(module.displayName, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.1), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            Text("这些模块的扫描结果可能不完整，标记为「未扫描」的项目不会出现在清理列表中")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func runDiagnostic() {
        isRunning = true
        Task.detached {
            let diagnostic = PermissionDiagnostic()
            let result = diagnostic.diagnose()
            await MainActor.run {
                report = result
                isRunning = false
            }
        }
    }

    private func iconForStatus(_ status: DirectoryAccessResult.AccessStatus) -> String {
        switch status {
        case .accessible: return "checkmark.circle.fill"
        case .notFound: return "minus.circle"
        case .denied: return "lock.fill"
        case .sandboxRestricted: return "lock.shield"
        }
    }

    private func colorForStatus(_ status: DirectoryAccessResult.AccessStatus) -> Color {
        switch status {
        case .accessible: return .green
        case .notFound: return .gray
        case .denied: return .red
        case .sandboxRestricted: return .orange
        }
    }

    private func labelForStatus(_ status: DirectoryAccessResult.AccessStatus) -> String {
        switch status {
        case .accessible: return "可访问"
        case .notFound: return "不存在"
        case .denied: return "无权限"
        case .sandboxRestricted: return "受限"
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = DiskScanner.homeDirectory
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
