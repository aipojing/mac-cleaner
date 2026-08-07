import SwiftUI
import MacCleanerCore

struct ResultsView: View {
    @Bindable var viewModel: ResultsViewModel
    let onClean: ([CleanableItem]) -> Void
    let onBack: () -> Void

    @State private var collapsedModules: Set<ModuleIdentifier> = []
    @State private var scrollTarget: ModuleIdentifier?
    @State private var isSidebarCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            searchBar
            Divider()
            if viewModel.isSearchActive {
                searchResultsArea
            } else {
                HStack(spacing: 0) {
                    if !isSidebarCollapsed {
                        sidebar
                        Divider()
                    }
                    mainList
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed)
        .task {
            // 只读本地 AI 缓存，不触发网络请求
            await viewModel.loadCachedAssessments()
        }
    }

    // MARK: - 搜索栏与筛选 chips（纯本地，不触发 AI）

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索名称、路径、标签或 AI 结论…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Picker("排序", selection: $viewModel.sortMode) {
                    Text("相关度").tag(ResultSortMode.relevance)
                    Text("可操作性").tag(ResultSortMode.actionability)
                    Text("大小").tag(ResultSortMode.size)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()

                if viewModel.isSearchActive {
                    Button("重置筛选") {
                        viewModel.resetFilters()
                    }
                    .controlSize(.small)
                }
            }

