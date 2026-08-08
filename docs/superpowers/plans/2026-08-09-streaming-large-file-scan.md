# 实时大文件扫描 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 扫描大文件时即时展示不断更新的候选列表，并把进程内 FTS 遍历并发限制为 2，降低元数据 I/O 争抢。

**Architecture:** `LargeFileScannerModule` 在保留 Top N 堆的同时向 `ScanContext` 发布合并后的快照；`ScanViewModel` 将快照安全地切换至主线程，`ScanView` 渲染一个只读的实时列表。最终 `ScanResult` 仍是唯一可进入既有结果页和清理流程的数据源。全进程 FTS gate 独立限制为 2，不保存跨启动索引，也不改变删除策略。

**Tech Stack:** Swift 5.9、Swift Concurrency、SwiftUI、Swift Testing、POSIX `fts`。

## Global Constraints

- 平台下限为 macOS 14；不得新增第三方依赖。
- 只对“大文件清理”单模块扫描展示实时候选；其他模块与 CLI 输出保持兼容。
- 实时 UI 只读，扫描完成前不得提供清理入口。
- 候选显示仍使用实际占用 `st_blocks * 512`，路径、文件身份和删除护栏的既有语义不能变化。
- 大文件扫描继续使用 `FTS_PHYSICAL`，新增 `FTS_XDEV`；不静默扩大既有排除目录名单。
- 首次候选立即发布；后续更新在核心层限频到每秒最多 5 次；完成时无条件发送最终快照。
- 当前项目目录故意没有 `.git`。不要在其中初始化 Git；完成后用临时 clone 把明确改动同步到 `aipojing/mac-cleaner` 的 `main`。

---

## 文件变更地图

| 文件 | 责任 |
| --- | --- |
| `Sources/MacCleanerCore/Models/LargeFileScanUpdate.swift` | 实时扫描快照的 Sendable 模型。 |
| `Sources/MacCleanerCore/Services/LargeFileUpdatePublisher.swift` | 可测试的首发、限频、最终发布策略。 |
| `Sources/MacCleanerCore/Models/ScanContext.swift` | 把可选实时快照处理器传给大文件模块。 |
| `Sources/MacCleanerCore/Services/TopNHeap.swift` | 让插入操作报告 Top N 集合是否改变。 |
| `Sources/MacCleanerCore/Modules/LargeFileScannerModule.swift` | 一边 FTS 枚举，一边生成实时快照；最终仍返回 `ScanResult`。 |
| `Sources/MacCleanerCore/Services/FTSTraversalGate.swift` | 将全进程 FTS 并发上限固定为 2。 |
| `Sources/MacCleanerCore/Services/ScanCoordinator.swift` | 把实时处理器装入一次扫描的 `ScanContext`。 |
| `Sources/MacCleanerApp/Features/Scan/ScanViewModel.swift` | 保存实时大文件状态，主线程应用/清空快照。 |
| `Sources/MacCleanerApp/Features/Scan/ScanView.swift` | 在扫描页渲染紧凑的候选预览与临时状态。 |
| `Tests/MacCleanerTests/Services/TopNHeapTests.swift` | Top N 变化信号测试。 |
| `Tests/MacCleanerTests/Modules/LargeFileScannerStreamingTests.swift` | 实时事件、排序、物理占用、最终结果测试。 |
| `Tests/MacCleanerTests/Services/FileMetadataIndexTests.swift` | 更新 FTS 并发上限断言。 |
| `Tests/MacCleanerAppTests/ScanViewModelLiveResultsTests.swift` | 实时状态应用、取消和重置测试。 |

## Task 1: Top N 变化信号与实时快照模型

**Files:**

- Create: `Sources/MacCleanerCore/Models/LargeFileScanUpdate.swift`
- Modify: `Sources/MacCleanerCore/Services/TopNHeap.swift`
- Modify: `Tests/MacCleanerTests/Services/TopNHeapTests.swift`

**Consumes:** 现有 `CleanableItem`、`TopNHeap`。

**Produces:** `LargeFileScanUpdate`，以及 `TopNHeap.insert(_:) -> Bool`。

- [ ] **Step 1: 为 Top N 变化信号写失败测试。**

  在 `TopNHeapTests.swift` 添加：

  ```swift
  @Test("插入结果只在保留集合变化时返回 true")
  func reportsRetainedSetChanges() {
      var heap = TopNHeap<Int>(capacity: 2, score: { Int64($0) })
      #expect(heap.insert(10))
      #expect(heap.insert(20))
      #expect(!heap.insert(5))
      #expect(heap.insert(30))
      #expect(heap.sortedDescending() == [30, 20])
  }
  ```

