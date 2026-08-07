# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

macOS 磁盘清理工具（中文 UI），提供 **SwiftUI 桌面应用** 和 **CLI** 两个入口。扫描开发者缓存、Xcode 产物、iOS 模拟器、AI 工具缓存、应用缓存和大文件，按风险等级分类展示，用户选择后执行删除。

## Build & Test Commands

```bash
swift build                      # Build all targets (CLI + App)
swift run mac-cleaner            # Run CLI (interactive mode)
swift run mac-cleaner scan       # Scan all modules
swift run mac-cleaner scan --json  # JSON output
swift run mac-cleaner clean --dry-run --all --yes  # Preview cleanup
swift test                       # Run all tests (129 tests)
swift test --filter RiskLevelTests  # Run a single test suite
swift test --enable-code-coverage   # Tests with coverage
```

SwiftUI App 需通过 Xcode 打开项目后 Cmd+R 运行（需配置 entitlements 和 code signing）。

## Architecture

**Three targets** sharing `MacCleanerCore`:

```
MacCleanerCore (library)    ← 纯 Foundation，无 UI 框架依赖
├── MacCleanerCLI (executable) ← ArgumentParser + TUI
└── MacCleanerApp (executable) ← SwiftUI 桌面应用
```

### Core Layer (`Sources/MacCleanerCore/`)

`CleanerModule` 协议是核心抽象 — 每个清理类别实现 `scan()` → `ScanResult` 和 `clean(items:dryRun:)` → `CleanupReport`。模块通过 `ModuleRegistry` 注册，用 `ModuleIdentifier` 枚举标识（raw value 如 `"dev-caches"`, `"simulators"` 用于 CLI）。

**风险模型**: `RiskLevel` 三级分类 — `.safe`（可放心删）、`.moderate`（小心删除）、`.destructive`（不建议删除，需二次确认）。每个 `CleanableItem` 必须有 `detail`（删除后果说明），默认取自 `RiskLevel.consequenceHint`。

**Services**: `DiskScanner`（文件系统遍历）、`Deleter`（删除，支持 trash/永久，删除后验证）、`ProcessRunner`（异步 shell 执行）、`ExclusionManager`（排除规则持久化与过滤）、`PermissionDiagnostic`（FDA/目录权限探测）。

**删除验证**: `CleanupReport` 跟踪 `expectedSize`/`actualFreed` 差异，`FailedItem` 按 `FailureReason`（permissionDenied/fileInUse/notFound/diskFull/unknown）分类。`Deleter` 删除前检查文件存在性，删除后 stat 确认。

**排除规则**: `ExclusionRule` 支持路径 glob、最近 N 天、最小大小、永久保留四种类型，持久化到 `~/Library/Application Support/MacCleaner/exclusions.json`。

**清理方案**: `CleaningProfile` 定义模块组合 + 风险过滤策略，内置 4 个方案（开发环境瘦身/发版前清理/仅安全项/日志清理）。`ProfileManager` 持久化用户自定义方案。CLI 支持 `--profile` 参数。

**定时扫描**: `ScheduledScanService` 后台周期扫描 + `UserNotifications` 低磁盘通知。`MenuBarViewModel` 展示可回收空间。

**用户规则包**: `RulesProvider` 加载 `~/.config/maccleaner/rules.d/*.json`，用户规则优先级最高。

### CLI Layer (`Sources/MacCleanerCLI/`)

三个子命令（`scan`, `clean`, `list`）+ 默认 `InteractiveCommand`（TUI 箭头键选择列表）。TUI 组件：`ANSIStyle`、`SelectionList`、`TableRenderer`、`ProgressBar`、`ConfirmationPrompt`。

### App Layer (`Sources/MacCleanerApp/`)

SwiftUI macOS 14+ 应用，使用 `@Observable` ViewModels：
- **ScanViewModel**: 状态机 idle → scanning → done/failed
- **ResultsViewModel**: 管理选择状态，`.destructive` 项勾选时触发二次确认弹窗
- **CleanupViewModel**: 删除进度和结果

App 流程: FDA 权限检查 → 模块选择 → 扫描 → 结果展示（sidebar + detail）→ 确认 → 执行删除。

## Key Conventions

- 所有 UI 字符串使用简体中文
- Models 是不可变值类型（`struct`），`Sendable` 协议
- `ShellExecutor` 协议抽象 shell 命令，测试中注入 `MockShellExecutor`
- 测试使用 Swift Testing 框架（`import Testing`, `@Test`, `#expect`）
- macOS 14+ 最低版本，App Sandbox 启用（需用户开启完全磁盘访问）

## Xcode 项目配置

App 的 entitlements 和 Info.plist 在 `MacCleanerApp/` 目录。需在 Xcode 中：
1. 创建 macOS App target，添加本地 SPM 包
2. 链接 `MacCleanerCore` library
3. 配置 code signing 和 sandbox entitlements
