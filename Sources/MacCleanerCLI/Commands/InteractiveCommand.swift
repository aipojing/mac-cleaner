import Foundation
import MacCleanerCore

public struct InteractiveCommand {
    private let terminal = TerminalCapabilities()

    public init() {}

    public func run() async throws {
        printBanner()

        // Step 1: Check available modules
        let available = ModuleRegistry.availableModules()
        if available.isEmpty {
            print("\(ANSIStyle.yellow)没有检测到可清理的项目\(ANSIStyle.reset)")
            return
        }

        print("\(ANSIStyle.bold)检测到 \(available.count) 个可用模块\(ANSIStyle.reset)\n")

        // Step 2: Let user select modules
        if terminal.isInteractive {
            try await runInteractive(modules: available)
        } else {
            try await runNonInteractive(modules: available)
        }
    }

    private func runInteractive(modules: [any CleanerModule]) async throws {
        // Module selection
        // 初始选择为空：只有用户主动勾选才进入扫描范围
        var moduleItems = modules.map { module in
            SelectionList.Item(
                label: "\(module.displayName) — \(module.description)",
                isSelected: false
            )
        }

        let selectedIndices = SelectionList.run(title: "选择要扫描的模块:", items: &moduleItems)
        guard !selectedIndices.isEmpty else {
            print("已取消")
            return
        }

        let selectedModules = selectedIndices.map { modules[$0] }

        // Step 3: Scan（统一入口：共享 ScanContext）
        print("\n\(ANSIStyle.bold)🔍 扫描中...\(ANSIStyle.reset)\n")

        let coordinator = ScanCoordinator(modules: selectedModules)
        let allResults = try await coordinator.scan()
        for result in allResults {
            print("  扫描 \(result.module.displayName)... \(ANSIStyle.green)✔\(ANSIStyle.reset) \(result.items.count) 项, \(ANSIStyle.coloredSize(result.totalSize))")
        }

        // Step 4: Show results summary
        printResultsSummary(allResults)

        // Step 5: Item selection per module
        var selectedItems: [CleanableItem] = []

        for result in allResults {
            guard !result.items.isEmpty else { continue }

            print("\n\(ANSIStyle.bold)\(result.module.displayName)\(ANSIStyle.reset)")

            // 初始选择为空：所有候选默认不选中
            var items = result.items.map { item in
                SelectionList.Item(
                    label: item.displayName,
                    detail: item.evidenceTags.joined(separator: ", "),
                    sizeText: ANSIStyle.coloredSize(item.size),
                    isSelected: false
                )
            }

            let selected = SelectionList.run(title: "选择要清理的项目:", items: &items)
            for index in selected {
                selectedItems.append(result.items[index])
            }
        }

        guard !selectedItems.isEmpty else {
            print("\n\(ANSIStyle.yellow)未选择任何项目\(ANSIStyle.reset)")
            return
        }

        // Step 6: Confirm and clean
        let confirmed = ConfirmationPrompt.showSummaryAndConfirm(items: selectedItems, dryRun: false)
        guard confirmed else {
            print("已取消")
            return
        }

        // Step 7: Execute
        print("\n\(ANSIStyle.bold)🧹 开始清理...\(ANSIStyle.reset)\n")

        var totalFreed: Int64 = 0
        var grouped: [ModuleIdentifier: [CleanableItem]] = [:]
        for item in selectedItems {
            grouped[item.category, default: []].append(item)
        }

        for module in selectedModules {
            guard let items = grouped[module.identifier], !items.isEmpty else { continue }
            print("  清理 \(module.displayName)...", terminator: "")
            fflush(stdout)
            let report = try await module.clean(items: items, dryRun: false)
            totalFreed += report.totalFreed
            if report.failureCount > 0 {
                print(" \(ANSIStyle.yellow)⚠\(ANSIStyle.reset) \(report.successCount)/\(items.count)")
                for failed in report.failedItems {
                    print("    \(ANSIStyle.red)✗\(ANSIStyle.reset) \(failed.path): \(failed.error)")
                }
            } else {
                print(" \(ANSIStyle.green)✔\(ANSIStyle.reset)")
            }
        }

        // Step 8: Summary
        print("\n\(ANSIStyle.green)✨ 清理完成！\(ANSIStyle.reset)")
        print("已回收空间: \(ANSIStyle.bold)\(ANSIStyle.coloredSize(totalFreed))\(ANSIStyle.reset)")
    }

    private func runNonInteractive(modules: [any CleanerModule]) async throws {
        // Non-interactive: just scan and print results
        print("非交互式模式 — 请使用 'mac-cleaner scan' 或 'mac-cleaner clean' 命令\n")

        for module in modules {
            let result = try await module.scan(context: ScanContext())
            print("  \(module.displayName): \(result.items.count) 项, \(result.totalSize.formattedSize)")
        }

        print("\n使用 'mac-cleaner clean --all --yes' 清理所有候选")
    }

    private func printBanner() {
        print("""

        \(ANSIStyle.bold)\(ANSIStyle.cyan)╔══════════════════════════════════════╗
        ║         🧹 Mac Cleaner v1.0         ║
        ║       macOS 磁盘清理工具              ║
        ╚══════════════════════════════════════╝\(ANSIStyle.reset)

        """)
    }

    private func printResultsSummary(_ results: [ScanResult]) {
        let totalSize = PhysicalSizeCalculator.uniqueAllocatedBytes(
            in: results.flatMap(\.items)
        )

        print("\n\(ANSIStyle.bold)📊 扫描结果\(ANSIStyle.reset)\n")

        TableRenderer.render(
            columns: [
                .init(header: "模块", minWidth: 14),
                .init(header: "项目数", minWidth: 6, alignment: .right),
                .init(header: "总大小", minWidth: 10, alignment: .right),
            ],
            rows: results.map { result in
                [
                    result.module.displayName,
                    "\(result.items.count)",
                    ANSIStyle.coloredSize(result.totalSize),
                ]
            }
        )

        print("\n\(ANSIStyle.bold)全部候选\(ANSIStyle.reset): \(ANSIStyle.coloredSize(totalSize))")
    }
}
