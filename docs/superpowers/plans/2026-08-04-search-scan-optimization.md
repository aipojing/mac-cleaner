# MacCleaner Search and Scan Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让一次扫描共享元数据、按实际占用统计、限制并发、消除硬链接与跨模块重复，并用带权搜索与筛选快速找到真正可处理的结果。

**Architecture:** `ScanCoordinator` 为一次扫描创建共享 `ScanContext`，所有模块通过同一个 metadata index 和 concurrency limiter 访问文件系统；结果在 coordinator 中按规范化路径和 device/inode 合并。搜索先构建规范化文档，再用纯函数 ranker 对事实和可选 AI 文本评分，搜索本身不触发 AI。

**Tech Stack:** Swift 5.9、Swift Concurrency、Foundation、Darwin、CryptoKit、SwiftUI、Swift Testing、Swift Package release benchmark。

**Design:** `docs/superpowers/specs/2026-08-04-ai-assessment-and-search-design.md`

## Global Constraints

- 开始本计划前必须完成安全基线、AI Core 和 App AI 迁移三份计划。
- 目录与文件大小默认显示磁盘实际占用 `st_blocks * 512`；逻辑大小仍保留在详情中。
- 符号链接只统计链接对象自身，不跟随到目标；同一 device/inode 的硬链接物理空间只计一次。
- 文件系统任务默认并发上限为 `min(max(activeProcessorCount, 2), 8)`，hash 并发上限为 4。
- 搜索、排序、筛选和列表滚动不得调用 DeepSeek；只读取内存中的事实和已有 `AIAssessmentState`。
- 搜索结果排序不能改变选择状态；扫描重排不能把新结果自动选中。
- 第一期只优化单次扫描，不引入 FSEvents 常驻索引或后台监视目录。
- 每个提交只包含该任务列出的文件；仓库中已有未提交修改不纳入提交。

## Acceptance Metrics

- 同一路径在单次扫描中最多执行一次 `lstat`。
- 同一物理对象跨模块、跨路径硬链接只计一次 allocated bytes。
- 任意时刻 metadata worker 不超过 8，full-hash worker 不超过 4。
- Top-N 大文件扫描的常驻候选数量不超过 N，复杂度为 `O(fileCount × log N)`。
- 10,000 条合成文档、20 次查询的 release benchmark p95 不超过 100 ms；结果必须稳定且不访问网络。
- 缓存未变化的重复文件第二次扫描不计算 full hash；size、mtime、device 或 inode 变化后必须重新计算。

## File Structure Map

```text
Package.swift                                      # 增加 benchmark executable
Benchmarks/MacCleanerBenchmarks/main.swift         # 搜索性能门槛
Sources/MacCleanerCore/
├── Models/
│   ├── CleanableItem.swift                       # sourceModules 与实际占用
│   ├── FileMetadata.swift                        # 单次扫描元数据
│   ├── ScanContext.swift                         # 共享上下文
│   └── SearchDocument.swift                      # 预规范化搜索文档
├── Protocols/
│   └── CleanerModule.swift                       # scan(context:)
├── Services/
│   ├── AsyncLimiter.swift                        # actor 并发许可
│   ├── CandidateMerger.swift                     # 路径/inode 合并
│   ├── FileHashCache.swift                       # 持久化 hash 缓存
│   ├── FileMetadataIndex.swift                   # actor 单次快照
│   ├── PhysicalSizeCalculator.swift              # 硬链接感知统计
│   ├── POSIXFileMetadataProvider.swift           # lstat/st_blocks
│   ├── ResultSearchEngine.swift                  # 权重、筛选、排序
│   ├── ScanCoordinator.swift                     # 全入口扫描编排
│   └── TopNHeap.swift                            # 大文件最小堆
├── Modules/
│   ├── DuplicateFilesModule.swift
│   └── LargeFileScannerModule.swift
├── Services/DiskScanner.swift
Sources/MacCleanerApp/Features/
├── ActivityMonitor/ActivityMonitorViewModel.swift
├── ActivityMonitor/ActivityMonitorView.swift
├── Results/ResultsViewModel.swift
└── Results/ResultsView.swift
Sources/MacCleanerCLI/Commands/
├── CleanCommand.swift
└── ScanCommand.swift
Tests/MacCleanerTests/
├── Models/FileMetadataTests.swift
└── Services/
    ├── AsyncLimiterTests.swift
    ├── CandidateMergerTests.swift
    ├── FileHashCacheTests.swift
    ├── FileMetadataIndexTests.swift
    ├── ResultSearchEngineTests.swift
    ├── ScanCoordinatorTests.swift
    └── TopNHeapTests.swift
Tests/MacCleanerAppTests/
├── ActivityMonitorSearchViewModelTests.swift
└── ResultsSearchViewModelTests.swift
```

