import SwiftUI
import MacCleanerCore

struct DuplicateFinderView: View {
    @Bindable var viewModel: DuplicateFinderViewModel
    let onBack: () -> Void

    @State private var selectedGroupID: String?
    @State private var showConfirm = false
    @State private var showDirectoryPicker = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let cleanError = viewModel.lastCleanError {
                Divider()
                Text(cleanError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
            }
            Divider()
            content
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { onBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.plain)

            Image(systemName: "doc.on.doc.fill")
                .foregroundStyle(.pink)
            Text("重复文件查找")
                .font(.headline)

            Spacer()

            if case .done = viewModel.phase, !viewModel.groups.isEmpty {
                strategyPicker

                Text("可回收 \(SizeFormatter.format(bytes: viewModel.deletableSize))")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("清理选中重复项") {
                    showConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(viewModel.itemsToDelete.isEmpty)
                .confirmationDialog("确认清理", isPresented: $showConfirm) {
                    Button("移到废纸篓", role: .destructive) { viewModel.clean() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将把 \(viewModel.itemsToDelete.count) 个重复文件移到废纸篓")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            idleView
        case .scanning, .cleaning:
            VStack {
                Spacer()
                ProgressView({ if case .scanning = viewModel.phase { return "正在扫描重复文件..." } else { return "正在清理..." } }())
                Text("按文件大小 → 部分哈希 → 完整哈希三阶段筛选")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Spacer()
            }
        case .done:
            if viewModel.groups.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("没有找到重复文件")
                        .font(.title3)
                    Spacer()
                }
            } else {
                resultView
            }
        case let .failed(msg):
            VStack {
                Spacer()
                Text("扫描失败: \(msg)")
                    .foregroundStyle(.red)
                Button("重试") { viewModel.startScan() }
                Spacer()
            }
        }
    }

    private var idleView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "doc.on.doc")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("查找主目录下的重复文件")
                .font(.title3)
            Text("通过文件内容哈希精确识别完全相同的文件")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("开始扫描") {
                viewModel.startScan()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
    }

    private var resultView: some View {
        HStack(spacing: 0) {
            // 左侧：重复组列表
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.groups) { group in
                        groupRow(group)
                        Divider()
                    }
                }
            }
            .frame(width: 300)
            .background(Color(.windowBackgroundColor))

            Divider()

            // 右侧：选中组的文件列表
            if let groupID = selectedGroupID,
               let group = viewModel.groups.first(where: { $0.id == groupID }) {
                fileList(group)
            } else {
                VStack {
                    Spacer()
                    Text("选择左侧的重复组查看文件")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        let isSelected = selectedGroupID == group.id
        return Button {
            selectedGroupID = group.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.files.first?.name ?? "")
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("\(group.duplicateCount) 个副本  可回收 \(SizeFormatter.format(bytes: group.totalWastedSpace))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(SizeFormatter.format(bytes: group.fileSize))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileList(_ group: DuplicateGroup) -> some View {
        // 无显式选择时 keptID 为 nil：不标记任何"删除"项
        let keptID = viewModel.keptFiles[group.id]

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("选择要保留的文件，其余将被清理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                ForEach(group.files) { file in
                    let isKept = file.id == keptID
                    HStack(spacing: 10) {
                        Image(systemName: isKept ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isKept ? .green : .secondary)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(file.name).fontWeight(.medium).lineLimit(1)
                                if isKept {
                                    Text("保留")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.green.opacity(0.1), in: Capsule())
                                } else if keptID != nil {
                                    Text("删除")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.red.opacity(0.1), in: Capsule())
                                }
                            }
                            Text(shortPath(file.path))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                        } label: {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.keptFiles[group.id] = file.id
                    }

                    Divider().padding(.leading, 48)
                }
            }
        }
    }

    // MARK: - 保留策略

    private var strategyPicker: some View {
        HStack(spacing: 4) {
            Text("保留策略:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { viewModel.selectedStrategy },
                set: { viewModel.applyStrategy($0) }
            )) {
                Text("最新文件").tag(DuplicateRetentionStrategy.keepNewest)
                Text("最短路径").tag(DuplicateRetentionStrategy.keepShortestPath)
                Text("指定目录").tag(DuplicateRetentionStrategy.keepInDirectory)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            if viewModel.selectedStrategy == .keepInDirectory {
                Button("选择目录") { showDirectoryPicker = true }
                    .controlSize(.small)
            }
        }
        .fileImporter(
            isPresented: $showDirectoryPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case let .success(url) = result {
                viewModel.preferredDirectory = url.path
                viewModel.applyStrategy(.keepInDirectory)
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = DiskScanner.homeDirectory
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}