- [ ] **Step 2: 运行失败测试。**

  Run: `swift test --filter TopNHeapTests/reportsRetainedSetChanges`
  Expected: 编译失败，提示 `insert` 的 `Void` 返回值不能用于 `#expect`。

- [ ] **Step 3: 最小化修改堆实现。**

  将 `insert` 改为以下语义，保留现有排序和峰值统计：

  ```swift
  @discardableResult
  public mutating func insert(_ element: Element) -> Bool {
      guard capacity > 0 else { return false }
      if storage.count < capacity {
          storage.append(element)
          siftUp(from: storage.count - 1)
          maximumObservedCount = max(maximumObservedCount, storage.count)
          return true
      }
      guard ranksBefore(element, storage[0]) else { return false }
      storage[0] = element
      siftDown(from: 0)
      return true
  }
  ```

  新建模型：

  ```swift
  public struct LargeFileScanUpdate: Sendable {
      public let items: [CleanableItem]
      public let matchedFileCount: Int
      public let matchedAllocatedSize: Int64
      public let isFinal: Bool

      public init(
          items: [CleanableItem],
          matchedFileCount: Int,
          matchedAllocatedSize: Int64,
          isFinal: Bool
      ) {
          self.items = items
          self.matchedFileCount = matchedFileCount
          self.matchedAllocatedSize = matchedAllocatedSize
          self.isFinal = isFinal
      }
  }
  ```

- [ ] **Step 4: 验证测试与旧行为。**

  Run: `swift test --filter TopNHeapTests`
  Expected: 全部 Top N 测试通过；既有调用可忽略 `Bool` 返回值。

## Task 2: 可测试的实时更新发布器与扫描上下文

**Files:**

- Create: `Sources/MacCleanerCore/Services/LargeFileUpdatePublisher.swift`
- Create: `Tests/MacCleanerTests/Services/LargeFileUpdatePublisherTests.swift`
- Modify: `Sources/MacCleanerCore/Models/ScanContext.swift`
- Modify: `Sources/MacCleanerCore/Services/ScanCoordinator.swift`

**Consumes:** Task 1 的 `LargeFileScanUpdate`。

**Produces:** `LargeFileUpdatePublisher`，以及 `ScanContext.onLargeFileUpdate` / `ScanCoordinator` 的可选观察者参数。

- [ ] **Step 1: 先测试首发、合并与最终发布。**

  用可控时钟验证发布策略：首项立刻发送；0.2 秒内的中间更新只保留为待发快照；0.2 秒后发送最新快照；`finish` 无条件发送最后快照。测试不要依赖 `Task.sleep`。

  ```swift
  @Test("首项立即发布，间隔内更新合并，最终快照必定发布")
  func coalescesUpdatesAndAlwaysFinishes() {
      var now: TimeInterval = 100
      var delivered: [Int] = []
      var publisher = LargeFileUpdatePublisher<Int>(
          minimumInterval: 0.2,
          now: { now },
          deliver: { delivered.append($0) }
      )

      publisher.submit(1)
      now += 0.05; publisher.submit(2)
      now += 0.05; publisher.submit(3)
      now += 0.11; publisher.submit(4)
      publisher.finish(5)

      #expect(delivered == [1, 4, 5])
  }
  ```

- [ ] **Step 2: 运行失败测试。**

  Run: `swift test --filter LargeFileUpdatePublisherTests`
  Expected: 编译失败，提示 `LargeFileUpdatePublisher` 不存在。