---

### Task 1: 用 lstat 建立共享文件元数据快照

**Files:**
- Create: `Sources/MacCleanerCore/Models/FileMetadata.swift`
- Create: `Sources/MacCleanerCore/Services/POSIXFileMetadataProvider.swift`
- Create: `Sources/MacCleanerCore/Services/FileMetadataIndex.swift`
- Modify: `Sources/MacCleanerCore/Services/DiskScanner.swift`
- Create: `Tests/MacCleanerTests/Models/FileMetadataTests.swift`
- Create: `Tests/MacCleanerTests/Services/FileMetadataIndexTests.swift`

- [ ] **Step 1: 写出 allocated size、符号链接和缓存测试**

```swift
@Suite("File metadata")
struct FileMetadataTests {
    @Test("实际占用来自 st_blocks 而不是 st_size")
    func usesAllocatedBlocks() {
        let metadata = FileMetadata.fromStat(
            path: "/tmp/sparse",
            device: 1,
            inode: 2,
            mode: regularFileMode,
            logicalSize: 1_000_000,
            blocks: 8,
            linkCount: 1,
            modificationTimeNanoseconds: 100
        )
        #expect(metadata.logicalSize == 1_000_000)
        #expect(metadata.allocatedSize == 4_096)
    }

    @Test("符号链接保持自身类型且不跟随目标")
    func preservesSymlinkIdentity() throws {
        let fixture = try SymlinkFixture.make()
        let metadata = try POSIXFileMetadataProvider().metadata(at: fixture.link.path)
        #expect(metadata.kind == .symbolicLink)
        #expect(metadata.identity.inode != fixture.targetIdentity.inode)
    }
}

@Test("单次扫描同一路径只调用 provider 一次")
func metadataIndexCoalescesRequests() async throws {
    let provider = CountingMetadataProvider(result: .fixture())
    let index = FileMetadataIndex(provider: provider)
    async let first = index.metadata(at: "/tmp/a")
    async let second = index.metadata(at: "/tmp/a")
    _ = try await (first, second)
    #expect(await provider.callCount(for: "/tmp/a") == 1)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter 'FileMetadataTests|FileMetadataIndexTests'`

Expected: 编译失败，提示 metadata 类型不存在。

- [ ] **Step 3: 定义不可变元数据**

```swift
public struct FileMetadata: Hashable, Sendable {
    public let path: String
    public let identity: FileIdentity
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let linkCount: UInt64
    public let modificationTimeNanoseconds: Int64
}
```

`POSIXFileMetadataProvider` 使用 `lstat`，allocated size 计算为 `max(0, st_blocks) * 512`。常规文件、目录、符号链接和 other 映射到 `FileObjectKind`；不调用 `stat` 跟随链接。路径先标准化 `.`、`..` 和重复 `/`，但不解析最终 symlink。

目录自身的 `st_blocks` 只代表目录记录，不代表后代。`DiskScanner` 计算目录候选时枚举后代并用 `(device, inode)` 集合累加每个对象的 logical/allocated size；符号链接只累加链接自身，硬链接只累加一次。

- [ ] **Step 4: 实现 actor 去重请求**

```swift
public actor FileMetadataIndex {
    private var values: [String: Result<FileMetadata, MetadataError>] = [:]
    private var inFlight: [String: Task<FileMetadata, Error>] = [:]

    public func metadata(at path: String) async throws -> FileMetadata
    public func cachedMetadata(at path: String) -> FileMetadata?
}
```

相同规范化路径并发请求共享一个 task；成功和确定性错误均在本次 scan context 内缓存。取消错误不缓存，避免一个调用者取消污染后续请求。

- [ ] **Step 5: 让 DiskScanner 使用 metadata index**

移除基于 URL resource values 或 `st_size` 的重复大小读取；枚举器发现路径后只通过注入的 `FileMetadataIndex` 获取逻辑大小、实际占用、对象类型和身份。

- [ ] **Step 6: 验证并提交**

Run: `swift test --filter 'FileMetadataTests|FileMetadataIndexTests'`

Expected: 全部通过。

```bash
git add Sources/MacCleanerCore/Models/FileMetadata.swift \
  Sources/MacCleanerCore/Services/POSIXFileMetadataProvider.swift \
  Sources/MacCleanerCore/Services/FileMetadataIndex.swift \
  Sources/MacCleanerCore/Services/DiskScanner.swift \
  Tests/MacCleanerTests/Models/FileMetadataTests.swift \
  Tests/MacCleanerTests/Services/FileMetadataIndexTests.swift
git commit -m "Core: share allocated file metadata per scan"
```

### Task 2: 建立有界并发的统一 ScanCoordinator

