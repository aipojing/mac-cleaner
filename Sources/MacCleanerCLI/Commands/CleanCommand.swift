import ArgumentParser
import Foundation
import MacCleanerCore

public struct CleanCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "执行磁盘清理"
    )

    @Flag(name: .long, help: "清理开发者缓存")
    var devCaches: Bool = false

    @Flag(name: .long, help: "清理 iOS 模拟器")
    var simulators: Bool = false

    @Flag(name: .long, help: "清理 Xcode 缓存")
    var xcode: Bool = false

    @Flag(name: .long, help: "清理 AI 工具缓存")
    var aiCaches: Bool = false

    @Flag(name: .long, help: "清理应用缓存")
    var appCaches: Bool = false

    @Flag(name: .long, help: "扫描并清理所有候选（执行前仍需确认）")
    var all: Bool = false

    @Option(name: .long, help: "使用清理方案（开发环境瘦身/发版前清理/日志清理）")
    var profile: String?

    @Flag(name: .long, help: "列出所有可用清理方案")
    var listProfiles: Bool = false

    @Flag(name: .long, help: "跳过确认提示")
    var yes: Bool = false

    @Flag(name: .long, help: "预览模式，不实际删除")
    var dryRun: Bool = false

    public init() {}

    public mutating func run() async throws {
        // 列出可用方案
        if listProfiles {
            printProfiles()
            return
        }

        // 使用清理方案
        if let profileName = profile {
            try await runWithProfile(named: profileName)
            return
        }

        let targetModules: [ModuleIdentifier]
        if all {
            targetModules = ModuleIdentifier.allCases
        } else {
            var ids: [ModuleIdentifier] = []
            if devCaches { ids.append(.developerCaches) }
            if simulators { ids.append(.iosSimulators) }
            if xcode { ids.append(.xcode) }
            if aiCaches { ids.append(.aiToolCaches) }
            if appCaches { ids.append(.applicationCaches) }

            // 不再默认扫描并清理所有模块：必须显式指定
            guard !ids.isEmpty else {
                throw ValidationError("请指定模块或 --all")
            }
            targetModules = ids
        }

        let modules = ModuleRegistry.modules(for: targetModules).filter { $0.isAvailable() }

        print("\(ANSIStyle.bold)🔍 扫描中...\(ANSIStyle.reset)\n")

        // 统一扫描入口：共享 ScanContext，模块级有界并发
        let coordinator = ScanCoordinator(modules: modules)
        let scanned = try await coordinator.scan()

        var allItems: [CleanableItem] = []
        let filter = ScanResultFilter(exclusionManager: ExclusionManager.shared)
        for result in scanned {
            let filtered = await filter.apply(to: result)
            // 全部过滤后候选进入确认列表，CLI 不做任何推荐筛选
            allItems.append(contentsOf: filtered.items)
            print("  扫描 \(filtered.module.displayName)... \(ANSIStyle.green)✔\(ANSIStyle.reset) \(filtered.items.count) 项候选")
        }

        if allItems.isEmpty {
            print("\n\(ANSIStyle.green)✨ 没有需要清理的项目\(ANSIStyle.reset)")
            return
        }

        let shouldProceed = yes || ConfirmationPrompt.showSummaryAndConfirm(items: allItems, dryRun: dryRun)
        guard shouldProceed else {
            print("\n已取消")
            return
        }

        print("\n\(ANSIStyle.bold)🧹 开始清理...\(ANSIStyle.reset)\n")

        var totalFreed: Int64 = 0
        var totalSuccess = 0
        var totalFailed = 0

        // Group items by module
        var grouped: [ModuleIdentifier: [CleanableItem]] = [:]
        for item in allItems {
            grouped[item.category, default: []].append(item)
        }

        for module in modules {
            guard let items = grouped[module.identifier], !items.isEmpty else { continue }
            print("  清理 \(module.displayName)...", terminator: "")
            fflush(stdout)
            let report = try await module.clean(items: items, dryRun: dryRun)
            totalFreed += report.totalFreed
            totalSuccess += report.successCount
            totalFailed += report.failureCount

            if report.failureCount > 0 {
                print(" \(ANSIStyle.yellow)⚠\(ANSIStyle.reset) \(report.successCount) 成功, \(report.failureCount) 失败")
            } else {
                print(" \(ANSIStyle.green)✔\(ANSIStyle.reset)")
            }
        }

        print("")
        if dryRun {
            print("\(ANSIStyle.yellow)⚠ 试运行模式 — 以上操作未实际执行\(ANSIStyle.reset)")
            print("预计可回收: \(ANSIStyle.coloredSize(totalFreed))")
        } else {
            print("\(ANSIStyle.green)✨ 清理完成\(ANSIStyle.reset)")
            print("已回收: \(ANSIStyle.coloredSize(totalFreed))  成功: \(totalSuccess)  失败: \(totalFailed)")
        }
    }

    // MARK: - 清理方案

    private func printProfiles() {
        print("\(ANSIStyle.bold)可用清理方案:\(ANSIStyle.reset)\n")
        for p in CleaningProfile.builtInProfiles {
            let modules = p.moduleIDs?.joined(separator: ", ") ?? "所有模块"
            print("  \(ANSIStyle.bold)\(p.name)\(ANSIStyle.reset)")
            print("    \(p.description)")
            print("    模块: \(modules)")
            print("")
        }
        print("使用方式: mac-cleaner clean --profile \"方案名称\"")
    }

    private mutating func runWithProfile(named name: String) async throws {
        let allProfiles = CleaningProfile.builtInProfiles
        guard let selectedProfile = allProfiles.first(where: { $0.name == name }) else {
            print("\(ANSIStyle.red)✘ 未找到方案「\(name)」\(ANSIStyle.reset)")
            print("可用方案: \(allProfiles.map(\.name).joined(separator: "、"))")
            return
        }

        print("\(ANSIStyle.bold)📋 使用方案: \(selectedProfile.name)\(ANSIStyle.reset)")
        print("  \(selectedProfile.description)\n")

        let targetModules = selectedProfile.filterModules(ModuleIdentifier.allCases)
        let modules = ModuleRegistry.modules(for: targetModules).filter { $0.isAvailable() }

        print("\(ANSIStyle.bold)🔍 扫描中...\(ANSIStyle.reset)\n")

        // 统一扫描入口：共享 ScanContext，模块级有界并发
        let coordinator = ScanCoordinator(modules: modules)
        let scanned = try await coordinator.scan()

        var allItems: [CleanableItem] = []
        let filter = ScanResultFilter(exclusionManager: ExclusionManager.shared)
        for result in scanned {
            let filtered = await filter.apply(to: result)
            // 方案只筛选模块；全部过滤后候选进入确认列表
            allItems.append(contentsOf: filtered.items)
            print("  扫描 \(filtered.module.displayName)... \(ANSIStyle.green)✔\(ANSIStyle.reset) \(filtered.items.count) 项候选")
        }

        if allItems.isEmpty {
            print("\n\(ANSIStyle.green)✨ 没有需要清理的项目\(ANSIStyle.reset)")
            return
        }

        let shouldProceed = yes || ConfirmationPrompt.showSummaryAndConfirm(items: allItems, dryRun: dryRun)
        guard shouldProceed else {
            print("\n已取消")
            return
        }

        print("\n\(ANSIStyle.bold)🧹 开始清理...\(ANSIStyle.reset)\n")

        var totalFreed: Int64 = 0
        var totalSuccess = 0
        var totalFailed = 0

        var grouped: [ModuleIdentifier: [CleanableItem]] = [:]
        for item in allItems {
            grouped[item.category, default: []].append(item)
        }

        for module in modules {
            guard let items = grouped[module.identifier], !items.isEmpty else { continue }
            print("  清理 \(module.displayName)...", terminator: "")
            fflush(stdout)
            let report = try await module.clean(items: items, dryRun: dryRun)
            totalFreed += report.totalFreed
            totalSuccess += report.successCount
            totalFailed += report.failureCount

            if report.failureCount > 0 {
                print(" \(ANSIStyle.yellow)⚠\(ANSIStyle.reset) \(report.successCount) 成功, \(report.failureCount) 失败")
            } else {
                print(" \(ANSIStyle.green)✔\(ANSIStyle.reset)")
            }
        }

        print("")
        if dryRun {
            print("\(ANSIStyle.yellow)⚠ 试运行模式 — 以上操作未实际执行\(ANSIStyle.reset)")
            print("预计可回收: \(ANSIStyle.coloredSize(totalFreed))")
        } else {
            print("\(ANSIStyle.green)✨ 清理完成\(ANSIStyle.reset)")
            print("已回收: \(ANSIStyle.coloredSize(totalFreed))  成功: \(totalSuccess)  失败: \(totalFailed)")
        }
    }
}