- [ ] **Step 3: 实现发布器与上下文传递。**

  发布器为泛型内部类型，采用 `TimeInterval` 时钟注入，保证测试确定性：

  ```swift
  struct LargeFileUpdatePublisher<Value> {
      let minimumInterval: TimeInterval
      let now: () -> TimeInterval
      let deliver: (Value) -> Void
      private var lastDeliveryTime: TimeInterval?
      private var pending: Value?

      mutating func submit(_ value: Value) {
          let currentTime = now()
          guard let lastDeliveryTime,
                currentTime - lastDeliveryTime < minimumInterval
          else {
              pending = nil
              self.lastDeliveryTime = currentTime
              deliver(value)
              return
          }
          pending = value
      }

      mutating func finish(_ value: Value) {
          pending = nil
          lastDeliveryTime = now()
          deliver(value)
      }
  }
  ```

  `ScanContext` 新增字段与末尾默认参数：

  ```swift
  public let onLargeFileUpdate: (@Sendable (LargeFileScanUpdate) -> Void)?

  public init(
      metadataIndex: FileMetadataIndex = FileMetadataIndex(),
      fileTaskLimit: Int = ScanContext.defaultFileTaskLimit,
      hashTaskLimit: Int = ScanContext.defaultHashTaskLimit,
      onLargeFileUpdate: (@Sendable (LargeFileScanUpdate) -> Void)? = nil
  )
  ```

  `ScanCoordinator.init` 新增同类型、默认 `nil` 的 `onLargeFileUpdate` 参数，并在 `scan()` 创建共享 `ScanContext` 时原样传入。不要改动 `CleanerModule` 协议。

- [ ] **Step 4: 验证 Core 编译与协调器兼容性。**

  Run: `swift test --filter 'LargeFileUpdatePublisherTests|ScanCoordinatorTests'`
  Expected: 新旧测试通过；未传观察者的协调器行为不变。

## Task 3: 大文件模块流式发布与 FTS I/O 限流

**Files:**

- Modify: `Sources/MacCleanerCore/Modules/LargeFileScannerModule.swift`
- Modify: `Sources/MacCleanerCore/Services/FTSTraversalGate.swift`
- Create: `Tests/MacCleanerTests/Modules/LargeFileScannerStreamingTests.swift`
- Modify: `Tests/MacCleanerTests/Services/FileMetadataIndexTests.swift`

**Consumes:** Task 1 的堆与快照，Task 2 的 `ScanContext` 处理器。

**Produces:** 流式 `LargeFileScanUpdate`、精确最终结果、全局 FTS 并发上限 2。

- [ ] **Step 1: 写扫描完成前即可观察到首项的失败测试。**

  在临时目录创建 `a.bin`、`b.bin`、`c.bin`，用 1-byte 阈值和 `limit: 2` 扫描。使用带锁的测试收集器保存回调，断言至少有一条非最终更新、最后一条 `isFinal == true`，且最终更新项与 `ScanResult.items` 路径相同、按大小降序。

  ```swift
  @Test("大文件扫描在完成前发布候选，并以最终结果收尾")
  func streamsCandidatesBeforeFinalResult() async throws {
      let collector = LargeFileUpdateCollector()
      let context = ScanContext(onLargeFileUpdate: { collector.append($0) })
      let result = try await LargeFileScannerModule(
          scanRoot: fixture.root, minAllocatedSize: 1, limit: 2
      ).scan(context: context)

      let updates = collector.snapshot()
      #expect(updates.contains { !$0.isFinal })
      #expect(updates.last?.isFinal == true)
      #expect(updates.last?.items.map(\.path) == result.items.map(\.path))
  }
  ```

  在同一文件中用 `linkItem` 创建硬链接，断言 `matchedAllocatedSize` 对同一 `(device, inode)` 只计一次。

- [ ] **Step 2: 运行失败测试。**

  Run: `swift test --filter LargeFileScannerStreamingTests`
  Expected: 失败，因为当前模块从不发布 `LargeFileScanUpdate`。

- [ ] **Step 3: 实现流式扫描。**

  将 `collectLargeFiles()` 改为接收可选处理器、返回最终 `FileMetadata`，并在 `scan(context:)` 中将 `context.onLargeFileUpdate` 传入。枚举中：

  1. 每轮先检查 `Task.isCancelled`，命中后抛出 `CancellationError()`。
  2. 只对满足阈值的常规文件增加 `matchedFileCount`；以 `device:inode` 集合对 `matchedAllocatedSize` 去重。
  3. 每个满足阈值的文件都提交最新快照给发布器；快照中的 `items` 始终来自 `heap.sortedDescending()`。
  4. 使用单个 `makeItem(from:)` 私有函数，供实时快照和最终 `ScanResult` 共用，防止分类/身份字段漂移。
  5. 遍历结束时，调用 `publisher.finish(finalUpdate)`；若处理器为 `nil`，不构造发布器或临时 UI 数据。

  `fts_open` flags 改为：

  ```swift
  FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV
  ```

  `FTSTraversalGate` 改为：

  ```swift
  static let maximumConcurrentTraversals = 2
  private static let semaphore = DispatchSemaphore(value: maximumConcurrentTraversals)
  ```

  在现有 FTS 测试中，将两处 `ScanContext.defaultFileTaskLimit` 的断言替换为 `FTSTraversalGate.maximumConcurrentTraversals`。