**Files:**
- Create: `Sources/MacCleanerCore/Models/ScanContext.swift`
- Create: `Sources/MacCleanerCore/Services/AsyncLimiter.swift`
- Create: `Sources/MacCleanerCore/Services/ScanCoordinator.swift`
- Modify: `Sources/MacCleanerCore/Protocols/CleanerModule.swift`
- Modify: `Sources/MacCleanerCore/Commands/ModuleRegistry.swift`
- Modify: `Sources/MacCleanerCore/Modules/AIToolCachesModule.swift`
- Modify: `Sources/MacCleanerCore/Modules/AndroidSDKModule.swift`
- Modify: `Sources/MacCleanerCore/Modules/ApplicationCachesModule.swift`
- Modify: `Sources/MacCleanerCore/Modules/DeveloperCachesModule.swift`
- Modify: `Sources/MacCleanerCore/Modules/DockerModule.swift`
- Modify: `Sources/MacCleanerCore/Modules/DuplicateFilesModule.swift`
- Modify: `Sources/MacCleanerCore/Modules/IOSSimulatorsModule.swift`
- Modify: `Sources/MacCleanerCore/Modules/LargeFileScannerModule.swift`
- Modify: `Sources/MacCleanerCore/Modules/SystemLogsModule.swift`
- Modify: `Sources/MacCleanerCore/Modules/XcodeModule.swift`
- Modify: `Sources/MacCleanerApp/Features/Scan/ScanViewModel.swift`
- Modify: `Sources/MacCleanerCLI/Commands/ScanCommand.swift`
- Modify: `Sources/MacCleanerCLI/Commands/CleanCommand.swift`
- Modify: `Sources/MacCleanerCore/Services/ScheduledScanService.swift`
- Create: `Tests/MacCleanerTests/Services/AsyncLimiterTests.swift`
- Create: `Tests/MacCleanerTests/Services/ScanCoordinatorTests.swift`

- [ ] **Step 1: 写出并发上限、共享 context 和取消测试**

```swift
@Suite("Scan coordinator")
struct ScanCoordinatorTests {
    @Test("所有模块共享 metadata index")
    func sharesOneContext() async throws {
        let recorder = ContextRecordingModule.fixture(count: 3)
        let coordinator = ScanCoordinator(modules: recorder.modules, maxConcurrentFileTasks: 2)
        _ = try await coordinator.scan()
        #expect(await recorder.uniqueMetadataIndexCount == 1)
    }

    @Test("文件任务不会超过设置的并发数")
    func limitsConcurrency() async throws {
        let probe = ConcurrencyProbe()
        let limiter = AsyncLimiter(limit: 3)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await limiter.withPermit { await probe.recordWork() }
                }
            }
        }
        #expect(await probe.maximumConcurrent == 3)
    }

    @Test("取消后不启动新的文件任务")
    func cancellationStopsScheduling() async {
        let module = BlockingScanModule(itemCount: 100)
        let task = Task { try await ScanCoordinator(modules: [module]).scan() }
        await module.waitUntilStarted(count: 4)
        task.cancel()
        _ = try? await task.value
        #expect(await module.startedCount < 100)
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter 'AsyncLimiterTests|ScanCoordinatorTests'`

Expected: 编译失败，提示 limiter/coordinator/context 不存在。

- [ ] **Step 3: 定义共享上下文和协议**

```swift
public struct ScanContext: Sendable {
    public let metadataIndex: FileMetadataIndex
    public let fileTaskLimiter: AsyncLimiter
    public let hashTaskLimiter: AsyncLimiter
}

public protocol CleanerModule: Sendable {
    var identifier: ModuleIdentifier { get }
    var displayName: String { get }
    var description: String { get }
    func isAvailable() -> Bool
    func scan(context: ScanContext) async throws -> ScanResult
    func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport
}
```

`AsyncLimiter.withPermit` 用 continuation 等待许可，并在 body 完成、抛错或取消时归还。默认 file limit 为 `min(max(activeProcessorCount, 2), 8)`，hash limit 为 4。

- [ ] **Step 4: 迁移所有模块与入口**

所有模块删除内部无界 `TaskGroup`，通过 `context.fileTaskLimiter` 调度 metadata 工作；full hash 使用 `hashTaskLimiter`。`ScanCoordinator` 创建一次 context，并以模块级最大并发 4 扫描。App、CLI 和 `ScheduledScanService` 只调用 coordinator，再调用 P0 `ScanResultFilter`。

- [ ] **Step 5: 验证并提交**

Run: `swift test --filter 'AsyncLimiterTests|ScanCoordinatorTests|ModuleTests|ScheduledScanTests'`

Expected: 全部通过；probe 的 file 最大值不超过设置，hash 最大值不超过 4。

