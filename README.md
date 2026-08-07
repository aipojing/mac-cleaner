# DevClean

DevClean 是一个面向 macOS 开发者场景的磁盘清理工具，提供 **SwiftUI 桌面应用** 和 **CLI** 两个入口。项目当前聚焦开发机器上最常见的空间占用来源，例如 Xcode 产物、iOS 模拟器、开发者缓存、AI 工具缓存、应用缓存和大文件。

当前品牌名已更新为 `DevClean`，但仓库内部的模块名、目录名和 CLI 命令仍暂时保留 `MacCleaner` / `mac-cleaner`，以降低重命名风险。

## 功能特性

- 扫描开发者缓存：Gradle、Maven、npm、Yarn、pnpm、CocoaPods、pub
- 扫描 Xcode 相关目录：DerivedData、Archives、DeviceSupport、CoreSimulator 缓存
- 扫描 iOS 模拟器运行时和设备数据
- 扫描 AI 工具与桌面客户端本地缓存
- 扫描 `~/Library/Caches` 下较大的应用缓存
- 扫描主目录下大于 `100MB` 的单个文件
- 按风险等级展示删除影响，并支持推荐项预选

## 项目结构

```text
Sources/
├── MacCleanerCore/   # 核心扫描、规则、模型、删除逻辑
├── MacCleanerCLI/    # CLI 命令与终端交互组件
└── MacCleanerApp/    # SwiftUI 桌面应用

Tests/MacCleanerTests/ # Swift Testing 测试
project.yml            # XcodeGen 配置
Package.swift          # Swift Package 配置
```

## 环境要求

- macOS 14+
- Xcode 16.4+ 或兼容 Swift 5.9 工具链
- 桌面应用建议授予“完全磁盘访问”权限，否则部分目录无法扫描或删除

## 本地运行

### CLI

```bash
swift build
swift run mac-cleaner
swift run mac-cleaner scan
swift run mac-cleaner scan --json
swift run mac-cleaner clean --dry-run --all --yes
swift test
```

### 桌面应用

仓库已包含 `MacCleaner.xcodeproj`。可直接用 Xcode 打开运行，或在修改 `project.yml` 后执行：

```bash
xcodegen generate
open MacCleaner.xcodeproj
```

## 设计说明

- `MacCleanerCore` 不依赖 UI 框架，供 CLI 和 App 共享
- 清理项通过 `CleanerModule` 抽象，统一实现 `scan()` 和 `clean()`
- 风险等级分为 `safe`、`moderate`、`destructive`
- 测试使用 Swift Testing：`@Suite`、`@Test`、`#expect`

## 当前状态

项目已经可以本地构建和运行，适合作为 macOS 清理工具的基础实现继续迭代。后续可以继续完善资源打包、删除边界和更细粒度的缓存识别策略。
