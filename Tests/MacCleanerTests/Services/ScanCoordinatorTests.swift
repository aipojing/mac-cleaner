import Testing
import Foundation
@testable import MacCleanerCore

/// 记录收到的 ScanContext 的测试模块。
actor ContextRecorder {
    private(set) var metadataIndexIDs: Set<ObjectIdentifier> = []

    func record(context: ScanContext) {
        metadataIndexIDs.insert(ObjectIdentifier(context.metadataIndex))
    }

    var uniqueMetadataIndexCount: Int { metadataIndexIDs.count }
}

struct ContextRecordingModule: CleanerModule {
    let identifier: ModuleIdentifier
    let displayName = "Context Recording"
    let description = "fixture"
    let recorder: ContextRecorder

    func isAvailable() -> Bool { true }

    func scan(context: ScanContext) async throws -> ScanResult {
        await recorder.record(context: context)
        return ScanResult(module: identifier, items: [], scanDuration: 0)
    }

    func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        CleanupReport(module: identifier)
    }

    static func fixture(count: Int) -> (modules: [any CleanerModule], recorder: ContextRecorder) {
        let recorder = ContextRecorder()
        let ids: [ModuleIdentifier] = [.developerCaches, .xcode, .docker, .systemLogs, .aiToolCaches]
        let modules = ids.prefix(count).map {
            ContextRecordingModule(identifier: $0, recorder: recorder) as any CleanerModule
        }
        return (Array(modules), recorder)
    }
}

/// 每个文件任务都会记录并耗时的模块：用于验证取消后不启动新任务。
actor BlockingScanModule: CleanerModule {
    let itemCount: Int
    private(set) var startedCount = 0
    private var startedContinuations: [(Int, CheckedContinuation<Void, Never>)] = []

    init(itemCount: Int = 100) {
        self.itemCount = itemCount
    }

    nonisolated var identifier: ModuleIdentifier { .largeFiles }
    nonisolated var displayName: String { "Blocking" }
    nonisolated var description: String { "fixture" }

    nonisolated func isAvailable() -> Bool { true }

    func waitUntilStarted(count: Int) async {
        if startedCount >= count { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append((count, continuation))
        }
    }

    func scan(context: ScanContext) async throws -> ScanResult {
        for _ in 0..<itemCount {
            try await context.fileTaskLimiter.withPermit {
                await self.markStarted()
            }
        }
        return ScanResult(module: .largeFiles, items: [], scanDuration: 0)
    }

    nonisolated func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        CleanupReport(module: .largeFiles)
    }

    private func markStarted() async {
        startedCount += 1
        let ready = startedContinuations.filter { $0.0 <= startedCount }
        startedContinuations.removeAll { $0.0 <= startedCount }
        for (_, continuation) in ready { continuation.resume() }
        // 模拟文件任务耗时
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// 立即失败的模块：coordinator 应跳过并继续其他模块。
struct FailingModule: CleanerModule {
    let identifier: ModuleIdentifier = .docker
    let displayName = "Failing"
    let description = "fixture"
    struct ScanFailure: Error {}

    func isAvailable() -> Bool { true }
    func scan(context: ScanContext) async throws -> ScanResult { throw ScanFailure() }
    func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        CleanupReport(module: identifier)
    }
}

/// 在 scan 中记录并发的模块。
struct ConcurrentProbeModule: CleanerModule {
    let identifier: ModuleIdentifier
    let displayName = "Probe"
    let description = "fixture"
    let probe: ConcurrencyProbe

    func isAvailable() -> Bool { true }
    func scan(context: ScanContext) async throws -> ScanResult {
        await probe.recordWork()
        return ScanResult(module: identifier, items: [], scanDuration: 0)
    }
    func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        CleanupReport(module: identifier)
    }
}

@Suite("Scan coordinator")
struct ScanCoordinatorTests {
    @Test("所有模块共享 metadata index")
    func sharesOneContext() async throws {
        let (modules, recorder) = ContextRecordingModule.fixture(count: 3)
        let coordinator = ScanCoordinator(modules: modules, maxConcurrentFileTasks: 2)
        _ = try await coordinator.scan()
        #expect(await recorder.uniqueMetadataIndexCount == 1)
    }

    @Test("取消后不启动新的文件任务")
    func cancellationStopsScheduling() async {
        let module = BlockingScanModule(itemCount: 100)
        let task = Task {
            try await ScanCoordinator(modules: [module]).scan()
        }
        await module.waitUntilStarted(count: 4)
        task.cancel()
        _ = try? await task.value
        #expect(await module.startedCount < 100)
    }

    @Test("模块失败被跳过，结果保持输入顺序")
    func skipsFailingModulesAndKeepsOrder() async throws {
        let (modules, _) = ContextRecordingModule.fixture(count: 3)
        // 在中间插入一个失败模块
        let all: [any CleanerModule] = [modules[0], FailingModule(), modules[1], modules[2]]
        let coordinator = ScanCoordinator(modules: all)
        let results = try await coordinator.scan()
        #expect(results.map(\.module) == [.developerCaches, .xcode, .docker])
    }

    @Test("模块级并发不超过设置值")
    func limitsModuleConcurrency() async throws {
        let probe = ConcurrencyProbe()
        let modules = (0..<8).map { _ in
            ConcurrentProbeModule(identifier: .xcode, probe: probe) as any CleanerModule
        }
        let coordinator = ScanCoordinator(modules: modules, maxConcurrentModules: 2)
        _ = try await coordinator.scan()
        #expect(await probe.maximumConcurrent == 2)
    }

    @Test("跨模块重复路径在输出前合并到主 category")
    func mergesDuplicatePathsBeforeOutput() async throws {
        let devModule = FixtureCleanerModule(
            identifier: .developerCaches,
            items: [CleanableItem(
                path: "/tmp/shared-cache", displayName: "npm 缓存", size: 1_000,
                category: .developerCaches, evidenceTags: ["npm"]
            )]
        )
        let largeModule = FixtureCleanerModule(
            identifier: .largeFiles,
            items: [CleanableItem(
                path: "/tmp/shared-cache", displayName: "tmp/shared-cache", size: 1_000,
                category: .largeFiles, evidenceTags: ["large-file"]
            )]
        )
        let coordinator = ScanCoordinator(modules: [devModule, largeModule])
        let results = try await coordinator.scan()

        let devResult = results.first { $0.module == .developerCaches }
        let largeResult = results.first { $0.module == .largeFiles }
        #expect(devResult?.items.count == 1)
        #expect(largeResult?.items.isEmpty == true)
        #expect(devResult?.items.first?.sourceModules == [.developerCaches, .largeFiles])
        // 总大小来自 unique items，不重复计数
        let total = results.reduce(Int64(0)) { $0 + $1.totalSize }
        #expect(total == 1_000)
    }
}