```bash
git add Sources/MacCleanerCore/Models/ScanContext.swift \
  Sources/MacCleanerCore/Services/AsyncLimiter.swift \
  Sources/MacCleanerCore/Services/ScanCoordinator.swift \
  Sources/MacCleanerCore/Protocols/CleanerModule.swift \
  Sources/MacCleanerCore/Commands/ModuleRegistry.swift \
  Sources/MacCleanerCore/Modules \
  Sources/MacCleanerCore/Services/ScheduledScanService.swift \
  Sources/MacCleanerApp/Features/Scan/ScanViewModel.swift \
  Sources/MacCleanerCLI/Commands/ScanCommand.swift \
  Sources/MacCleanerCLI/Commands/CleanCommand.swift \
  Tests/MacCleanerTests/Services/AsyncLimiterTests.swift \
  Tests/MacCleanerTests/Services/ScanCoordinatorTests.swift
git commit -m "Core: bound and coordinate filesystem scanning"
```

### Task 3: 合并跨模块路径、硬链接和重叠候选

**Files:**
- Modify: `Sources/MacCleanerCore/Models/CleanableItem.swift`
- Modify: `Sources/MacCleanerCore/Models/ScanResult.swift`
- Create: `Sources/MacCleanerCore/Services/CandidateMerger.swift`
- Create: `Sources/MacCleanerCore/Services/PhysicalSizeCalculator.swift`
- Modify: `Sources/MacCleanerCore/Services/ScanCoordinator.swift`
- Modify: `Sources/MacCleanerApp/Features/Results/ResultsViewModel.swift`
- Modify: `Sources/MacCleanerCLI/TUI/ConfirmationPrompt.swift`
- Create: `Tests/MacCleanerTests/Services/CandidateMergerTests.swift`
- Modify: `Tests/MacCleanerTests/Services/ScanCoordinatorTests.swift`

- [ ] **Step 1: 写出路径、inode 和目录覆盖测试**

```swift
@Suite("Candidate merger")
struct CandidateMergerTests {
    @Test("相同规范化路径合并 tags 和来源模块")
    func mergesSamePath() {
        let merged = CandidateMerger().merge([
            .fixture(path: "/tmp/cache/./a", module: .developerCaches, tags: ["npm"]),
            .fixture(path: "/tmp/cache/a", module: .largeFiles, tags: ["large-file"]),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].sourceModules == [.developerCaches, .largeFiles])
        #expect(Set(merged[0].evidenceTags) == ["npm", "large-file"])
    }

    @Test("不同路径的硬链接保留两个事实，但物理占用只计一次")
    func countsHardlinksOnceWithoutMergingPaths() {
        let merged = CandidateMerger().merge([
            .fixture(path: "/tmp/a", device: 1, inode: 10, allocatedSize: 4096),
            .fixture(path: "/tmp/b", device: 1, inode: 10, allocatedSize: 4096),
        ])
        #expect(merged.count == 2)
        #expect(PhysicalSizeCalculator.uniqueAllocatedBytes(in: merged) == 4096)
        #expect(PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: [merged[0]],
            allKnownItems: merged
        ) == 0)
        #expect(PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: merged,
            allKnownItems: merged
        ) == 4096)
    }

    @Test("父目录候选覆盖子项时只计父目录一次")
    func parentDirectoryOwnsDescendants() {
        let merged = CandidateMerger().merge([
            .fixture(path: "/tmp/cache", kind: .directory, allocatedSize: 10_000),
            .fixture(path: "/tmp/cache/a", kind: .regularFile, allocatedSize: 4_096),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].path == "/tmp/cache")
        #expect(merged[0].allocatedSize == 10_000)
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter CandidateMergerTests`

Expected: 编译失败，提示 merger/sourceModules/physical size calculator 不存在。

- [ ] **Step 3: 扩展事实模型并定义确定性主项**

`CleanableItem` 增加排序稳定的 `sourceModules: [ModuleIdentifier]` 和 `linkCount: UInt64`。主 category 按 `ModuleRegistry` 固定优先级选择，而不是按 task 完成顺序；display name 取主 category 的候选，tags 和来源模块合并排序。

- [ ] **Step 4: 实现两阶段合并**

第一阶段按规范化路径合并；第二阶段按路径组件边界消除已被目录候选完整覆盖的子项。不同路径即使 `(device, inode)` 相同也保留为不同可选项，避免选择一个路径时暗中删除另一个硬链接。符号链接不与目标 inode 合并。

`PhysicalSizeCalculator.uniqueAllocatedBytes` 按 `(device, inode)` 汇总物理占用；`estimatedReclaimableBytes` 只有在用户选择的已知路径数量达到 `linkCount` 时才计入该对象，否则为 0。`ResultsViewModel.totalSelectedSize`、Scan summary 和 CLI confirmation 都使用该 calculator，不再直接求和 item size。

