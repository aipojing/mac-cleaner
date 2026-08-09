# Mac Cleaner 版本迭代路线图

## v1.0 — 安全和一致性 ✅ 已完成

> 目标：用户点"开始清理"时，结果 100% 符合预期，零意外删除

### P0 — 扫描/删除语义对齐

| 模块 | 问题 | 解决方案 |
|------|------|----------|
| iOS 模拟器 | 扫描 path 为展示目录，删除通过 subcategory UDID | 明确 path 为 CoreSimulator/Devices 根目录，clean() 通过 subcategory 执行 simctl delete，添加结构化失败原因 |
| AI 工具缓存 | 历史版本路径过宽会删除整个工具目录 | 已收窄到 cache 子目录（如 ~/.codex/cache），dataPaths 与 cachePaths 严格区分 |
| 应用残留 | AppUninstallerService 扫描范围 > 实际可删范围 | 残留路径按可达性标记，沙盒受限路径不进清理列表 |
| 通用 Deleter | 删除后无校验 | 删除前检查存在性，删除后 stat 确认，返回 verified 状态和 actual vs expected 差异 |

**关键实现：**
- `CleanupReport` 新增 `expectedSize`/`actualFreed`/`discrepancy` 字段
- `FailedItem` 新增 `FailureReason` 枚举（permissionDenied/fileInUse/notFound/diskFull/unknown），自动分类
- `CleanedItem` 新增 `verified` 字段

### P1 — 排除规则与保护策略

- `ExclusionRule` 模型支持 4 种类型：
  - `pathPattern` — glob 路径模式匹配（如 `*/DerivedData/MyProject-*`）
  - `recency` — 最近 N 天内修改的文件不清理
  - `minSize` — 低于指定大小不展示
  - `permanentKeep` — 永久保留标记
- `ExclusionManager` actor 负责持久化（`~/Library/Application Support/MacCleaner/exclusions.json`）和过滤管道
- 规则支持模块级作用域（如仅对 xcode 模块生效）
- `ScanViewModel` 扫描完成后自动应用排除规则

### P2 — 删除后校验与差异报告

- `CleanupSummary` 结构：expectedSize / actualFreed / failedItems / hasPermissionIssues
- `CleanupView` 展示：
  - 实际回收 vs 预计回收差异
  - 按原因分组的失败摘要
  - 可展开的失败详情列表（路径 + 原因）
  - 权限不足时的橙色横幅提示

### P3 — 权限诊断页

- `PermissionDiagnostic` 服务：探测 16 个关键目录的访问状态，检测 FDA
- `DirectoryAccessResult` 4 种状态：accessible / notFound / denied / sandboxRestricted
- `PermissionDiagnosticReport` 包含受影响模块列表、completeness 百分比
- `PermissionDiagnosticView`：FDA 状态卡片、目录列表、受影响模块标签
- `ScanSummaryView` 集成：扫描完成后自动运行诊断，有问题时显示橙色横幅

### P4 — 测试补强

测试数量从 24 → 129：

| 测试类别 | 内容 |
|----------|------|
| 删除语义 | Deleter 验证删除后确认、notFound 检测、dry run 安全性、expected/actual 跟踪 |
| 失败分类 | FailedItem 的 permission/inUse/notFound/unknown 自动分类 |
| 排除规则 | 4 种规则工厂、toggle 不可变性、Codable 序列化、minSize/permanentKeep/disabled/module-scoped 过滤 |
| 权限诊断 | 诊断报告生成、completeness 计算、affected modules 聚合 |
| 模块对齐 | 模拟器 subcategory 对齐、AI 工具路径安全检查、所有模块绝对路径验证、dryRun 安全验证 |

---

## v2.0 — 高价值覆盖 + 体验增强 ✅ 已完成

> 目标：覆盖开发者 80% 的磁盘浪费场景，形成清理闭环

### P0 — 补齐开发者缓存

- Homebrew 旧版本清理 + 下载缓存
- Cargo 编译缓存（`~/.cargo/registry/cache`）
- Go 模块缓存（`~/go/pkg/mod/cache`）+ 构建缓存
- pip 下载缓存（`~/.cache/pip`）
- SwiftPM 缓存（`~/Library/Caches/org.swift.swiftpm/`）
- Docker 模块：磁盘镜像、构建缓存、应用缓存、日志

### P1 — 强化 Xcode/Apple 生态

- DerivedData 按项目拆分展示（解析 `info.plist` 中的 `WorkspacePath`）
- DeviceSupport 按 iOS 版本分组，标注当前版本/旧版本
- Simulator runtime vs device data 独立管理，runtime 标注版本和大小

### P2 — 强化应用卸载器

- 扩展残留检测范围：LaunchDaemons、Application Scripts、Group Containers、HTTPStorages、WebKit、Crash Reports
- 按残留类型分组展示

