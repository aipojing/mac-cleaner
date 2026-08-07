import SwiftUI
import MacCleanerCore

struct ItemRowView: View {
    let item: CleanableItem
    let isSelected: Bool
    let onToggle: () -> Void
    let assessmentState: AIAssessmentState?
    let isPartOfBatchAnalysis: Bool
    /// 本地可执行性预判：false 时即使 AI 建议操作也无法执行
    let isLocallyExecutable: Bool
    let onAnalyze: () -> Void
    let onReanalyze: () -> Void
    let onCancelAnalysis: () -> Void

    @State private var showAI = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? .blue : .secondary)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(displayPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.path)
                }

                Spacer()

                aiActionView

                SizeLabel(bytes: item.size)
                    .frame(minWidth: 70, alignment: .trailing)

                Button {
                    revealInFinder()
                } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("在 Finder 中显示")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            // AI 卡片：本地 guard 的不可执行状态优先展示
            if let assessment = assessmentState?.assessment {
                if !isLocallyExecutable {
                    Label("本地安全校验未通过，无法执行", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.leading, 40)
                }
                AIAssessmentCard(
                    assessment: assessment,
                    fromCache: isCachedState
                )
                .padding(.leading, 40)
            }
            if case let .failed(message, _) = assessmentState {
                HStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("重试") { onAnalyze() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - AI 状态操作区（不含选择控件）

    @ViewBuilder
    private var aiActionView: some View {
        switch assessmentState {
        case .notConfigured:
            Text("未配置 API Key")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                if isPartOfBatchAnalysis {
                    Text("批量分析中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("取消") { onCancelAnalysis() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }
            }
        case .cached, .fresh:
            Button("AI 重新检查") { onReanalyze() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
        case let .failed(_, previous):
            if previous != nil {
                Button("AI 重新检查") { onReanalyze() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
            } else {
                Button("AI 分析") { onAnalyze() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .notAnalyzed, .none:
            Button("AI 分析") { onAnalyze() }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var isCachedState: Bool {
        if case .cached = assessmentState { return true }
        return false
    }

    private var displayPath: String {
        let home = DiskScanner.homeDirectory
        if item.path.hasPrefix(home) {
            return "~" + item.path.dropFirst(home.count)
        }
        return item.path
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: item.path)
        if FileManager.default.fileExists(atPath: item.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            NSWorkspace.shared.open(parent)
        }
    }
}