目录候选在 Task 1 的递归累计阶段已对后代 identity 去重；同一路径或父子目录重叠由 merger 去重。不同目录之间存在交叉硬链接时，确认页将其标记为“实际释放取决于其他硬链接”，不把单个已选路径计入预计释放。

- [ ] **Step 5: 在 coordinator 输出前合并并重建模块结果**

每个 unique item 只出现在主 category 的 `ScanResult`；`sourceModules` 保留发现来源供筛选和 AI evidence 使用。总大小从 unique items 汇总，不能再对原始模块 result 求和。

- [ ] **Step 6: 验证并提交**

Run: `swift test --filter 'CandidateMergerTests|ScanCoordinatorTests'`

Expected: 全部通过。

```bash
git add Sources/MacCleanerCore/Models/CleanableItem.swift \
  Sources/MacCleanerCore/Models/ScanResult.swift \
  Sources/MacCleanerCore/Services/CandidateMerger.swift \
  Sources/MacCleanerCore/Services/PhysicalSizeCalculator.swift \
  Sources/MacCleanerCore/Services/ScanCoordinator.swift \
  Sources/MacCleanerApp/Features/Results/ResultsViewModel.swift \
  Sources/MacCleanerCLI/TUI/ConfirmationPrompt.swift \
  Tests/MacCleanerTests/Services/CandidateMergerTests.swift \
  Tests/MacCleanerTests/Services/ScanCoordinatorTests.swift
git commit -m "Core: deduplicate cleanup candidates and physical bytes"
```

### Task 4: 用固定容量最小堆扫描 Top-N 大文件

**Files:**
- Create: `Sources/MacCleanerCore/Services/TopNHeap.swift`
- Modify: `Sources/MacCleanerCore/Modules/LargeFileScannerModule.swift`
- Create: `Tests/MacCleanerTests/Services/TopNHeapTests.swift`
- Modify: `Tests/MacCleanerTests/Modules/ModuleSemanticTests.swift`

- [ ] **Step 1: 写出容量和稳定排序测试**

```swift
@Suite("Top N heap")
struct TopNHeapTests {
    @Test("始终只保留最大的 N 项")
    func keepsLargestValues() {
        var heap = TopNHeap<Int>(capacity: 3, score: { Int64($0) })
        [5, 1, 9, 3, 8, 2].forEach { heap.insert($0) }
        #expect(heap.count == 3)
        #expect(heap.sortedDescending() == [9, 8, 5])
        #expect(heap.maximumObservedCount == 3)
    }

    @Test("同大小按规范化路径排序保证稳定")
    func stableTieBreak() {
        var heap = TopNHeap<FileCandidate>(capacity: 2, score: \.allocatedSize, tieBreak: \.path)
        heap.insert(.fixture(path: "/b", allocatedSize: 10))
        heap.insert(.fixture(path: "/a", allocatedSize: 10))
        #expect(heap.sortedDescending().map(\.path) == ["/a", "/b"])
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter TopNHeapTests`

Expected: 编译失败，提示 heap 不存在。

- [ ] **Step 3: 实现通用最小堆**

实现 `insert`、`siftUp`、`siftDown`、`sortedDescending`；capacity 为 0 时丢弃全部输入。大文件模块枚举过程中立即把满足阈值的 metadata 放入 heap，不再把所有文件收集后全量排序。评分使用 allocated size，详情同时显示 logical size。

- [ ] **Step 4: 验证并提交**

Run: `swift test --filter 'TopNHeapTests|ModuleSemanticTests'`

Expected: heap 及大文件模块测试通过，观察到的常驻候选不超过配置 N。

```bash
git add Sources/MacCleanerCore/Services/TopNHeap.swift \
  Sources/MacCleanerCore/Modules/LargeFileScannerModule.swift \
  Tests/MacCleanerTests/Services/TopNHeapTests.swift \
  Tests/MacCleanerTests/Modules/ModuleSemanticTests.swift
git commit -m "Core: retain large files with a bounded heap"
```

### Task 5: 改进重复文件分桶、抽样和 hash 缓存

**Files:**
- Create: `Sources/MacCleanerCore/Services/FileHashCache.swift`
- Modify: `Sources/MacCleanerCore/Services/FileHasher.swift`
- Modify: `Sources/MacCleanerCore/Modules/DuplicateFilesModule.swift`
- Create: `Tests/MacCleanerTests/Services/FileHashCacheTests.swift`
- Modify: `Tests/MacCleanerTests/Models/DuplicateStrategyTests.swift`

- [ ] **Step 1: 写出 hardlink、三段抽样和缓存失效测试**

