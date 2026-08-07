import Foundation
import MacCleanerCore

public struct ConfirmationPrompt {
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

    public static func showSummaryAndConfirm(items: [CleanableItem], dryRun: Bool) -> Bool {
        // 预计可释放按物理占用估算：硬链接未集齐路径的对象不计入
        let reclaimable = PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: items,
            allKnownItems: items
        )
        let plainSum = items.reduce(Int64(0)) { $0 + $1.size }

        print("")
        print("\(ANSIStyle.bold)📋 清理计划\(ANSIStyle.reset)")
        print("\(ANSIStyle.dim)\(String(repeating: "─", count: 50))\(ANSIStyle.reset)")

        var grouped: [ModuleIdentifier: [CleanableItem]] = [:]
        for item in items {
            grouped[item.category, default: []].append(item)
        }

        for (module, moduleItems) in grouped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let moduleSize = moduleItems.reduce(Int64(0)) { $0 + $1.size }
            print("  \(ANSIStyle.cyan)\(module.displayName)\(ANSIStyle.reset): \(moduleItems.count) 项, \(ANSIStyle.coloredSize(moduleSize))")
        }

        print("\(ANSIStyle.dim)\(String(repeating: "─", count: 50))\(ANSIStyle.reset)")
        print("  \(ANSIStyle.bold)总计\(ANSIStyle.reset): \(items.count) 项, 预计可释放 \(ANSIStyle.coloredSize(reclaimable))")
        if reclaimable < plainSum {
            print("  \(ANSIStyle.dim)部分硬链接对象的实际释放取决于其他硬链接路径\(ANSIStyle.reset)")
        }
        print("")

        if dryRun {
            print("\(ANSIStyle.yellow)⚠ 试运行模式 — 不会实际删除任何文件\(ANSIStyle.reset)")
            return true
        }

        return confirm("确认执行清理?")
    }
}
