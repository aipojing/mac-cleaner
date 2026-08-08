# 实时大文件扫描体验设计

## 目标

让用户在大文件扫描尚未完成时立即看到已经发现的候选，而不是等待整个主目录枚举结束；同时减少多路文件系统遍历带来的元数据 I/O 争抢。首期不持久化整个主目录的扫描索引，所有扫描数据仅保留在当前应用会话内。

## 非目标

- 不保存整个主目录的文件路径、大小和 inode 快照。
- 不接入 FSEvents 做跨启动增量扫描。
- 不改变清理范围、阈值（默认 100 MB）或删除策略。
- 不静默扩大排除目录名单而漏掉用户可能需要查看的大文件。

## 用户体验

点击“大文件清理”后，扫描页立即进入实时模式：

1. 保留已有的“正在扫描”路径和取消按钮。
2. 首次发现符合阈值的文件时立即显示一张“实时发现”列表；之后列表持续更新。
3. 列表展示当前最大的最多 50 个候选、发现数量和已发现候选的物理占用总量。
4. 列表明确标注“扫描中，排名会随新文件发现而变化”。不允许在扫描中执行清理。
5. 取消时停止后续更新并丢弃临时实时结果；完成时以最终 `ScanResult` 取代临时结果，进入既有汇总页。

更新不能为每个目录项触发一次 SwiftUI 重绘：第一个候选立即发布，后续候选在核心层合并成不高于每秒约 5 次的快照更新，完成时必定发布最终快照。

## 核心数据流

```text
fts 枚举主目录
  → 发现符合阈值的文件
  → TopNHeap 更新当前 Top 50
  → LargeFileScanUpdate（合并、限频）
  → ScanContext 的可选更新处理器
  → ScanViewModel（切换至 MainActor）
  → ScanView 的实时列表
  → 扫描结束：最终 ScanResult
```

### 数据类型与接口

在 `MacCleanerCore` 新增 `LargeFileScanUpdate`：

- `items: [CleanableItem]`：当前按实际占用从大到小排列的临时 Top 50。
- `matchedFileCount: Int`：本次扫描至今满足阈值的文件总数，而非仅显示数。
- `matchedAllocatedSize: Int64`：满足阈值文件的累计实际占用；同一 device/inode 只计一次。
- `isFinal: Bool`：最后一次更新为 `true`。

`ScanContext` 增加可选的 `onLargeFileUpdate: @Sendable (LargeFileScanUpdate) -> Void`。仅 `LargeFileScannerModule` 使用；CLI 和其他模块不传处理器，行为与当前一致。

`TopNHeap.insert` 返回是否改变保留集合，以便扫描器只在新的候选进入或替换 Top 50 时考虑发布快照。

`LargeFileScannerModule` 从扫描时的 `FileMetadata` 直接构造临时 `CleanableItem`，与最终结果使用同一分类与字段。扫描器通过一个内部、可注入时钟的限频发布器发送首个、间隔内合并的及最终快照；取消检查发生在遍历和发布前。

## UI 状态

`ScanViewModel` 增加仅用于进行中大文件扫描的状态：

- `liveLargeFileItems`
- `liveLargeFileMatchCount`
- `liveLargeFileMatchedSize`

启动单独的大文件扫描时创建带更新处理器的 `ScanCoordinator`。处理器不直接改 UI，而是切到 `MainActor` 后替换快照；每个快照已经过核心层限频。`ScanView` 在原扫描信息下展示一个至多 5 行的紧凑列表和“查看最终详情”的说明，避免扫描页变成完整结果页。

完成、失败、取消和重新开始时都清空实时状态，防止旧扫描结果闪现。最终结果继续使用现有 `ScanSummaryView` 与 `ResultsView`，不引入第二套结果模型。

## I/O 策略

`FTSTraversalGate` 从随 CPU 数扩展的上限改为独立的保守默认值 `2`。这是全进程 FTS 遍历上限，避免 `ScanCoordinator` 的模块并发与模块内部的目录大小计算共同放大元数据读取压力。文件哈希并发保持原有独立上限。

大文件扫描继续使用 `FTS_PHYSICAL`，不跟随符号链接；同时增加 `FTS_XDEV`，避免从用户主目录意外进入挂载在其中的其他卷。现有排除项保持不变，避免为了速度悄悄隐藏用户文件。

这期不尝试把所有模块合成一次全主目录遍历：开发缓存、Xcode 和应用缓存需要不同粒度的候选与删除策略。单独触发“大文件清理”时本来只运行该模块；总扫描则通过最多两条 FTS 遍历降低争抢。

## 错误与取消

- 无法访问的目录沿用 FTS 的跳过行为，不把权限错误伪装成零大小。
- 取消应停止发布、使 `ScanCoordinator` 保持既有取消语义，并清空 UI 临时数据。
- 实时项不是清理授权；只有最终 `ScanResult` 才能进入既有确认与删除流程。

## 测试

1. `TopNHeap`：插入进入/替换/未进入 Top N 时的“集合是否变化”返回值。
2. `LargeFileScannerModule`：使用临时目录，验证第一个符合阈值的文件会在扫描结束前发布；最终快照排序、数量和最终 `ScanResult` 一致。
3. `LargeFileScannerModule`：验证相同 inode（硬链接）在累计物理占用中只计算一次。
4. `FTSTraversalGate`：并发遍历时峰值不超过 2。
5. `ScanViewModel` 或抽出的实时状态存储：验证更新在主线程替换、取消与重启会清空状态、最终结果不会与临时结果混用。

## 验收标准

- 点击“大文件清理”后，发现首个大文件无需等待完整扫描结束即可在 UI 中出现。
- 扫描期间最多每秒约 5 次 UI 候选刷新，扫描路径进度仍可更新。
- 最终列表仍为准确、稳定排序的 Top 50，既有清理与确认流程不变。
- 同时进行的 FTS 遍历不超过 2。
- Core 与 App 测试通过，且 CLI 的无观察者扫描输出保持兼容。