```swift
@Suite("File hash cache")
struct FileHashCacheTests {
    @Test("相同实例第二次读取不重复 full hash")
    func reusesFullHash() async throws {
        let hasher = CountingFileHasher(fullHash: "full")
        let cache = FileHashCache(fileURL: temporaryURL(), hasher: hasher)
        let metadata = FileMetadata.fixture(device: 1, inode: 2, logicalSize: 100, mtime: 10)
        _ = try await cache.fullHash(for: metadata)
        _ = try await cache.fullHash(for: metadata)
        #expect(await hasher.fullHashCalls == 1)
    }

    @Test("大小或 mtime 变化后重新 hash")
    func invalidatesChangedFile() async throws {
        let hasher = CountingFileHasher(fullHash: "full")
        let cache = FileHashCache(fileURL: temporaryURL(), hasher: hasher)
        _ = try await cache.fullHash(for: .fixture(logicalSize: 100, mtime: 10))
        _ = try await cache.fullHash(for: .fixture(logicalSize: 101, mtime: 10))
        _ = try await cache.fullHash(for: .fixture(logicalSize: 100, mtime: 11))
        #expect(await hasher.fullHashCalls == 3)
    }
}

@Test("首中尾抽样可区分只有中部不同的文件")
func sampledHashReadsThreeRegions() async throws {
    let hasher = RecordingFileHasher()
    _ = try await hasher.sampledHash(path: "/tmp/a", logicalSize: 12_288, chunkSize: 4_096)
    #expect(await hasher.readOffsets == [0, 4_096, 8_192])
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter 'FileHashCacheTests|DuplicateStrategyTests'`

Expected: 新缓存和三段抽样测试失败。

- [ ] **Step 3: 实现三阶段重复检测**

顺序固定为：allocated/logical size 分桶；对 `linkCount > 1` 先按 `(device,inode)` 合并物理对象；首/中/尾各最多 64 KiB 的 sampled hash；最后只对 sampled hash 相同的桶计算 full hash。所有 hash 通过 `context.hashTaskLimiter`，最大并发 4。

- [ ] **Step 4: 实现持久化 hash 缓存**

缓存键为 schema version、device、inode、logical size、mtime nanoseconds；值为 full SHA-256 和计算时间。默认文件 `~/Library/Application Support/DevClean/Scan/file-hashes-v1.json`，actor 管理、原子写入、最多 50,000 条 LRU。symlink、目录和无法获得稳定 identity 的文件不进入缓存。

- [ ] **Step 5: 验证并提交**

Run: `swift test --filter 'FileHashCacheTests|DuplicateStrategyTests'`

Expected: 全部通过；同 inode hardlink 不形成重复组；第二次扫描不调用 full hash。

```bash
git add Sources/MacCleanerCore/Services/FileHashCache.swift \
  Sources/MacCleanerCore/Services/FileHasher.swift \
  Sources/MacCleanerCore/Modules/DuplicateFilesModule.swift \
  Tests/MacCleanerTests/Services/FileHashCacheTests.swift \
  Tests/MacCleanerTests/Models/DuplicateStrategyTests.swift
git commit -m "Core: cache bounded duplicate file hashing"
```

### Task 6: 实现带权搜索、筛选和可操作性排序

**Files:**
- Create: `Sources/MacCleanerCore/Models/SearchDocument.swift`
- Create: `Sources/MacCleanerCore/Services/ResultSearchEngine.swift`
- Create: `Tests/MacCleanerTests/Services/ResultSearchEngineTests.swift`

- [ ] **Step 1: 写出权重、中文、AI 缺失和筛选测试**

```swift
@Suite("Result search engine")
struct ResultSearchEngineTests {
    @Test("basename 精确匹配排在路径和 AI 文本匹配之前")
    func appliesFieldWeights() {
        let engine = ResultSearchEngine(documents: [
            .fixture(id: "exact", basename: "npm"),
            .fixture(id: "path", path: "/Caches/npm/data"),
            .fixture(id: "ai", aiText: "npm 缓存"),
        ])
        #expect(engine.search(.init(text: "npm")).map(\.id) == ["exact", "path", "ai"])
    }

    @Test("中文、大小写和宽字符规范化后可搜索")
    func normalizesText() {
        let engine = ResultSearchEngine(documents: [
            .fixture(id: "one", basename: "Ｃａｃｈｅ", tags: ["开发工具缓存"]),
        ])
        #expect(engine.search(.init(text: "cache")).map(\.id) == ["one"])
        #expect(engine.search(.init(text: "开发 缓存")).map(\.id) == ["one"])
    }

    @Test("无 AI 结果仍可按事实搜索")
    func worksWithoutAssessment() {
        let engine = ResultSearchEngine(documents: [.fixture(id: "one", aiText: nil, path: "/tmp/cache")])
        #expect(engine.search(.init(text: "cache")).count == 1)
    }

    @Test("风险、建议、分析状态、模块和最小大小可组合筛选")
    func combinesFilters() {
        let query = ResultSearchQuery(
            text: "",
            modules: [.xcode],
            risks: [.low],
            recommendations: [.delete],
            assessmentStatuses: [.cached, .fresh],
            minimumAllocatedSize: 1_000
        )
        let result = ResultSearchEngine(documents: [.matchingFixture(), .nonMatchingFixture()]).search(query)
        #expect(result.map(\.id) == ["matching"])
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter ResultSearchEngineTests`

