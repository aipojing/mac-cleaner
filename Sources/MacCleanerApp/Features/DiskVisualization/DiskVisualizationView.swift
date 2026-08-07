import SwiftUI
import MacCleanerCore

struct DiskVisualizationView: View {
    var viewModel: DiskVisualizationViewModel
    let onBack: () -> Void
    var onAddToCleanup: ((String, Int64) -> Void)?

    /// 扫描中的实时路径反馈（与扫描页同一 ScanProgress 源）
    @State private var currentScanPath = ""
    @State private var pathPollTask: Task<Void, Never>?

    // 12 色固定色板
    private let palette: [Color] = [
        .blue, .green, .orange, .purple, .red, .teal,
        .indigo, .pink, .cyan, .mint, .brown, .yellow,
    ]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            breadcrumbBar
            Divider()

            if viewModel.isLoading {
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Text("正在扫描目录…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(shortScanPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 480)
                        .animation(.none, value: shortScanPath)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .onAppear { startPathPolling() }
                .onDisappear { pathPollTask?.cancel() }
            } else if let node = viewModel.currentNode {
                GeometryReader { geo in
                    let layout = TreemapLayout.compute(root: node, in: CGRect(origin: .zero, size: geo.size), maxDepth: 1)
                    treemapCanvas(layout: layout, size: geo.size)
                }
            } else {
                VStack {
                    Spacer()
                    Text("点击「开始」扫描磁盘使用情况")
                        .foregroundStyle(.secondary)
                    Button("开始") { viewModel.loadRoot() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
        }
        .onAppear {
            if viewModel.navigationStack.isEmpty { viewModel.loadRoot() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { onBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.plain)

            Image(systemName: "chart.pie.fill")
                .foregroundStyle(.blue)
            Text("磁盘可视化")
                .font(.headline)

            Spacer()

            if let node = viewModel.currentNode {
                Text(SizeFormatter.format(bytes: node.size))
                    .font(.callout)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }

            // Tooltip
            if let tile = viewModel.hoveredTile {
                Text("\(tile.name)  \(SizeFormatter.format(bytes: tile.size))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let names = viewModel.navigationStack.map(\.name)
                let count = names.count
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 4) {
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(name) {
                            viewModel.navigateTo(index: index)
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(index == count - 1 ? Color.primary : Color.blue)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .background(.bar.opacity(0.5))
    }

    private func treemapCanvas(layout: TreemapLayout, size: CGSize) -> some View {
        Canvas { context, canvasSize in
            for tile in layout.tiles {
                let rect = tile.rect
                guard rect.width > 1, rect.height > 1 else { continue }

                // 颜色：根据 colorIndex 和 depth 计算
                let baseColor = palette[tile.colorIndex % palette.count]
                let opacity = max(0.3, 1.0 - Double(tile.depth) * 0.25)

                // 填充
                let path = Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 2)
                context.fill(path, with: .color(baseColor.opacity(opacity)))

                // 边框
                context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 0.5)

                // 文字标签（只在足够大的 tile 上显示）
                if rect.width > 50, rect.height > 20 {
                    let label = "\(tile.name)\n\(SizeFormatter.format(bytes: tile.size))"
                    let textRect = rect.insetBy(dx: 4, dy: 2)
                    context.draw(
                        Text(label)
                            .font(.system(size: min(11, rect.height / 3)))
                            .foregroundStyle(.white),
                        in: textRect
                    )
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case let .active(point):
                viewModel.hoveredTile = layout.tiles.last { $0.rect.contains(point) }
            case .ended:
                viewModel.hoveredTile = nil
            }
        }
        .onTapGesture { location in
            if let tile = layout.tiles.last(where: { $0.rect.contains(location) }), tile.isDirectory {
                viewModel.drillInto(tile)
            }
        }
        .contextMenu {
            if let tile = viewModel.hoveredTile {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tile.path)])
                }

                if let callback = onAddToCleanup {
                    Button("加入清理列表") {
                        callback(tile.path, tile.size)
                    }
                }

                Divider()

                Button("复制路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tile.path, forType: .string)
                }

                Button("复制大小") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SizeFormatter.format(bytes: tile.size), forType: .string)
                }
            }
        }
    }

    // MARK: - 扫描进度反馈

    private var shortScanPath: String {
        let path = currentScanPath
        guard !path.isEmpty else { return " " }
        let home = DiskScanner.homeDirectory
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func startPathPolling() {
        pathPollTask?.cancel()
        pathPollTask = Task {
            while !Task.isCancelled {
                let path = ScanProgress.shared.currentPath
                if !path.isEmpty { currentScanPath = path }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }
}
