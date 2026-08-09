import SwiftUI
import MacCleanerCore
import UniformTypeIdentifiers

struct AppUninstallerView: View {
    @Bindable var viewModel: AppUninstallerViewModel
    let onBack: () -> Void

    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if viewModel.phase == .loadingApps {
                loadingState
            } else {
                HStack(spacing: 0) {
                    appList
                    Divider()
                    detailPanel
                }
            }
        }
        .onAppear { viewModel.loadApps() }
        .onDisappear { viewModel.stopBackgroundResidualPrefetch() }
        .alert("卸载完成", isPresented: .init(
            get: { viewModel.report != nil },
            set: { if !$0 { viewModel.report = nil } }
        )) {
            Button("好") { viewModel.report = nil }
        } message: {
            if let r = viewModel.report {
                Text("已移入废纸篓 \(SizeFormatter.format(bytes: r.bytesMovedToTrash))\n成功 \(r.residualsRemoved) 项，失败 \(r.failures) 项\n清空废纸篓后空间才会真正释放")
            }
        }
    }

    /// 应用列表加载中：全区域居中提示
    private var loadingState: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("正在加载应用列表…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { onBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.plain)

            Image(systemName: "trash")
                .foregroundStyle(.red)
            Text("应用卸载器")
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - 左侧应用列表

    private var appList: some View {
        VStack(spacing: 0) {
            // 搜索框
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.bar)

            Divider()

            if viewModel.isPrefetchingResidualTotals {
                Text("正在后台补全关联文件 \(viewModel.residualPrefetchCompleted)/\(viewModel.residualPrefetchTotal)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                Divider()
            }

            // 列表
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredApps) { app in
                        appRow(app)
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
        }
        .frame(width: 280)
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let isSelected = viewModel.selectedApp?.id == app.id
        return Button {
            viewModel.selectApp(app)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: viewModel.appIcon(for: app))
                    .resizable()
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(appListSizeText(for: app))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.1) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                Task { @MainActor in
                    viewModel.selectAppFromURL(url)
                }
            }
        }
    }

    // MARK: - 右侧详情

    private var detailPanel: some View {
        Group {
            if let app = viewModel.selectedApp {
                VStack(spacing: 0) {
                    appDetailHeader(app)
                    Divider()

                    if viewModel.phase == .scanningResiduals {
                        VStack(spacing: 14) {
                            Spacer()
                            ProgressView()
                                .controlSize(.large)
                            Text("正在扫描残留文件…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else if let residuals = viewModel.residuals {
                        residualsList(residuals)
                        Divider()
                        uninstallBar(app)
                    }
                }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "arrow.left.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.quaternary)
                    Text("选择一个应用查看详情")
                        .foregroundStyle(.secondary)
                    Text("也可以拖放 .app 文件到左侧列表")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func appDetailHeader(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: viewModel.appIcon(for: app))
                .resizable()
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.title3).fontWeight(.semibold)
                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                Text(appDetailSizeText(for: app))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
    }

    private func residualsList(_ residuals: AppResidualFiles) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("残留文件 \(viewModel.selectedSelectableResidualCount)/\(viewModel.selectableResidualCount) 项已选")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(viewModel.areAllSelectableResidualsSelected ? "取消全选" : "全选") {
                        viewModel.toggleSelectAllResiduals()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!viewModel.hasSelectableResiduals)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                ForEach(residuals.groups) { group in
                    HStack {
                        Text(group.label)
                        Spacer()
                        Text("\(group.items.count) 项 · \(SizeFormatter.format(bytes: group.totalSize))")
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                    ForEach(group.items) { item in
                        residualRow(item)
                        Divider().padding(.leading, 48)
                    }
                }
            }
        }
    }

    private func residualRow(_ item: ResidualItem) -> some View {
        let selectable = viewModel.canSelect(item)
        return HStack(spacing: 10) {
            Button {
                viewModel.toggleResidual(item)
            } label: {
                Image(systemName: selectable
                    ? (viewModel.isResidualSelected(item) ? "checkmark.circle.fill" : "circle")
                    : "minus.circle")
                    .foregroundStyle(selectable
                        ? (viewModel.isResidualSelected(item) ? Color.blue : Color.secondary)
                        : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!selectable)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).fontWeight(.medium).lineLimit(1)
                Text(shortPath(item.path))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                if !selectable {
                    Text("无法验证文件身份，已跳过")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }

            Spacer()

            Text(SizeFormatter.format(bytes: item.size))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "folder").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func uninstallBar(_ app: InstalledApp) -> some View {
        HStack {
            Text("残留文件 \(SizeFormatter.format(bytes: viewModel.selectedResidualSize))")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("卸载 \(app.name)", role: .destructive) {
                showConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .confirmationDialog("确认卸载", isPresented: $showConfirm) {
                Button("卸载并清理残留", role: .destructive) { viewModel.uninstall() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将移除 \(app.name) 及选中的残留文件到废纸篓\n可从废纸篓恢复")
            }
        }
        .padding(16)
        .background(.bar)
    }

    private func shortPath(_ path: String) -> String {
        let home = DiskScanner.homeDirectory
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func appListSizeText(for app: InstalledApp) -> String {
        if viewModel.hasScannedResidualTotal(for: app) {
            return "总计 \(SizeFormatter.format(bytes: viewModel.displaySize(for: app)))"
        }
        return "应用 \(SizeFormatter.format(bytes: app.bundleSize))"
    }

    private func appDetailSizeText(for app: InstalledApp) -> String {
        guard viewModel.hasScannedResidualTotal(for: app), let residuals = viewModel.residuals else {
            return "版本 \(app.version)  应用大小 \(SizeFormatter.format(bytes: app.bundleSize))"
        }
        return "版本 \(app.version)  应用 \(SizeFormatter.format(bytes: app.bundleSize)) · 残留 \(SizeFormatter.format(bytes: residuals.totalSize)) · 总计 \(SizeFormatter.format(bytes: viewModel.displaySize(for: app)))"
    }
}