Expected: 编译失败，提示 search model/engine 不存在。

- [ ] **Step 3: 构建一次性规范化文档**

```swift
public struct SearchDocument: Identifiable, Sendable {
    public let id: String
    public let basename: String
    public let path: String
    public let tags: [String]
    public let bundleIdentifier: String?
    public let aiText: String?
    public let module: ModuleIdentifier?
    public let allocatedSize: Int64
    public let risk: AIRiskLevel?
    public let recommendation: AIRecommendation?
    public let confidence: AIConfidence?
    public let assessmentStatus: AssessmentStatus
}

public enum AssessmentStatus: String, CaseIterable, Sendable {
    case notConfigured, notAnalyzed, cached, loading, fresh, failed
}

public enum ResultSortMode: String, CaseIterable, Sendable {
    case relevance, actionability, size
}

public struct ResultSearchQuery: Sendable {
    public var text: String
    public var modules: Set<ModuleIdentifier>
    public var risks: Set<AIRiskLevel>
    public var recommendations: Set<AIRecommendation>
    public var assessmentStatuses: Set<AssessmentStatus>
    public var minimumAllocatedSize: Int64?
    public var sortMode: ResultSortMode

    public init(
        text: String,
        modules: Set<ModuleIdentifier> = [],
        risks: Set<AIRiskLevel> = [],
        recommendations: Set<AIRecommendation> = [],
        assessmentStatuses: Set<AssessmentStatus> = [],
        minimumAllocatedSize: Int64? = nil,
        sortMode: ResultSortMode = .relevance
    ) {
        self.text = text
        self.modules = modules
        self.risks = risks
        self.recommendations = recommendations
        self.assessmentStatuses = assessmentStatuses
        self.minimumAllocatedSize = minimumAllocatedSize
        self.sortMode = sortMode
    }
}
```

初始化时对所有文本执行兼容分解、全角折叠、diacritic insensitive、case folding；query 只规范化一次并按空白拆 token。文档在扫描结果或 AI 状态变化时重建，不在每次键入时重新读取文件系统。

- [ ] **Step 4: 实现固定权重**

每个 token 取最佳字段分数后累加：basename 精确 1000、basename 前缀 750、basename 包含 500、tag/bundle ID 包含 350、path 组件包含 200、AI summary/explanation/evidence 包含 100。所有 token 都必须命中。分数相同按显式 sort mode 处理：relevance 使用 confidence、allocated size、basename；actionability 使用 recommendation `delete > inspect > keep > unknown`、risk `low > medium > high > critical > unknown`、confidence、allocated size；size 直接按 allocated size。

风险与建议仍是两个独立筛选字段；排序只用于展示，不推导选择或执行。

- [ ] **Step 5: 验证并提交**

Run: `swift test --filter ResultSearchEngineTests`

Expected: 全部通过，重复运行结果顺序一致。

```bash
git add Sources/MacCleanerCore/Models/SearchDocument.swift \
  Sources/MacCleanerCore/Services/ResultSearchEngine.swift \
  Tests/MacCleanerTests/Services/ResultSearchEngineTests.swift
git commit -m "Core: rank and filter cleanup search results"
```

### Task 7: 在结果页和活动监视器接入搜索引擎

**Files:**
- Modify: `Sources/MacCleanerApp/Features/Results/ResultsViewModel.swift`
- Modify: `Sources/MacCleanerApp/Features/Results/ResultsView.swift`
- Modify: `Sources/MacCleanerApp/Features/ActivityMonitor/ActivityMonitorViewModel.swift`
- Modify: `Sources/MacCleanerApp/Features/ActivityMonitor/ActivityMonitorView.swift`
- Create: `Tests/MacCleanerAppTests/ResultsSearchViewModelTests.swift`
- Create: `Tests/MacCleanerAppTests/ActivityMonitorSearchViewModelTests.swift`

- [ ] **Step 1: 写出搜索不触发 AI 且不改变选择测试**