- [ ] **Step 4: 验证目标测试与全部 Core 测试。**

  Run: `swift test --filter 'LargeFileScannerStreamingTests|ModuleSemanticTests|FileMetadataIndexTests'`
  Expected: 实时快照、硬链接去重、旧大文件语义和 FTS 并发测试均通过。

  Run: `swift test`
  Expected: 全部 Core 测试通过。

## Task 4: SwiftUI 实时扫描状态与预览

**Files:**

- Modify: `Sources/MacCleanerApp/Features/Scan/ScanViewModel.swift`
- Modify: `Sources/MacCleanerApp/Features/Scan/ScanView.swift`
- Create: `Tests/MacCleanerAppTests/ScanViewModelLiveResultsTests.swift`

**Consumes:** Task 2 的 `LargeFileScanUpdate`。

**Produces:** 仅在单模块大文件扫描期间可见的实时状态与只读预览。

- [ ] **Step 1: 写 ViewModel 状态的失败测试。**

  测试在 `@MainActor` 执行。为 `ScanViewModel` 添加内部 `applyLargeFileUpdate(_:)`，测试其应用快照、最终/重置/取消清空状态。

  ```swift
  @MainActor
  @Test("实时大文件快照会替换状态，取消会清空临时结果")
  func clearsLiveItemsWhenCancelled() {
      let viewModel = ScanViewModel()
      viewModel.applyLargeFileUpdate(.fixture(items: [.fixture(path: "/tmp/a", size: 200)]))
      #expect(viewModel.liveLargeFileItems.count == 1)

      viewModel.cancel()
      #expect(viewModel.liveLargeFileItems.isEmpty)
      #expect(viewModel.liveLargeFileMatchCount == 0)
  }
  ```

  若测试 helper 不存在，在测试文件内扩展 `LargeFileScanUpdate` 与 `CleanableItem` 创建最小 fixture；不要把仅测试用初始化器加入生产模块。

- [ ] **Step 2: 运行失败测试。**

  Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' -only-testing:MacCleanerAppTests/ScanViewModelLiveResultsTests`
  Expected: 编译失败，提示实时状态与应用方法不存在。

- [ ] **Step 3: 实现 ViewModel 主线程状态。**

  在 `ScanViewModel` 添加：

  ```swift
  var liveLargeFileItems: [CleanableItem] = []
  var liveLargeFileMatchCount = 0
  var liveLargeFileMatchedSize: Int64 = 0

  var isLargeFileScan: Bool {
      selectedModuleIDs == [.largeFiles]
  }
  ```

  `startScan()` 在创建 `ScanCoordinator` 时，仅当本次 `moduleIDs == [.largeFiles]` 传入处理器：

  ```swift
  let updateHandler: (@Sendable (LargeFileScanUpdate) -> Void)? =
      moduleIDs == [.largeFiles]
      ? { [weak self] update in
          Task { @MainActor [weak self] in
              self?.applyLargeFileUpdate(update)
          }
      }
      : nil

  let coordinator = ScanCoordinator(
      modules: modules,
      onModuleFinished: { outcome in
          if let error = outcome.error {
              logger.error("\(outcome.module.displayName) error: \(error.localizedDescription)")
          }
          Task { @MainActor [weak self] in
              guard let self, case .scanning = self.phase else { return }
              self.phase = .scanning(
                  completed: outcome.completedCount,
                  total: outcome.totalCount
              )
              if let result = outcome.result {
                  self.results.append(result)
                  self.completedModules.append(result.module)
                  self.totalDiscoveredSize = PhysicalSizeCalculator.uniqueAllocatedBytes(
                      in: self.results.flatMap(\.items)
                  )
              }
          }
      },
      onLargeFileUpdate: updateHandler
  )
  ```

  将现有 `onModuleFinished` 闭包完整保留在该调用中，不得改变它实时追加已完成模块结果的逻辑。`applyLargeFileUpdate` 仅替换临时状态，绝不写入 `results`。`cancel()`、`reset()`、开始一次新扫描、失败分支和正常完成分支都调用一个私有 `clearLiveLargeFileResults()`。

