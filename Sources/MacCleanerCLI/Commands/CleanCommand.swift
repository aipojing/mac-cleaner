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

    @Flag(name: .long, help: "清理主目录大文件（用户数据，只能显式指定，--all 不包含）")
    var largeFiles: Bool = false

    @Flag(name: .long, help: "扫描并清理所有候选（不含大文件等用户数据模块；执行前仍需确认）")
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

    /// --all 与"所有模块"方案的默认范围：排除大文件等用户数据模块。
    /// 大文件只能由用户通过 --large-files 显式指定。
    /// （重复文件模块未在 CLI 注册表中，天然不会被解析到。）
    static let defaultCleanModules: [ModuleIdentifier] =
        ModuleIdentifier.allCases.filter { $0 != .largeFiles }

    public func validate() throws {
        let explicitFlags = [devCaches, simulators, xcode, aiCaches, appCaches, largeFiles]
            .contains(true)

        if listProfiles, explicitFlags || all || profile != nil || yes || dryRun {
            throw ValidationError("--list-profiles 不能与其它选项同时使用")
        }
        if all, explicitFlags {
            throw ValidationError("--all 不能与单模块 flag 同时使用（大文件请单独使用 --large-files）")
        }
        if all, profile != nil {
            throw ValidationError("--all 不能与 --profile 同时使用")
        }
        if profile != nil, explicitFlags {
            throw ValidationError("--profile 不能与单模块 flag 同时使用")
        }
    }

    public mutating func run() async throws {
        // 列出可用方案
        if listProfiles {
            printProfiles()
            return
        }

        // 使用清理方案
        if let profileName = profile {
            let allProfiles = CleaningProfile.builtInProfiles
            guard let selectedProfile = allProfiles.first(where: { $0.name == profileName }) else {
                throw ValidationError(
                    "未找到方案「\(profileName)」。可用方案: \(allProfiles.map(\.name).joined(separator: "、"))"
                )
            }

            // 方案里出现未识别的模块名时明确报错，而不是静默丢弃
            let knownIDs = Set(ModuleIdentifier.allCases.map(\.rawValue))
            let unknownIDs = (selectedProfile.moduleIDs ?? []).filter { !knownIDs.contains($0) }
            guard unknownIDs.isEmpty else {
                throw ValidationError(
                    "方案「\(profileName)」包含未识别的模块: \(unknownIDs.joined(separator: ", "))"
                )
            }

            print("\(ANSIStyle.bold)📋 使用方案: \(selectedProfile.name)\(ANSIStyle.reset)")
            print("  \(selectedProfile.description)\n")

            // "所有模块"的方案同样排除大文件等用户数据模块
            let targetModules = selectedProfile.filterModules(Self.defaultCleanModules)
            try await runCleaning(targetModules: targetModules)
            return
        }

        let targetModules: [ModuleIdentifier]
        if all {
            targetModules = Self.defaultCleanModules
        } else {
            var ids: [ModuleIdentifier] = []
            if devCaches { ids.append(.developerCaches) }
            if simulators { ids.append(.iosSimulators) }
            if xcode { ids.append(.xcode) }
            if aiCaches { ids.append(.aiToolCaches) }
            if appCaches { ids.append(.applicationCaches) }
            if largeFiles { ids.append(.largeFiles) }

            // 不再默认扫描并清理所有模块：必须显式指定
            guard !ids.isEmpty else {
                throw ValidationError("请指定模块或 --all")
            }
            targetModules = ids
        }

        try await runCleaning(targetModules: targetModules)
    }

    // MARK: - 共享编排

    /// 扫描 → 排除过滤 → 确认 → 逐模块清理 → 汇总的统一流程。
    /// 单模块清理抛错不中断批次：记录失败并继续，最终以非零退出码结束。
    private mutating func runCleaning(targetModules: [ModuleIdentifier]) async throws {
        let modules = ModuleRegistry.modules(for: targetModules).filter { $0.isAvailable() }
        guard !modules.isEmpty else {
            print("没有可用的清理模块")
            return
        }

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
        var failedModules: [(name: String, error: String)] = []

        // Group items by module
        var grouped: [ModuleIdentifier: [CleanableItem]] = [:]
        for item in allItems {
            grouped[item.category, default: []].append(item)
        }

        for module in modules {
            guard let items = grouped[module.identifier], !items.isEmpty else { continue }
            print("  清理 \(module.displayName)...", terminator: "")
            fflush(stdout)
            do {
                let report = try await module.clean(items: items, dryRun: dryRun)
                totalFreed += report.totalFreed
                totalSuccess += report.successCount
                totalFailed += report.failureCount

                if report.failureCount > 0 {
                    print(" \(ANSIStyle.yellow)⚠\(ANSIStyle.reset) \(report.successCount) 成功, \(report.failureCount) 失败")
                } else {
                    print(" \(ANSIStyle.green)✔\(ANSIStyle.reset)")
                }
            } catch {
                // 单模块失败不中断批次：记录后继续后续模块
                failedModules.append((name: module.displayName, error: error.localizedDescription))
                print(" \(ANSIStyle.red)✘ 失败: \(error.localizedDescription)\(ANSIStyle.reset)")
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

        if !failedModules.isEmpty {
            print("\n\(ANSIStyle.red)以下模块清理失败:\(ANSIStyle.reset)")
            for failure in failedModules {
                print("  \(ANSIStyle.red)✘\(ANSIStyle.reset) \(failure.name): \(failure.error)")
            }
            throw ExitCode.failure
        }
    }

    // MARK: - 清理方案

    private func printProfiles() {
        print("\(ANSIStyle.bold)可用清理方案:\(ANSIStyle.reset)\n")
        for p in CleaningProfile.builtInProfiles {
            let modules = p.moduleIDs?.joined(separator: ", ") ?? "所有模块（不含大文件）"
            print("  \(ANSIStyle.bold)\(p.name)\(ANSIStyle.reset)")
            print("    \(p.description)")
            print("    模块: \(modules)")
            print("")
        }
        print("使用方式: mac-cleaner clean --profile \"方案名称\"")
    }
}