```swift
@MainActor
@Suite("Results search view model")
struct ResultsSearchViewModelTests {
    @Test("键入、筛选和排序不调用 AI、不改变选择")
    func searchIsLocalAndSelectionNeutral() async {
        let ai = RecordingAIService()
        let viewModel = ResultsViewModel.fixture(aiService: ai)
        let selectedBefore = viewModel.selectedItemIDs
        viewModel.searchText = "npm"
        viewModel.selectedRisks = [.low]
        viewModel.sortMode = .actionability
        await viewModel.updateSearchResultsImmediatelyForTesting()
        #expect(await ai.analysisCallCount == 0)
        #expect(viewModel.selectedItemIDs == selectedBefore)
    }
}

@MainActor
@Test("进程搜索包含真实路径和已有 AI 文本")
func processSearchUsesFactsAndCachedAI() async {
    let viewModel = ActivityMonitorViewModel.fixture(
        processes: [.fixture(path: "/Applications/Test.app/Test")],
        cachedAssessment: .fixture(summary: "图像处理服务")
    )
    viewModel.searchText = "图像处理"
    await viewModel.updateSearchResultsImmediatelyForTesting()
    #expect(viewModel.filteredProcesses.count == 1)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacCleanerAppTests/ResultsSearchViewModelTests -only-testing:MacCleanerAppTests/ActivityMonitorSearchViewModelTests`

Expected: 新搜索字段和引擎尚未接入，测试失败。

- [ ] **Step 3: 实现 view model 搜索状态**

Results 增加 `searchText`、module/risk/recommendation/status/size filters、`sortMode` 和 `visibleItems`。Activity Monitor 增加 text、assessment status、risk/recommendation filters 和 CPU/memory/name sort。输入采用 150 ms debounce；新输入取消上次 search task。AI 状态变化只重建受影响 document。

- [ ] **Step 4: 实现紧凑筛选 UI**

搜索栏始终可见；下方使用可清除 chips 显示模块、AI 风险、AI 建议、分析状态和大小；“重置筛选”只清 filters，不清选择。无结果时区分“扫描没有候选”和“当前筛选无匹配”。已缓存 AI 文本参与搜索，未分析项不显示虚构说明。

- [ ] **Step 5: 验证并提交**

Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacCleanerAppTests/ResultsSearchViewModelTests -only-testing:MacCleanerAppTests/ActivityMonitorSearchViewModelTests`

Expected: 全部通过。

```bash
git add Sources/MacCleanerApp/Features/Results \
  Sources/MacCleanerApp/Features/ActivityMonitor \
  Tests/MacCleanerAppTests/ResultsSearchViewModelTests.swift \
  Tests/MacCleanerAppTests/ActivityMonitorSearchViewModelTests.swift
git commit -m "App: add local ranked search and filters"
```

### Task 8: 增加 release benchmark 和总体验收

**Files:**
- Modify: `Package.swift`
- Create: `Benchmarks/MacCleanerBenchmarks/main.swift`

- [ ] **Step 1: 增加 benchmark executable target**

```swift
.executableTarget(
    name: "MacCleanerBenchmarks",
    dependencies: ["MacCleanerCore"],
    path: "Benchmarks/MacCleanerBenchmarks"
),
```

- [ ] **Step 2: 实现确定性搜索 benchmark**

benchmark 用固定 seed 构造 10,000 个 `SearchDocument`，预热 5 次，运行 20 个固定中英文查询，使用 `ContinuousClock` 记录每次 duration 并计算 p50/p95。程序打印 JSON：

```json
{"documents":10000,"queries":20,"p50_ms":0.0,"p95_ms":0.0,"stable_order":true}
```

若 p95 > 100 ms 或结果顺序在两轮间不同，进程以 exit code 1 退出。搜索不触发 AI 的约束由 Task 7 的 recording service 测试验证。

- [ ] **Step 3: 运行专项与完整测试**

Run: `swift test --filter 'FileMetadata|AsyncLimiter|ScanCoordinator|CandidateMerger|TopNHeap|FileHashCache|DuplicateStrategy|ResultSearchEngine'`

Expected: 全部通过，0 issues。

Run: `swift test`

Expected: 所有 suite 通过，0 issues。

- [ ] **Step 4: 运行 release benchmark**

Run: `swift run -c release MacCleanerBenchmarks`

Expected: exit code 0，JSON 中 `documents` 为 10000、`queries` 为 20、`p95_ms` 不超过 100、`stable_order` 为 true。

- [ ] **Step 5: 构建并测试 App**

Run: `xcodegen generate && xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

Expected: `** TEST SUCCEEDED **`。

- [ ] **Step 6: 手工验证一次真实扫描**

在同一台机器上连续扫描两次：第二次重复文件 full hash 明显减少；总大小以实际占用显示；硬链接和模块重叠不重复计数；取消扫描后新文件任务停止；搜索、筛选和排序即时更新且不触发 AI、不改变选择。

- [ ] **Step 7: 提交**

```bash
git add Package.swift Benchmarks/MacCleanerBenchmarks/main.swift
git commit -m "Perf: add scan and search acceptance benchmark"
```