- [ ] **Step 4: 在扫描页增加只读预览。**

  在 `ScanView.scanningState` 的当前路径下、进度条前插入仅在 `viewModel.isLargeFileScan && !viewModel.liveLargeFileItems.isEmpty` 时出现的视图：

  - 标题：`实时发现 · 扫描中`
  - 副标题：`已发现 N 个大文件，排名会持续更新`
  - `ForEach(viewModel.liveLargeFileItems.prefix(5), id: \.path)` 显示文件名和 `SizeFormatter.format(bytes:)`
  - 页脚：`扫描完成后可查看全部结果并选择清理`

  使用现有 `brandCard()`、`Color(.controlBackgroundColor)`、`SizeFormatter`；不要在该区添加按钮或导航。

- [ ] **Step 5: 验证 App 测试与构建。**

  Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' -only-testing:MacCleanerAppTests`
  Expected: 所有 App 测试通过。

  Run: `xcodebuild build -project MacCleaner.xcodeproj -scheme MacCleanerApp -configuration Debug`
  Expected: `BUILD SUCCEEDED`。

## Task 5: 端到端验证、文档与 GitHub 同步

**Files:**

- Modify: `README.md`（仅在现有命令说明中补充“扫描页会流式展示大文件候选”的一句说明）
- Modify: `docs/superpowers/specs/2026-08-09-streaming-scan-experience-design.md`（将状态标记为已实现，并填写实际验证命令）

**Consumes:** Tasks 1–4 的实现和测试。

**Produces:** 经验证的本地变更，以及同步到 GitHub 的单一清晰提交。

- [ ] **Step 1: 做手工安全验证。**

  从桌面应用点击“大文件清理”。确认：第一个候选在扫描仍进行时出现；列表最多显示 5 行；没有清理按钮；取消后临时列表消失；完成后结果页仍可进入既有确认流程。

- [ ] **Step 2: 运行全量验证。**

  Run: `swift test`
  Expected: Core 测试全绿。

  Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS'`
  Expected: App 与 Core 关联测试通过。

- [ ] **Step 3: 仅同步明确变更到 GitHub。**

  当前项目目录无 `.git`。创建临时 clone，复制以下明确变更文件后提交：

  ```text
  Sources/MacCleanerCore/Models/LargeFileScanUpdate.swift
  Sources/MacCleanerCore/Models/ScanContext.swift
  Sources/MacCleanerCore/Modules/LargeFileScannerModule.swift
  Sources/MacCleanerCore/Services/FTSTraversalGate.swift
  Sources/MacCleanerCore/Services/LargeFileUpdatePublisher.swift
  Sources/MacCleanerCore/Services/ScanCoordinator.swift
  Sources/MacCleanerCore/Services/TopNHeap.swift
  Sources/MacCleanerApp/Features/Scan/ScanView.swift
  Sources/MacCleanerApp/Features/Scan/ScanViewModel.swift
  Tests/MacCleanerTests/Modules/LargeFileScannerStreamingTests.swift
  Tests/MacCleanerTests/Services/FileMetadataIndexTests.swift
  Tests/MacCleanerTests/Services/LargeFileUpdatePublisherTests.swift
  Tests/MacCleanerTests/Services/TopNHeapTests.swift
  Tests/MacCleanerAppTests/ScanViewModelLiveResultsTests.swift
  README.md
  docs/superpowers/specs/2026-08-09-streaming-scan-experience-design.md
  docs/superpowers/plans/2026-08-09-streaming-large-file-scan.md
  ```

  在临时 clone 中运行 `git diff --check`，再提交：

  ```bash
  git commit -m "App: stream large-file scan results"
  git push origin main
  ```

  推送后比较远端 `main` 提交 SHA，确认一致；原项目目录保持无 `.git`。

## Plan Self-Review

- **覆盖度：** Tasks 1–3 覆盖实时流、准确最终结果、硬链接去重、取消和 FTS 限流；Task 4 覆盖 UI 呈现与状态清理；Task 5 覆盖安全手测、自动测试与同步。
- **范围：** 没有引入跨启动索引、FSEvents、阈值或删除策略变更；没有隐藏额外目录。
- **接口一致性：** `LargeFileScanUpdate` 只经 `ScanContext.onLargeFileUpdate` 向上传递；`ScanCoordinator` 与 `ScanViewModel` 使用相同名称；最终数据仍为 `ScanResult`。