            // 可清除的筛选 chips：模块 / AI 风险 / AI 建议 / 分析状态 / 大小
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    moduleFilterMenu
                    riskFilterMenu
                    recommendationFilterMenu
                    statusFilterMenu
                    sizeFilterMenu
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var moduleFilterMenu: some View {
        Menu {
            ForEach(viewModel.results, id: \.module) { result in
                Toggle(
                    result.module.displayName,
                    isOn: bindingForModule(result.module)
                )
            }
        } label: {
            filterChipLabel(
                title: viewModel.selectedModules.isEmpty
                    ? "模块"
                    : "模块 \(viewModel.selectedModules.count)",
                isActive: !viewModel.selectedModules.isEmpty
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var riskFilterMenu: some View {
        Menu {
            ForEach(AIRiskLevel.allCases, id: \.self) { risk in
                Toggle(AIAssessmentCard.riskLabel(risk), isOn: bindingForRisk(risk))
            }
        } label: {
            filterChipLabel(
                title: viewModel.selectedRisks.isEmpty
                    ? "AI 风险"
                    : "风险 \(viewModel.selectedRisks.count)",
                isActive: !viewModel.selectedRisks.isEmpty
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var recommendationFilterMenu: some View {
        Menu {
            ForEach(AIRecommendation.allCases, id: \.self) { recommendation in
                Toggle(
                    AIAssessmentCard.recommendationLabel(recommendation),
                    isOn: bindingForRecommendation(recommendation)
                )
            }
        } label: {
            filterChipLabel(
                title: viewModel.selectedRecommendations.isEmpty
                    ? "AI 建议"
                    : "建议 \(viewModel.selectedRecommendations.count)",
                isActive: !viewModel.selectedRecommendations.isEmpty
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var statusFilterMenu: some View {
        Menu {
            ForEach(AssessmentStatus.allCases, id: \.self) { status in
                Toggle(Self.statusLabel(status), isOn: bindingForStatus(status))
            }
        } label: {
            filterChipLabel(
                title: viewModel.selectedAssessmentStatuses.isEmpty
                    ? "分析状态"
                    : "状态 \(viewModel.selectedAssessmentStatuses.count)",
                isActive: !viewModel.selectedAssessmentStatuses.isEmpty
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sizeFilterMenu: some View {
        Menu {
            Button("全部大小") { viewModel.minimumAllocatedSize = nil }
            Button("大于 10 MB") { viewModel.minimumAllocatedSize = 10 * 1024 * 1024 }
            Button("大于 100 MB") { viewModel.minimumAllocatedSize = 100 * 1024 * 1024 }
            Button("大于 1 GB") { viewModel.minimumAllocatedSize = 1024 * 1024 * 1024 }
        } label: {
            filterChipLabel(
                title: viewModel.minimumAllocatedSize.map {
                    "> \(SizeFormatter.format(bytes: $0))"
                } ?? "大小",
                isActive: viewModel.minimumAllocatedSize != nil
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func filterChipLabel(title: String, isActive: Bool) -> some View {
        Text(title)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                isActive ? Color.accentColor.opacity(0.2) : Color(.controlBackgroundColor),
                in: Capsule()
            )
    }

    private func bindingForModule(_ module: ModuleIdentifier) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedModules.contains(module) },
            set: { isOn in
                if isOn { viewModel.selectedModules.insert(module) }
                else { viewModel.selectedModules.remove(module) }
            }
        )
    }

    private func bindingForRisk(_ risk: AIRiskLevel) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedRisks.contains(risk) },
            set: { isOn in
                if isOn { viewModel.selectedRisks.insert(risk) }
                else { viewModel.selectedRisks.remove(risk) }
            }
        )
    }

    private func bindingForRecommendation(_ recommendation: AIRecommendation) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedRecommendations.contains(recommendation) },
            set: { isOn in
                if isOn { viewModel.selectedRecommendations.insert(recommendation) }
                else { viewModel.selectedRecommendations.remove(recommendation) }
            }
        )
    }

    private func bindingForStatus(_ status: AssessmentStatus) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedAssessmentStatuses.contains(status) },
            set: { isOn in
                if isOn { viewModel.selectedAssessmentStatuses.insert(status) }
                else { viewModel.selectedAssessmentStatuses.remove(status) }
            }
        )
    }

    static func statusLabel(_ status: AssessmentStatus) -> String {
        switch status {
        case .notConfigured: return "未配置"
        case .notAnalyzed: return "未分析"
        case .cached: return "已缓存"
        case .loading: return "分析中"
        case .fresh: return "刚完成"
        case .failed: return "失败"
        }
    }

    // MARK: - 搜索结果区（跨模块扁平列表）

    private var searchResultsArea: some View {
        Group {
            if viewModel.allItems.isEmpty {
                ContentUnavailableView(
                    "扫描没有候选",
                    systemImage: "checkmark.circle",
                    description: Text("本次扫描没有发现可清理的项目")
                )
            } else if viewModel.visibleItems.isEmpty {
                ContentUnavailableView(
                    "当前筛选无匹配",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("试试调整搜索词或重置筛选")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.visibleItems) { item in
                            ItemRowView(
                                item: item,
                                isSelected: viewModel.isSelected(item),
                                onToggle: { viewModel.toggleItem(item) },
                                assessmentState: viewModel.assessmentStates[item.id],
                                isPartOfBatchAnalysis: viewModel.isPartOfBatchAnalysis(item),
                                isLocallyExecutable: ResultsViewModel.isLocallyExecutable(item),
                                onAnalyze: {
                                    Task { await viewModel.analyzeItem(item) }
                                },
                                onReanalyze: {
                                    Task { await viewModel.reanalyzeItem(item) }
                                },
                                onCancelAnalysis: {
                                    Task { await viewModel.cancelAIAnalysis() }
                                }
                            )
                            .padding(.leading, 40)
                            .padding(.trailing, 20)
                            .padding(.vertical, 2)

                            Divider().padding(.leading, 72)
                        }
                    }
                }
                .background(Color(.textBackgroundColor))
            }
        }
    }

    // MARK: - 顶部固定汇总栏

