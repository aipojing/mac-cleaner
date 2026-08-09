import Foundation
import MacCleanerCore

public struct ConfirmationPrompt {
    /// 用户数据模块：确认摘要中必须逐条列出完整路径（删除确认，完整性优先）
    static let userDataModules: Set<ModuleIdentifier> = [.largeFiles]

    public static func confirm(_ message: String, defaultYes: Bool = false) -> Bool {
        let hint = defaultYes ? "[Y/n]" : "[y/N]"
        print("\(ANSIStyle.bold)\(message)\(ANSIStyle.reset) \(ANSIStyle.dim)\(hint)\(ANSIStyle.reset) ", terminator: "")
        fflush(stdout)

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return defaultYes
        }

        if input.isEmpty { return defaultYes }
        return input == "y" || input == "yes"
    }

    /// 生成清理计划摘要文本（纯函数，便于测试与审阅）。
    /// 用户数据模块（如大文件）始终逐条列出"路径 + 大小"；
    /// dry-run 预览下所有模块都逐条列出，让预览真正可审阅。
    static func makeSummary(items: [CleanableItem], dryRun: Bool) -> String {
        // 预计可释放按物理占用估算：硬链接未集齐路径的对象不计入
        let reclaimable = PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: items,
            allKnownItems: items
        )
        let plainSum = items.reduce(Int64(0)) { $0 + $1.size }

        var grouped: [ModuleIdentifier: [CleanableItem]] = [:]
        for item in items {
            grouped[item.category, default: []].append(item)
        }

        var lines: [String] = []
        lines.append("")
        lines.append("\(ANSIStyle.bold)📋 清理计划\(ANSIStyle.reset)")
        lines.append("\(ANSIStyle.dim)\(String(repeating: "─", count: 50))\(ANSIStyle.reset)")

        for (module, moduleItems) in grouped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let moduleSize = moduleItems.reduce(Int64(0)) { $0 + $1.size }
            lines.append("  \(ANSIStyle.cyan)\(module.displayName)\(ANSIStyle.reset): \(moduleItems.count) 项, \(ANSIStyle.coloredSize(moduleSize))")

            let listPaths = dryRun || userDataModules.contains(module)
            if listPaths {
                for item in moduleItems {
                    lines.append("    \(item.path)  \(ANSIStyle.dim)(\(ANSIStyle.coloredSize(item.size)))\(ANSIStyle.reset)")
                }
            }
        }

        lines.append("\(ANSIStyle.dim)\(String(repeating: "─", count: 50))\(ANSIStyle.reset)")
        lines.append("  \(ANSIStyle.bold)总计\(ANSIStyle.reset): \(items.count) 项, 预计可释放 \(ANSIStyle.coloredSize(reclaimable))")
        if reclaimable < plainSum {
            lines.append("  \(ANSIStyle.dim)部分硬链接对象的实际释放取决于其他硬链接路径\(ANSIStyle.reset)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func showSummaryAndConfirm(items: [CleanableItem], dryRun: Bool) -> Bool {
        print(makeSummary(items: items, dryRun: dryRun))

        if dryRun {
            print("\(ANSIStyle.yellow)⚠ 试运行模式 — 不会实际删除任何文件\(ANSIStyle.reset)")
            return true
        }

        return confirm("确认执行清理?")
    }
}