### P3 — 强化重复文件

- ✅ 自动策略：保留最新 / 保留路径最短 / 保留指定目录下的文件 — 分段选择器 + 目录选择
- ✅ 忽略目录配置（如 `node_modules`、`.git`）— `defaultSkipDirectories`
- ✅ 大文件优先排序

### P4 — 清理历史与趋势

- ✅ 每次扫描/清理结果落盘（JSON 文件持久化）+ CleanupViewModel 自动记录
- ✅ 首页展示"累计释放 X GB"、释放空间 Top 5 模块、上次清理时间
- ✅ SwiftUI Charts 趋势图（近 30 天柱状图）+ Top 5 模块横向柱状图

---

## v3.0 — 平台化 + 自动化 ✅ 已完成（P2 规则包除外，仍为规划项）

> 目标：从工具变为常驻服务

### P0 — 可保存清理方案

- `CleaningProfile` 模型：name、moduleIDs、isBuiltIn、icon（无条目级筛选字段；规划中的 maxRiskLevel/onlyRecommended 因无风险判断依据而未实现）
- 3 个内置方案：开发环境瘦身、发版前清理、日志清理（"仅安全项"方案未实现——无 AI/本地判断时无法兑现条目级语义）
- `ProfileManager` actor：用户自定义方案 CRUD + JSON 持久化
- CLI 集成：`--profile "方案名"` 和 `--list-profiles`；"所有模块"的方案与 `--all` 均默认排除大文件等用户数据模块

### P1 — 定时扫描 + 菜单栏提醒

- `ScheduledScanConfig` 模型：间隔、低空间阈值、通知开关
- `ScheduledScanService` actor：后台周期扫描 + 低磁盘通知（UserNotifications）
- `MenuBarViewModel` 增强：显示可回收空间、定时扫描开关

### P2 — 可扩展规则包（规划中，未实现）

- ~~`RulesProvider` 新增加载 `~/.config/maccleaner/rules.d/*.json`~~（代码中不存在 RulesProvider 与用户规则目录加载，仅保留为规划项）
- ~~用户规则优先级最高，覆盖内置和远程规则~~（未实现）
- ~~`ensureUserRulesDirectory()` 工具方法~~（未实现）

### P3 — 磁盘可视化闭环

- `DiskVisualizationView` 右键菜单：加入清理列表、在 Finder 中显示、复制路径、复制大小
- `onAddToCleanup` 回调支持从 Treemap 直接添加到清理流程

### P4 — 系统日志清理

- `SystemLogsModule`：用户日志、诊断报告、崩溃报告、Spindump
- 30 天阈值区分 stale/recent
- `ModuleIdentifier.systemLogs` + ModuleRegistry 注册

### P5 — CLI 方案集成

- `CleanCommand --profile` 选项：按方案过滤模块和项目
- `--list-profiles` 列出所有可用方案

---

## v3.5 — 系统工具箱 ✅ 已完成

> 目标：从磁盘清理扩展为轻量系统工具箱

### P0 — 活动监视器

- 进程实时监控（3 秒自动刷新）
- 40+ 常见进程中文描述数据库 + 启发式分类
- 「关了会怎样」后果说明 + 操作建议
- 终止按钮分级：critical 禁止、dangerous 警告、safe/caution 正常
- `kill()` 安全防护：`guard pid > 0` 防止误杀全局进程

### P1 — Android SDK 模块

- platforms / build-tools / NDK / system-images / AVD 扫描
- 按组件类型分组，标注版本和大小

### P2 — 大文件智能分类

- 构建产物 / 安装包 / 压缩包 / 日志自动识别
- 按风险等级分类：构建产物标 safe，用户文件标 destructive

---

## 体验优化方向

| 方向 | 说明 | 状态 |
|------|------|------|
| 快捷键 | Cmd+Shift+N 新建扫描、Cmd+, 偏好设置 | ✅ |
| 深色/浅色主题 | 跟随系统 + 7 种自定义主题色（偏好设置面板） | ✅ |
| i18n | 英文 + 简体中文，`Localizable.strings` 全覆盖 | ✅ |
| Sparkle 自动更新 | 应用内检查更新（需签名证书和分发渠道） | ⬚ |

---

## 推荐迭代节奏

```
v1.0  安全和一致性（删除语义对齐 + 排除规则 + 权限诊断 + 测试）  ← ✅ 已完成
v2.0  高价值覆盖（补缓存缺口 + Xcode/Docker + 卸载器 + 重复文件策略 + 历史趋势）  ← ✅ 已完成
v3.0  平台化（清理方案 + 定时扫描 + 可扩展规则 + 系统日志 + 可视化闭环）  ← ✅ 已完成
v3.5  系统工具箱（活动监视器 + Android SDK + 大文件智能分类）  ← ✅ 已完成
```