    private var topBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.plain)
                .help("返回摘要")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSidebarCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .help(isSidebarCollapsed ? "展开左侧菜单" : "收起左侧菜单")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("共发现可清理 \(SizeFormatter.format(bytes: viewModel.totalSize))")
                    .font(.headline)
                Text("已选 \(viewModel.selectedCount) 项  \(SizeFormatter.format(bytes: viewModel.totalSelectedSize))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isBatchAnalyzing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在分析 \(viewModel.batchAnalyzingItemIDs.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("取消") {
                        Task { await viewModel.cancelAIAnalysis() }
                    }
                    .controlSize(.small)
                }
            } else {
                Button("AI 分析下一批（\(viewModel.nextAnalysisBatchCount)/\(viewModel.unanalyzedCount)）") {
                    Task { await viewModel.analyzeMissingItems() }
                }
                .controlSize(.small)
                .disabled(viewModel.unanalyzedCount == 0)
                .help("每次最多分析 10 项；也可点击每一行的“AI 分析”单独检查")
            }

            Button("全选可清理项") {
                viewModel.selectAllEligible()
            }
            .controlSize(.small)

            Button(action: {
                onClean(viewModel.selectedItems)
            }) {
                Text("开始清理")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.accent)
            .controlSize(.large)
            .disabled(viewModel.selectedItemIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - 左侧分类导航

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.results, id: \.module) { result in
                sidebarItem(result: result)
            }
            Spacer()
        }
        .frame(width: 180)
        .background(Color(.windowBackgroundColor))
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private func sidebarItem(result: ScanResult) -> some View {
        let selectedCount = selectedCountForModule(result.module)

        return Button {
            // 展开目标分组并滚动到它
            collapsedModules.remove(result.module)
            scrollTarget = result.module
        } label: {
            HStack(spacing: 8) {
                Image(systemName: result.module.sfSymbol)
                    .font(.caption)
                    .foregroundStyle(result.module.color)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(result.module.displayName)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text("\(result.items.count) 项  \(SizeFormatter.format(bytes: result.totalSize))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if selectedCount > 0 {
                    Text("\(selectedCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右侧主列表（可折叠）

    private var mainList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(viewModel.results, id: \.module) { result in
                        Section {
                            if !collapsedModules.contains(result.module) {
                                ForEach(result.items) { item in
                                    ItemRowView(
                                        item: item,
                                        isSelected: viewModel.isSelected(item),
                                        onToggle: { viewModel.toggleItem(item) },
                                        assessmentState: viewModel.assessmentStates[item.id],
                                        isPartOfBatchAnalysis: viewModel.isPartOfBatchAnalysis(item),
                                        isLocallyExecutable: ResultsViewModel.isLocallyExecutable(item),
                                        onAnalyze: {
                                            Task { await viewModel.analyzeItem(item) }
                                        },
                                        onReanalyze: {
                                            Task { await viewModel.reanalyzeItem(item) }
                                        },
                                        onCancelAnalysis: {
                                            Task { await viewModel.cancelAIAnalysis() }
                                        }
                                    )
                                    .padding(.leading, 40)
                                    .padding(.trailing, 20)
                                    .padding(.vertical, 2)

                                    Divider().padding(.leading, 72)
                                }
                            }
                        } header: {
                            sectionHeader(result: result)
                                .id(result.module)
                        }
                    }
                }
            }
            .background(Color(.textBackgroundColor))
            .onChange(of: scrollTarget) { _, target in
                if let target {
                    withAnimation {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    scrollTarget = nil
                }
            }
        }
    }

    // MARK: - 分组标题（可点击折叠）

    private func sectionHeader(result: ScanResult) -> some View {
        let isCollapsed = collapsedModules.contains(result.module)
        let selectedCount = selectedCountForModule(result.module)
        let selectedSize = selectedSizeForModule(result.module)

        return HStack(spacing: 10) {
            // 折叠箭头
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Image(systemName: result.module.sfSymbol)
                .font(.title3)
                .foregroundStyle(result.module.color)
                .frame(width: 24)

            Text(result.module.displayName)
                .font(.headline)

            Text("共 \(SizeFormatter.format(bytes: result.totalSize))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if selectedCount > 0 {
                Text("已选 \(selectedCount) 项 \(SizeFormatter.format(bytes: selectedSize))")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }

            Spacer()

            Button {
                viewModel.toggleModule(result.module)
            } label: {
                Text(selectedCount == result.items.count ? "取消全选" : "全选")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isCollapsed {
                    collapsedModules.remove(result.module)
                } else {
                    collapsedModules.insert(result.module)
                }
            }
        }
    }

    // MARK: - Helpers

    private func selectedCountForModule(_ moduleID: ModuleIdentifier) -> Int {
        let items = viewModel.results.first { $0.module == moduleID }?.items ?? []
        return items.filter { viewModel.selectedItemIDs.contains($0.id) }.count
    }

    private func selectedSizeForModule(_ moduleID: ModuleIdentifier) -> Int64 {
        viewModel.selectedSize(for: moduleID)
    }
}
