import Foundation

/// 单个模块扫描完成的进度快照。
public struct ScanModuleOutcome: Sendable {
    public let module: ModuleIdentifier
    /// 成功时为扫描结果；失败（非取消）时为 nil。
    public let result: ScanResult?
    /// 模块失败时的错误；成功或取消时为 nil。
    public let error: (any Error)?
    public let completedCount: Int
    public let totalCount: Int

    public init(
        module: ModuleIdentifier,
        result: ScanResult?,
        error: (any Error)?,
        completedCount: Int,
        totalCount: Int
    ) {
        self.module = module
        self.result = result
        self.error = error
        self.completedCount = completedCount
        self.totalCount = totalCount
    }
}

/// 统一扫描编排入口：一次扫描创建一个共享 ScanContext，
/// 以模块级有界并发运行所有模块，结果按输入模块顺序返回。
///
/// 模块失败（非取消）被跳过；整体取消时抛出 `CancellationError`，
/// 并停止调度新的模块和文件任务。
public struct ScanCoordinator: Sendable {
    public let modules: [any CleanerModule]
    public let maxConcurrentModules: Int
    public let maxConcurrentFileTasks: Int
    public let maxConcurrentHashTasks: Int
    private let progressHandler: (@Sendable (ScanModuleOutcome) -> Void)?

    public init(
        modules: [any CleanerModule],
        maxConcurrentModules: Int = 4,
        maxConcurrentFileTasks: Int = ScanContext.defaultFileTaskLimit,
        maxConcurrentHashTasks: Int = ScanContext.defaultHashTaskLimit,
        onModuleFinished: (@Sendable (ScanModuleOutcome) -> Void)? = nil
    ) {
        self.modules = modules
        self.maxConcurrentModules = max(1, maxConcurrentModules)
        self.maxConcurrentFileTasks = maxConcurrentFileTasks
        self.maxConcurrentHashTasks = maxConcurrentHashTasks
        self.progressHandler = onModuleFinished
    }

    /// 运行一次扫描。返回成功模块的结果，顺序与输入模块一致。
    public func scan() async throws -> [ScanResult] {
        try Task.checkCancellation()

        let context = ScanContext(
            fileTaskLimit: maxConcurrentFileTasks,
            hashTaskLimit: maxConcurrentHashTasks
        )
        let moduleLimiter = AsyncLimiter(limit: maxConcurrentModules)
        let counter = CompletionCounter()
        let total = modules.count

        return try await withThrowingTaskGroup(
            of: (index: Int, outcome: ScanModuleOutcome).self
        ) { group in
            for (index, module) in modules.enumerated() {
                group.addTask {
                    let outcome: ScanModuleOutcome
                    do {
                        let result = try await moduleLimiter.withPermit {
                            try await module.scan(context: context)
                        }
                        let completed = await counter.increment()
                        outcome = ScanModuleOutcome(
                            module: module.identifier,
                            result: result,
                            error: nil,
                            completedCount: completed,
                            totalCount: total
                        )
                    } catch is CancellationError {
                        // 取消属于整体行为：向上传播以停止调度新模块。
                        throw CancellationError()
                    } catch {
                        let completed = await counter.increment()
                        outcome = ScanModuleOutcome(
                            module: module.identifier,
                            result: nil,
                            error: error,
                            completedCount: completed,
                            totalCount: total
                        )
                    }
                    return (index, outcome)
                }
            }

            var collected: [(index: Int, result: ScanResult)] = []
            for try await (index, outcome) in group {
                progressHandler?(outcome)
                if let result = outcome.result {
                    collected.append((index, result))
                }
            }
            let ordered = collected.sorted { $0.index < $1.index }.map(\.result)
            return Self.mergedResults(from: ordered)
        }
    }

    /// 合并跨模块重复候选（同路径、目录覆盖），并按主 category 重建模块结果。
    /// 每个 unique item 只出现在主 category 的 ScanResult 中；
    /// sourceModules 保留全部发现来源。总大小由 unique items 汇总，
    /// 不再对原始模块 result 求和。
    static func mergedResults(from results: [ScanResult]) -> [ScanResult] {
        let allItems = results.flatMap(\.items)
        guard !allItems.isEmpty else { return results }

        let merged = CandidateMerger().merge(allItems)
        var grouped: [ModuleIdentifier: [CleanableItem]] = [:]
        for item in merged {
            grouped[item.category, default: []].append(item)
        }

        return results.map { result in
            ScanResult(
                module: result.module,
                items: grouped[result.module] ?? [],
                scanDuration: result.scanDuration
            )
        }
    }
}

private actor CompletionCounter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
