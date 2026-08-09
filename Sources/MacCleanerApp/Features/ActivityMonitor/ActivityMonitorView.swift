import SwiftUI
import MacCleanerCore

struct ActivityMonitorView: View {
    @Bindable var viewModel: ActivityMonitorViewModel
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
        }
        .onAppear { viewModel.startMonitoring() }
        .onDisappear { viewModel.stopMonitoring() }
        .confirmationDialog(
            "终止进程",
            isPresented: $viewModel.showKillConfirm,
            titleVisibility: .visible
        ) {
            if let proc = viewModel.pendingKillProcess {
                Button("终止「\(proc.name)」", role: .destructive) {
                    viewModel.confirmKill()
                }
                Button("取消", role: .cancel) {
                    viewModel.cancelKill()
                }
            }
        } message: {
            if let proc = viewModel.pendingKillProcess {
                Text("PID \(proc.id) · \(proc.path)")
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                Text("活动监视器")
                    .font(.title3)
                    .fontWeight(.bold)
                if viewModel.phase == .monitoring {
                    let countText = viewModel.isFiltered
                        ? "\(viewModel.processCount)/\(viewModel.totalProcessCount) 个进程"
                        : "\(viewModel.processCount) 个进程"
                    Text("\(countText) · 内存合计 \(formatBytes(viewModel.totalMemoryUsage))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if viewModel.phase == .monitoring {
                // 搜索框 — 整个容器固定宽度，TextField 自然填充，clipShape 防止内容溢出圆角
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索进程名、路径或 PID…", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity)
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(width: 240)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // 排序
                Picker("排序", selection: $viewModel.sortKey) {
                    ForEach(ActivityMonitorViewModel.SortKey.allCases, id: \.self) { key in
                        Text(key.rawValue).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()

                // AI 状态/风险/建议筛选（只读已有状态，不触发分析）
                Menu {
                    Section("分析状态") {
                        ForEach(AssessmentStatus.allCases, id: \.self) { status in
                            Toggle(
                                ResultsView.statusLabel(status),
                                isOn: Binding(
                                    get: { viewModel.selectedAssessmentStatuses.contains(status) },
                                    set: { isOn in
                                        if isOn { viewModel.selectedAssessmentStatuses.insert(status) }
                                        else { viewModel.selectedAssessmentStatuses.remove(status) }
                                    }
                                )
                            )
                        }
                    }
                    Section("AI 风险") {
                        ForEach(AIRiskLevel.allCases, id: \.self) { risk in
                            Toggle(
                                AIAssessmentCard.riskLabel(risk),
                                isOn: Binding(
                                    get: { viewModel.selectedRisks.contains(risk) },
                                    set: { isOn in
                                        if isOn { viewModel.selectedRisks.insert(risk) }
                                        else { viewModel.selectedRisks.remove(risk) }
                                    }
                                )
                            )
                        }
                    }
                    Section("能否结束") {
                        ForEach(AIRecommendation.allCases, id: \.self) { recommendation in
                            Toggle(
                                AIAssessmentCard.recommendationLabel(recommendation, context: .process),
                                isOn: Binding(
                                    get: { viewModel.selectedRecommendations.contains(recommendation) },
                                    set: { isOn in
                                        if isOn { viewModel.selectedRecommendations.insert(recommendation) }
                                        else { viewModel.selectedRecommendations.remove(recommendation) }
                                    }
                                )
                            )
                        }
                    }
                } label: {
                    let activeCount = viewModel.selectedAssessmentStatuses.count
                        + viewModel.selectedRisks.count
                        + viewModel.selectedRecommendations.count
                    Label(
                        activeCount > 0 ? "筛选 \(activeCount)" : "筛选",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                }
                .help("按 AI 分析状态、结束风险和结论筛选（不触发分析）")

                if viewModel.isFiltered {
                    Button {
                        viewModel.searchText = ""
                        viewModel.selectedAssessmentStatuses = []
                        viewModel.selectedRisks = []
                        viewModel.selectedRecommendations = []
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help("清除搜索与筛选")
                }

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("手动刷新")

                if viewModel.isBatchAnalyzing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在分析 \(viewModel.batchAnalyzingProcessIDs.count) 个进程")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("取消") {
                            Task { await viewModel.cancelAIAnalysis() }
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button("AI 分析下一批（\(viewModel.nextAnalysisBatchCount)/\(viewModel.unanalyzedCount)）") {
                        Task { await viewModel.analyzeMissingProcesses() }
                    }
                    .controlSize(.small)
                    .disabled(viewModel.unanalyzedCount == 0)
                    .help("每次最多分析 10 个进程；也可在右侧对当前进程单独分析")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Content

    private var contentArea: some View {
        Group {
            switch viewModel.phase {
            case .idle, .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在获取进程列表…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .monitoring:
                HStack(spacing: 0) {
                    processList
                    Divider()
                    detailPanel
                }

            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("获取进程失败")
                        .font(.headline)
                    Text(msg)
                        .foregroundStyle(.secondary)
                    Button("重试") {
                        viewModel.startMonitoring()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Process List

    private var processList: some View {
        List(viewModel.filteredProcesses, selection: Binding(
            get: { viewModel.selectedProcess?.id },
            set: { pid in
                viewModel.selectedProcess = viewModel.processes.first { $0.id == pid }
            }
        )) { proc in
            ProcessRowView(process: proc)
                .tag(proc.id)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minWidth: 420)
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        Group {
            if let proc = viewModel.selectedProcess {
                processDetail(proc)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.right")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("选择一个进程查看详情")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 260, idealWidth: 280)
    }

    private func processDetail(_ proc: RunningProcess) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(proc.name)
                    .font(.title2)
                    .fontWeight(.bold)

                // 属性列表（只展示客观事实）
                detailRow(label: "PID", value: "\(proc.id)")
                detailRow(label: "用户", value: proc.user)
                detailRow(label: "CPU", value: String(format: "%.1f%%", proc.cpuPercent))
                detailRow(label: "内存", value: formatBytes(proc.residentMemoryBytes))
                detailRow(label: "运行时长", value: formatElapsed(proc.elapsedSeconds))

                if !proc.path.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("路径")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                        Text(proc.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Divider()

                // AI 分析区（解释信息，不改变终止按钮权限）
                aiSection(proc)

                Divider()

                // 操作按钮
                actionButtons(proc)

                Spacer()
            }
            .padding(16)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.body)
                .fontWeight(.medium)
            Spacer()
        }
    }

    /// AI 分析区：未分析时只显示分析按钮；缓存命中显示卡片。
    /// AI 结果只作解释信息，终止按钮始终由本地 guard 裁决。
    @ViewBuilder
    private func aiSection(_ proc: RunningProcess) -> some View {
        let state = viewModel.assessmentState(for: proc)
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .notConfigured:
                Label("未配置 API Key，请在设置中配置", systemImage: "key")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("AI 正在判断结束影响…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("取消") {
                        Task { await viewModel.cancelAIAnalysis() }
                    }
                    .font(.callout)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            default:
                if let assessment = state?.assessment {
                    AIAssessmentCard(
                        assessment: assessment,
                        fromCache: {
                            if case .cached = state { return true }
                            return false
                        }(),
                        context: .process
                    )
                    HStack(spacing: 12) {
                        Button("AI 重新判断") {
                            Task { await viewModel.reanalyze(proc) }
                        }
                        .font(.callout)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                } else {
                    HStack(spacing: 12) {
                        Button("AI 判断能否结束") {
                            Task { await viewModel.analyze(proc) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if case let .failed(message, _) = state {
                    HStack(spacing: 8) {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                        Button("重试") {
                            Task { await viewModel.analyze(proc) }
                        }
                        .font(.callout)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
            }
        }
    }

    private func actionButtons(_ proc: RunningProcess) -> some View {
        VStack(spacing: 8) {
            if proc.identity == nil {
                Label("无法验证进程身份，不可终止", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    viewModel.requestKill(pid: proc.id)
                } label: {
                    Label("终止进程", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                Button {
                    viewModel.requestKill(pid: proc.id, force: true)
                } label: {
                    Label("强制终止", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            if let error = viewModel.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formatElapsed(_ seconds: UInt64?) -> String {
        guard let seconds else { return "未知" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(minutes) 分钟"
    }
}

// MARK: - Process Row

struct ProcessRowView: View {
    let process: RunningProcess

    var body: some View {
        HStack(spacing: 10) {
            // 名称 + 路径
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(process.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // 资源占用
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatMemory)
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                Text(String(format: "%.1f%% CPU", process.cpuPercent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private var formatMemory: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(process.residentMemoryBytes))
    }
}
