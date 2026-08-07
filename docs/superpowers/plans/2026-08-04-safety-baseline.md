# MacCleaner P0 安全基线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在接入 AI 前先消除错误选择、越界删除、扫描后目标变化、进程 PID 复用和排除规则不一致等风险，确保 AI 结果永远不能绕过本地安全边界。

**Architecture:** 扫描阶段记录不可变的文件/进程身份，执行阶段由 Core 中的 guard 重新解析并比对；App、CLI、定时扫描统一经过同一个结果过滤器。AI 不参与本计划中的任何放行判断。

**Tech Stack:** Swift 5.9、macOS 14、Swift Testing、Foundation、Darwin、SwiftUI、XcodeGen。

**Design:** `docs/superpowers/specs/2026-08-04-ai-assessment-and-search-design.md`

## Global Constraints

- 不自动勾选任何清理项；“全选”也必须排除本地 guard 判定为不可执行的目标。
- `Deleter` 和进程终止服务只接受扫描时已经生成的目标，不接受 AI 返回的路径或 PID。
- 删除前必须同时验证允许根目录、规范化路径、对象类型以及设备号与 inode。
- 遇到符号链接、目标身份变化、根目录过宽、受保护 PID 或无法确认身份时，一律拒绝执行。
- 每个提交只包含该任务列出的文件；仓库中已有未提交修改不纳入提交。
- 本计划完成后，再执行 AI Core、App AI 迁移和扫描搜索优化计划。

## File Structure Map

```text
Sources/MacCleanerCore/
├── Models/
│   ├── CleanableItem.swift                 # 增加扫描时文件身份
│   ├── CleanupReport.swift                 # 增加安全拒绝原因
│   ├── FileIdentity.swift                  # 新增文件对象身份
│   └── ProcessInfo.swift                   # 增加进程执行身份
├── Modules/
│   ├── DockerModule.swift                  # 不再把 contexts 当缓存
│   └── SystemLogsModule.swift              # 精确返回非 Retired 子项
├── Services/
│   ├── AppUninstallerService.swift         # 精确残留匹配
│   ├── Deleter.swift                       # 接入删除 guard
│   ├── DeletionGuard.swift                 # 新增路径与身份验证
│   ├── DeletionPolicyCatalog.swift         # 新增模块允许根目录策略
│   ├── ExclusionManager.swift              # 保持规则来源
│   ├── FileIdentityProvider.swift          # 新增 lstat 实现
│   ├── ProcessFetcher.swift                # 获取真实可执行文件路径
│   ├── ProcessTerminationGuard.swift       # 新增 PID 身份验证
│   ├── ScanResultFilter.swift              # 新增统一排除过滤器
│   └── ScheduledScanService.swift          # 使用统一过滤器
Sources/MacCleanerApp/Features/
├── Results/ResultsViewModel.swift          # 初始不选中
└── Scan/ScanViewModel.swift                # 使用统一过滤器
Sources/MacCleanerCLI/Commands/
├── CleanCommand.swift                      # 清理前使用统一过滤器
└── ScanCommand.swift                       # 输出过滤后的结果
Tests/MacCleanerTests/
├── Models/CleanupSelectionPolicyTests.swift
├── Modules/DockerModuleTests.swift
├── Modules/SystemLogsModuleTests.swift
└── Services/
    ├── AppUninstallerResidualMatcherTests.swift
    ├── DeletionGuardTests.swift
    ├── DeletionPolicyCatalogTests.swift
    ├── DeleterTests.swift
    ├── ProcessTerminationGuardTests.swift
    └── ScanResultFilterTests.swift
```

---

### Task 1: 将默认选择改为显式空集合

**Files:**
- Create: `Sources/MacCleanerCore/Models/CleanupSelectionPolicy.swift`
- Modify: `Sources/MacCleanerApp/Features/Results/ResultsViewModel.swift`
- Modify: `Sources/MacCleanerApp/Features/Results/ResultsView.swift`
- Create: `Tests/MacCleanerTests/Models/CleanupSelectionPolicyTests.swift`

- [ ] **Step 1: 写出失败测试**

```swift
import Testing
@testable import MacCleanerCore

@Suite("Cleanup selection policy")
struct CleanupSelectionPolicyTests {
    @Test("初始状态不选择任何项")
    func initialSelectionIsEmpty() {
        let items = [
            CleanableItem(
                path: "/tmp/a",
                displayName: "a",
                size: 10,
                category: .developerCaches
            ),
            CleanableItem(
                path: "/tmp/b",
                displayName: "b",
                size: 20,
                category: .systemLogs
            ),
        ]

        #expect(CleanupSelectionPolicy.initialSelection(from: items).isEmpty)
    }

    @Test("用户点击全选才返回可执行项")
    func explicitSelectAllUsesEligibility() {
        let items = [
            CleanableItem(
                path: "/tmp/a",
                displayName: "a",
                size: 10,
                category: .developerCaches
            ),
            CleanableItem(
                path: "/",
                displayName: "root",
                size: 20,
                category: .systemLogs
            ),
        ]

        let ids = CleanupSelectionPolicy.selectAll(
            from: items,
            isEligible: { $0.path != "/" }
        )

        #expect(ids == Set([items[0].id]))
    }
}
```

- [ ] **Step 2: 运行测试并确认因类型不存在而失败**

Run: `swift test --filter CleanupSelectionPolicyTests`

Expected: 编译失败，提示找不到 `CleanupSelectionPolicy`。

- [ ] **Step 3: 实现无副作用的选择策略**

```swift
public enum CleanupSelectionPolicy {
    public static func initialSelection(from items: [CleanableItem]) -> Set<UUID> {
        []
    }

    public static func selectAll(
        from items: [CleanableItem],
        isEligible: (CleanableItem) -> Bool
    ) -> Set<UUID> {
        Set(items.lazy.filter(isEligible).map(\.id))
    }
}
```

在 `ResultsViewModel.init` 中只调用 `initialSelection`。将“选择推荐项”改为“全选可清理项”，并确保它只在用户点击后调用 `selectAll`。

- [ ] **Step 4: 验证测试与 App 编译**

Run: `swift test --filter CleanupSelectionPolicyTests`

Expected: 2 tests passed。

Run: `xcodebuild -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
git add Sources/MacCleanerCore/Models/CleanupSelectionPolicy.swift \
  Sources/MacCleanerApp/Features/Results/ResultsViewModel.swift \
  Sources/MacCleanerApp/Features/Results/ResultsView.swift \
  Tests/MacCleanerTests/Models/CleanupSelectionPolicyTests.swift
git commit -m "App: require explicit cleanup selection"
```

### Task 2: 记录并验证文件对象身份

**Files:**
- Create: `Sources/MacCleanerCore/Models/FileIdentity.swift`
- Create: `Sources/MacCleanerCore/Services/FileIdentityProvider.swift`
- Create: `Sources/MacCleanerCore/Services/DeletionGuard.swift`
- Create: `Sources/MacCleanerCore/Services/DeletionPolicyCatalog.swift`
- Modify: `Sources/MacCleanerCore/Models/CleanableItem.swift`
- Modify: `Sources/MacCleanerCore/Models/CleanupReport.swift`
- Modify: `Sources/MacCleanerCore/Services/Deleter.swift`
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
- Create: `Tests/MacCleanerTests/Services/DeletionGuardTests.swift`
- Create: `Tests/MacCleanerTests/Services/DeletionPolicyCatalogTests.swift`
- Modify: `Tests/MacCleanerTests/Services/DeleterTests.swift`
- Modify: `Tests/MacCleanerTests/Modules/ModuleSemanticTests.swift`

- [ ] **Step 1: 写出路径、符号链接与身份变化的失败测试**

```swift
import Foundation
import Testing
@testable import MacCleanerCore

@Suite("Deletion guard")
struct DeletionGuardTests {
    @Test("拒绝根目录和用户主目录")
    func rejectsBroadRoots() throws {
        let provider = StubFileIdentityProvider()
        let guardrail = DeletionGuard(
            allowedRoots: ["/Users/test/Library/Caches"],
            identityProvider: provider,
            protectedExactPaths: ["/", "/Users/test"],
            protectedSubtrees: ["/System", "/usr/bin", "/usr/lib", "/bin", "/sbin"]
        )

        #expect(throws: DeletionGuardError.self) {
            try guardrail.validate(path: "/", expectedIdentity: nil)
        }
        #expect(throws: DeletionGuardError.self) {
            try guardrail.validate(path: "/Users/test", expectedIdentity: nil)
        }
    }

    @Test("拒绝扫描后 inode 已变化的目标")
    func rejectsChangedIdentity() throws {
        let old = FileIdentity(device: 1, inode: 10, kind: .regularFile)
        let current = FileIdentity(device: 1, inode: 11, kind: .regularFile)
        let provider = StubFileIdentityProvider(identity: current)
        let guardrail = DeletionGuard(
            allowedRoots: ["/tmp/mac-cleaner-tests"],
            identityProvider: provider,
            protectedExactPaths: ["/"],
            protectedSubtrees: ["/System", "/usr/bin", "/usr/lib", "/bin", "/sbin"]
        )

        #expect(throws: DeletionGuardError.identityChanged) {
            try guardrail.validate(
                path: "/tmp/mac-cleaner-tests/cache.bin",
                expectedIdentity: old
            )
        }
    }

    @Test("拒绝最终路径为符号链接")
    func rejectsSymbolicLink() throws {
        let provider = StubFileIdentityProvider(
            identity: FileIdentity(device: 1, inode: 10, kind: .symbolicLink)
        )
        let guardrail = DeletionGuard(
            allowedRoots: ["/tmp/mac-cleaner-tests"],
            identityProvider: provider,
            protectedExactPaths: ["/"],
            protectedSubtrees: ["/System", "/usr/bin", "/usr/lib", "/bin", "/sbin"]
        )

        #expect(throws: DeletionGuardError.symbolicLink) {
            try guardrail.validate(
                path: "/tmp/mac-cleaner-tests/link",
                expectedIdentity: nil
            )
        }
    }
}
```

测试桩完整实现 `FileIdentityProviding` 的 `identity(at:)`、`canonicalParent(of:)` 和 `exists(at:)`，所有返回值由初始化参数确定，避免触碰真实文件系统。

- [ ] **Step 2: 运行测试并确认失败**

Run: `swift test --filter DeletionGuardTests`

Expected: 编译失败，提示缺少文件身份与 guard 类型。

- [ ] **Step 3: 定义文件身份和提供器协议**

```swift
public enum FileObjectKind: String, Codable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

public struct FileIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let kind: FileObjectKind
}

public protocol FileIdentityProviding: Sendable {
    func exists(at path: String) -> Bool
    func identity(at path: String) throws -> FileIdentity
    func canonicalParent(of path: String) throws -> String
}
```

`POSIXFileIdentityProvider` 使用 `lstat` 获取 `st_dev`、`st_ino` 和对象类型；只对父目录执行 `realpath`，不跟随最终目标的符号链接。

- [ ] **Step 4: 实现拒绝优先的删除 guard**

```swift
public enum DeletionGuardError: Error, Equatable {
    case targetMissing
    case outsideAllowedRoots
    case protectedRoot
    case symbolicLink
    case identityUnavailable
    case identityChanged
}

public struct DeletionGuard: Sendable {
    public func validate(
        path: String,
        expectedIdentity: FileIdentity?
    ) throws -> FileIdentity {
        guard identityProvider.exists(at: path) else {
            throw DeletionGuardError.targetMissing
        }

        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let canonicalParent = try identityProvider.canonicalParent(of: standardized)
        let canonicalPath = (canonicalParent as NSString)
            .appendingPathComponent((standardized as NSString).lastPathComponent)

        guard !protectedExactPaths.contains(canonicalPath) else {
            throw DeletionGuardError.protectedRoot
        }
        guard !protectedSubtrees.contains(where: { Self.contains($0, path: canonicalPath) }) else {
            throw DeletionGuardError.protectedRoot
        }
        guard allowedRoots.contains(where: { Self.contains($0, path: canonicalPath) }) else {
            throw DeletionGuardError.outsideAllowedRoots
        }

        let current = try identityProvider.identity(at: canonicalPath)
        guard current.kind != .symbolicLink else {
            throw DeletionGuardError.symbolicLink
        }
        guard let expectedIdentity else {
            throw DeletionGuardError.identityUnavailable
        }
        guard current == expectedIdentity else {
            throw DeletionGuardError.identityChanged
        }
        return current
    }

    private static func contains(_ root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
```

根目录判断必须按路径组件边界比较：`/Users/a/Library/Caches2` 不能命中 `/Users/a/Library/Caches`。`protectedExactPaths` 只拒绝目标本身；`protectedSubtrees` 拒绝目录及全部后代，避免把 `/` 作为 subtree 后误拒绝所有绝对路径。

- [ ] **Step 5: 定义每个模块的允许根目录策略**

```swift
public struct DeletionPolicy: Sendable {
    public let allowedRoots: [String]
    public let protectedExactPaths: [String]
    public let protectedSubtrees: [String]
}

public protocol DeletionPolicyProviding: Sendable {
    func policy(for module: ModuleIdentifier) -> DeletionPolicy
}
```

生产 catalog 的允许根目录如下；路径从注入的 home 和 developer directory 生成，不读取 AI 输出：

| 模块 | 允许根目录 |
|---|---|
| developerCaches | `.gradle/caches`、`.gradle/daemon`、`.gradle/wrapper/dists`、`.m2/repository`、`.npm`、`Library/Caches/Yarn`、`Library/pnpm`、`Library/Caches/pnpm`、`.cocoapods`、`.pub-cache`、`Library/Caches/Homebrew`、`/usr/local/Cellar`、`/opt/homebrew/Cellar`、`.cargo/registry/cache`、`.cargo/registry/src`、`.cargo/git/db`、`go/pkg/mod/cache`、`.cache/pip`、`Library/Caches/org.swift.swiftpm` |
| iosSimulators | `Library/Developer/CoreSimulator/Devices`、`Library/Developer/CoreSimulator/Profiles/Runtimes` |
| xcode | `Library/Developer/Xcode/DerivedData`、`Archives`、`iOS DeviceSupport`、`watchOS DeviceSupport`、`Library/Developer/CoreSimulator/Caches` |
| aiToolCaches | 直接复用 `AIToolCachesModule` 的 typed target manifest 中每一条 `cachePaths` 与用户数据候选 `dataPaths`；manifest 是扫描与执行的唯一根目录来源，不能由 AI 或响应内容扩展 |
| applicationCaches | `Library/Caches` |
| docker | `Library/Containers/com.docker.docker/Data` 与 `.docker/buildx`，不包含 `.docker/contexts` |
| systemLogs | `Library/Logs` 与 `Library/Logs/DiagnosticReports` |
| androidSDK | `.gradle/caches`、`.android/avd` 与 Android SDK 中模块明确识别的旧版本目录 |
| largeFiles、duplicateFiles | 用户 home 后代；home 本身仍在 `protectedExactPaths` 中 |

所有 policy 的 `protectedExactPaths` 至少含 `/` 和 home，`protectedSubtrees` 至少含 `/System`、`/usr/bin`、`/usr/lib`、`/usr/sbin`、`/usr/share`、`/bin`、`/sbin`、`/private/var/db`。保留 `/usr/local/Cellar` 这一明确 Homebrew 根，不把整个 `/usr` 放入 protected subtree。catalog 测试逐模块断言 allowed roots 非空、不含 `/`，并验证 Docker contexts 不在任何允许根中。

- [ ] **Step 6: 让全部扫描模块记录身份**

`CleanableItem` 增加可选 `fileIdentity` 参数；每个模块在生成候选的同一时刻通过注入的 `FileIdentityProviding.identity(at:)` 记录 device、inode 和对象类型。`ModuleSemanticTests` 遍历所有 fixture 扫描结果，断言每个存在的候选都有身份。身份获取失败的候选可以展示，但必须标记 `fileIdentity == nil`，后续 guard 拒绝执行。

- [ ] **Step 7: 将 guard 和 policy catalog 注入 `Deleter` 并映射报告原因**

`CleanupReport.FailureReason` 增加：

```swift
case unsafeTarget
case identityChanged
case identityUnavailable
```

`Deleter` 根据调用参数 `module` 从 catalog 取 policy，再在所有 `trashItem` 或 `removeItem` 前调用同一个 `DeletionGuard.validate`。验证失败只记录 `FailedItem`，不得尝试降级删除。AI 层没有 policy catalog 的写入口。

- [ ] **Step 8: 运行针对性测试**

Run: `swift test --filter 'DeletionGuardTests|DeletionPolicyCatalogTests|DeleterTests|ModuleSemanticTests'`

Expected: guard 和 deleter 测试全部通过；dry-run 测试确认文件仍存在。

- [ ] **Step 9: 提交**

```bash
git add Sources/MacCleanerCore/Models/FileIdentity.swift \
  Sources/MacCleanerCore/Models/CleanableItem.swift \
  Sources/MacCleanerCore/Models/CleanupReport.swift \
  Sources/MacCleanerCore/Services/FileIdentityProvider.swift \
  Sources/MacCleanerCore/Services/DeletionGuard.swift \
  Sources/MacCleanerCore/Services/DeletionPolicyCatalog.swift \
  Sources/MacCleanerCore/Services/Deleter.swift \
  Sources/MacCleanerCore/Modules/AIToolCachesModule.swift \
  Sources/MacCleanerCore/Modules/AndroidSDKModule.swift \
  Sources/MacCleanerCore/Modules/ApplicationCachesModule.swift \
  Sources/MacCleanerCore/Modules/DeveloperCachesModule.swift \
  Sources/MacCleanerCore/Modules/DockerModule.swift \
  Sources/MacCleanerCore/Modules/DuplicateFilesModule.swift \
  Sources/MacCleanerCore/Modules/IOSSimulatorsModule.swift \
  Sources/MacCleanerCore/Modules/LargeFileScannerModule.swift \
  Sources/MacCleanerCore/Modules/SystemLogsModule.swift \
  Sources/MacCleanerCore/Modules/XcodeModule.swift \
  Tests/MacCleanerTests/Services/DeletionGuardTests.swift \
  Tests/MacCleanerTests/Services/DeletionPolicyCatalogTests.swift \
  Tests/MacCleanerTests/Modules/ModuleSemanticTests.swift \
  Tests/MacCleanerTests/Services/DeleterTests.swift
git commit -m "Core: validate cleanup targets before deletion"
```

### Task 3: 修正系统日志和 Docker 的越界候选

**Files:**
- Modify: `Sources/MacCleanerCore/Modules/SystemLogsModule.swift`
- Modify: `Sources/MacCleanerCore/Modules/DockerModule.swift`
- Modify: `Tests/MacCleanerTests/Modules/SystemLogsModuleTests.swift`
- Modify: `Tests/MacCleanerTests/Modules/DockerModuleTests.swift`

- [ ] **Step 1: 写出两个回归测试**

```swift
@Test("诊断报告只返回非 Retired 的直接子项")
func diagnosticReportsPreserveRetired() async throws {
    let home = try TemporaryHome.fixture(
        files: [
            "Library/Logs/DiagnosticReports/a.crash": "a",
            "Library/Logs/DiagnosticReports/Retired/old.crash": "old",
        ]
    )
    let result = try await SystemLogsModule(homeDirectory: home.url).scan()
    let paths = Set(result.items.map(\.path))

    #expect(paths.contains(home.path("Library/Logs/DiagnosticReports/a.crash")))
    #expect(!paths.contains(home.path("Library/Logs/DiagnosticReports")))
    #expect(!paths.contains(home.path("Library/Logs/DiagnosticReports/Retired")))
}

@Test("Docker contexts 不作为缓存候选")
func excludesDockerContexts() async throws {
    let home = try TemporaryHome.fixture(
        files: [
            ".docker/buildx/cache.db": "cache",
            ".docker/contexts/meta/ctx/meta.json": "context",
        ]
    )
    let result = try await DockerModule(homeDirectory: home.url).scan()
    let paths = Set(result.items.map(\.path))

    #expect(paths.contains(home.path(".docker/buildx")))
    #expect(!paths.contains(home.path(".docker/contexts")))
}
```

- [ ] **Step 2: 运行并确认当前实现失败**

Run: `swift test --filter 'SystemLogsModuleTests|DockerModuleTests'`

Expected: 诊断报告测试发现父目录被返回；Docker 测试发现 `contexts` 被返回。

- [ ] **Step 3: 精确修正候选生成**

`SystemLogsModule` 枚举 `DiagnosticReports` 的直接子项，跳过名称为 `Retired` 的目录，每个子项单独生成 `CleanableItem`。`DockerModule` 的 `buildCachePaths` 只保留已确认的构建缓存目录，删除 `~/.docker/contexts`。两个模块均通过构造参数注入 home，生产默认值仍是 `FileManager.default.homeDirectoryForCurrentUser`。

- [ ] **Step 4: 验证**

Run: `swift test --filter 'SystemLogsModuleTests|DockerModuleTests'`

Expected: 两组测试全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/MacCleanerCore/Modules/SystemLogsModule.swift \
  Sources/MacCleanerCore/Modules/DockerModule.swift \
  Tests/MacCleanerTests/Modules/SystemLogsModuleTests.swift \
  Tests/MacCleanerTests/Modules/DockerModuleTests.swift
git commit -m "Core: narrow log and Docker cleanup targets"
```

### Task 4: 将应用残留匹配从子串改为身份边界

**Files:**
- Create: `Sources/MacCleanerCore/Services/AppResidualMatcher.swift`
- Modify: `Sources/MacCleanerCore/Models/InstalledApp.swift`
- Modify: `Sources/MacCleanerCore/Models/AppResidualFiles.swift`
- Modify: `Sources/MacCleanerCore/Services/AppUninstallerService.swift`
- Modify: `Sources/MacCleanerApp/Features/AppUninstaller/AppUninstallerViewModel.swift`
- Modify: `Sources/MacCleanerApp/Features/AppUninstaller/AppUninstallerView.swift`
- Create: `Tests/MacCleanerTests/Services/AppUninstallerResidualMatcherTests.swift`

- [ ] **Step 1: 写出真假阳性测试**

```swift
@Suite("App residual matcher")
struct AppUninstallerResidualMatcherTests {
    @Test(arguments: [
        ("com.acme.notes.plist", "com.acme.notes", true),
        ("com.acme.notes.helper.plist", "com.acme.notes", true),
        ("com.acme.notes-backup.plist", "com.acme.notes", true),
        ("com.acme.notesplus.plist", "com.acme.notes", false),
        ("org.example.com.acme.notes.plist", "com.acme.notes", false),
    ])
    func bundleBoundary(candidate: String, bundleID: String, expected: Bool) {
        #expect(AppResidualMatcher.matchesFilename(candidate, bundleID: bundleID) == expected)
    }

    @Test("普通 App 名称不使用 contains")
    func appNameDoesNotMatchUnrelatedName() {
        #expect(!AppResidualMatcher.matchesAppNameFilename("NotesBackup.plist", appName: "Notes"))
        #expect(AppResidualMatcher.matchesAppNameFilename("Notes.plist", appName: "Notes"))
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter AppUninstallerResidualMatcherTests`

Expected: 编译失败，提示缺少 `AppResidualMatcher`。

- [ ] **Step 3: 实现边界匹配**

```swift
public enum AppResidualMatcher {
    private static let separators = CharacterSet(charactersIn: ".-_ ")

    public static func matchesFilename(_ filename: String, bundleID: String) -> Bool {
        matchesStem((filename as NSString).deletingPathExtension, token: bundleID)
    }

    public static func matchesAppNameFilename(_ filename: String, appName: String) -> Bool {
        (filename as NSString).deletingPathExtension
            .localizedCaseInsensitiveCompare(appName) == .orderedSame
    }

    private static func matchesStem(_ stem: String, token: String) -> Bool {
        guard stem.hasPrefix(token) else { return false }
        guard stem.count > token.count else { return true }
        let boundary = stem.index(stem.startIndex, offsetBy: token.count)
        return stem[boundary].unicodeScalars.allSatisfy(separators.contains)
    }
}
```

LaunchAgent/LaunchDaemon 先解析 plist 的 `Label`、`Program`、`ProgramArguments`；只有 bundle ID 边界匹配或程序路径位于 app bundle 内时才返回。崩溃报告只接受精确 app 名 stem 或 bundle ID 边界，不使用任意位置子串。

- [ ] **Step 4: 为 App 和每个残留记录扫描身份**

`InstalledApp` 与 `ResidualItem` 增加 `fileIdentity`。`scanApplications` 和 `probeLocation` 在创建值对象时用 P0 `FileIdentityProviding` 记录身份。身份缺失的条目仍可展示，但卸载确认页禁用该条目的选择并说明“无法验证文件身份”。

卸载执行使用专用 `DeletionPolicy`：App bundle 只允许 `/Applications` 与 `~/Applications` 的直接 `.app` 子项；残留只允许本任务列出的 Application Support、Preferences、Caches、Logs、LaunchAgents、LaunchDaemons、Saved Application State、Containers、Group Containers、Application Scripts、HTTPStorages、WebKit 和 DiagnosticReports 根目录。目标必须同时满足发现时 identity 与执行时 identity 一致。

- [ ] **Step 5: 修正移入废纸篓的空间文案**

把 `UninstallReport.bytesFreed` 改为 `bytesMovedToTrash`。App 和残留移动成功后只累计“已移入废纸篓的大小”，UI 不再声称空间已经释放；实际释放需等用户清空废纸篓。

- [ ] **Step 6: 验证残留发现与删除入口**

Run: `swift test --filter 'AppUninstallerResidualMatcherTests|DeleterTests'`

Expected: 全部通过；新增身份变化测试断言 App 或残留在扫描后被替换时不会进入废纸篓。

- [ ] **Step 7: 提交**

```bash
git add Sources/MacCleanerCore/Services/AppResidualMatcher.swift \
  Sources/MacCleanerCore/Models/InstalledApp.swift \
  Sources/MacCleanerCore/Models/AppResidualFiles.swift \
  Sources/MacCleanerCore/Services/AppUninstallerService.swift \
  Sources/MacCleanerApp/Features/AppUninstaller/AppUninstallerViewModel.swift \
  Sources/MacCleanerApp/Features/AppUninstaller/AppUninstallerView.swift \
  Tests/MacCleanerTests/Services/AppUninstallerResidualMatcherTests.swift
git commit -m "Core: match app residuals by identity boundary"
```

### Task 5: 统一 App、CLI 和定时扫描的排除规则

**Files:**
- Create: `Sources/MacCleanerCore/Services/ScanResultFilter.swift`
- Modify: `Sources/MacCleanerApp/Features/Scan/ScanViewModel.swift`
- Modify: `Sources/MacCleanerCLI/Commands/ScanCommand.swift`
- Modify: `Sources/MacCleanerCLI/Commands/CleanCommand.swift`
- Modify: `Sources/MacCleanerCore/Services/ScheduledScanService.swift`
- Create: `Tests/MacCleanerTests/Services/ScanResultFilterTests.swift`
- Modify: `Tests/MacCleanerTests/Services/ScheduledScanTests.swift`

- [ ] **Step 1: 写出跨入口一致性测试**

```swift
@Test("过滤器保持模块信息并删除排除项")
func filtersExcludedItems() async {
    let manager = InMemoryExclusionManager(excludedPaths: ["/tmp/cache/keep"])
    let filter = ScanResultFilter(exclusionManager: manager)
    let result = ScanResult(
        module: .applicationCaches,
        items: [
            CleanableItem(
                path: "/tmp/cache/delete",
                displayName: "delete",
                size: 10,
                category: .applicationCaches
            ),
            CleanableItem(
                path: "/tmp/cache/keep",
                displayName: "keep",
                size: 20,
                category: .applicationCaches
            ),
        ],
        scanDuration: 0
    )

    let filtered = await filter.apply(to: result)

    #expect(filtered.module == result.module)
    #expect(filtered.items.map(\.path) == ["/tmp/cache/delete"])
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter ScanResultFilterTests`

Expected: 编译失败，提示缺少 `ScanResultFilter`。

- [ ] **Step 3: 实现唯一过滤入口**

```swift
public struct ScanResultFilter: Sendable {
    private let exclusionManager: any ExclusionManaging

    public init(exclusionManager: any ExclusionManaging) {
        self.exclusionManager = exclusionManager
    }

    public func apply(to result: ScanResult) async -> ScanResult {
        var items: [CleanableItem] = []
        for item in result.items {
            if !(await exclusionManager.isExcluded(path: item.path)) {
                items.append(item)
            }
        }
        return ScanResult(
            module: result.module,
            items: items,
            scanDuration: result.scanDuration
        )
    }
}
```

为现有 `ExclusionManager` 增加 `ExclusionManaging` 协议；App 扫描、CLI scan/clean 和 `ScheduledScanService` 都在模块结果产生后立即调用该过滤器，执行层不再各自复制路径判断。

- [ ] **Step 4: 验证所有入口**

Run: `swift test --filter 'ScanResultFilterTests|ScheduledScanTests'`

Expected: 全部通过，定时扫描的总大小不包含排除路径。

Run: `swift run mac-cleaner scan --json`

Expected: 输出合法 JSON，且用户排除路径不在 items 中。

- [ ] **Step 5: 提交**

```bash
git add Sources/MacCleanerCore/Services/ScanResultFilter.swift \
  Sources/MacCleanerCore/Services/ExclusionManager.swift \
  Sources/MacCleanerCore/Services/ScheduledScanService.swift \
  Sources/MacCleanerApp/Features/Scan/ScanViewModel.swift \
  Sources/MacCleanerCLI/Commands/ScanCommand.swift \
  Sources/MacCleanerCLI/Commands/CleanCommand.swift \
  Tests/MacCleanerTests/Services/ScanResultFilterTests.swift \
  Tests/MacCleanerTests/Services/ScheduledScanTests.swift
git commit -m "Core: apply exclusions across all scan entry points"
```

### Task 6: 在结束进程前验证真实可执行身份

**Files:**
- Modify: `Sources/MacCleanerCore/Models/ProcessInfo.swift`
- Modify: `Sources/MacCleanerCore/Services/ProcessFetcher.swift`
- Create: `Sources/MacCleanerCore/Services/ProcessExecutableResolver.swift`
- Create: `Sources/MacCleanerCore/Services/ProcessTerminationGuard.swift`
- Modify: `Tests/MacCleanerTests/Services/ProcessFetcherTests.swift`
- Create: `Tests/MacCleanerTests/Services/ProcessTerminationGuardTests.swift`

- [ ] **Step 1: 写出 PID 复用与受保护进程测试**

```swift
@Suite("Process termination guard")
struct ProcessTerminationGuardTests {
    @Test("拒绝 PID 1、自身和 helper")
    func rejectsProtectedProcesses() async {
        let guardrail = ProcessTerminationGuard(
            currentPID: 300,
            helperBundleIdentifiers: ["com.maccleaner.helper"],
            resolver: StubProcessResolver()
        )

        #expect(await guardrail.validate(.fixture(pid: 1)) == .protectedProcess)
        #expect(await guardrail.validate(.fixture(pid: 300)) == .protectedProcess)
        #expect(await guardrail.validate(.fixture(bundleID: "com.maccleaner.helper")) == .protectedProcess)
    }

    @Test("拒绝 PID 相同但可执行路径或启动时间变化")
    func rejectsReusedPID() async {
        let scanned = ProcessIdentity(pid: 99, executablePath: "/Applications/A.app/A", startTimeTicks: 10)
        let resolver = StubProcessResolver(
            identity: ProcessIdentity(pid: 99, executablePath: "/Applications/B.app/B", startTimeTicks: 11)
        )
        let guardrail = ProcessTerminationGuard(
            currentPID: 300,
            helperBundleIdentifiers: [],
            resolver: resolver
        )

        #expect(await guardrail.validate(scanned) == .identityChanged)
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter ProcessTerminationGuardTests`

Expected: 编译失败，提示缺少身份和 guard 类型。

- [ ] **Step 3: 实现 resolver 与身份模型**

```swift
public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let startTimeTicks: UInt64
    public let bundleIdentifier: String?
}

public protocol ProcessExecutableResolving: Sendable {
    func identity(for pid: Int32) async throws -> ProcessIdentity
}
```

Darwin 实现用 `proc_pidpath` 获取完整绝对路径，并从 `proc_pidinfo` 获取启动时间字段；`ProcessFetcher` 不再把 `ps comm` 中带参数的字符串当可执行路径。无法解析时保留原始命令名用于显示，但把进程标记为不可终止。

- [ ] **Step 4: 实现验证和信号发送分层**

`ProcessTerminationGuard.validate` 重新解析同一 PID，只在 `pid`、规范化可执行路径、启动时间均一致且不是受保护进程时返回 `.allowed`。实际 `kill` 通过 `ProcessSignalSending` 协议执行；guard 失败时不得发送 `SIGTERM` 或 `SIGKILL`。

- [ ] **Step 5: 修正 ProcessFetcher 测试并验证**

Run: `swift test --filter 'ProcessFetcherTests|ProcessTerminationGuardTests'`

Expected: 测试全部通过，所有可终止进程的 `executablePath` 都是绝对路径；带命令参数的 `ps` 文本不再被误判为路径。

- [ ] **Step 6: 提交**

```bash
git add Sources/MacCleanerCore/Models/ProcessInfo.swift \
  Sources/MacCleanerCore/Services/ProcessFetcher.swift \
  Sources/MacCleanerCore/Services/ProcessExecutableResolver.swift \
  Sources/MacCleanerCore/Services/ProcessTerminationGuard.swift \
  Tests/MacCleanerTests/Services/ProcessFetcherTests.swift \
  Tests/MacCleanerTests/Services/ProcessTerminationGuardTests.swift
git commit -m "Core: verify process identity before termination"
```

### Task 7: P0 总体验收

**Files:**
- Modify only if verification exposes a regression in files already touched by Tasks 1–6.

- [ ] **Step 1: 运行完整 Swift 测试**

Run: `swift test`

Expected: 所有 suite 通过，0 issues。

- [ ] **Step 2: 构建 App**

Run: `xcodegen generate`

Expected: `MacCleaner.xcodeproj` 成功生成。

Run: `xcodebuild -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 验证 CLI dry-run 不写文件**

Run: `swift run mac-cleaner clean --dry-run --all --yes`

Expected: 命令列出候选和拒绝原因，不移动或删除任何文件。

- [ ] **Step 4: 手工验证交互安全门槛**

启动 App 后确认：扫描完成时 0 项被选中；未选择时清理按钮不可执行；点击全选只选择 guard 可执行项；目标被替换、改成符号链接或移动后，执行时显示本地安全拒绝，而不是继续删除。

- [ ] **Step 5: 检查提交边界**

Run: `git status --short`

Expected: 只显示用户原有未提交修改；本计划文件和本计划的实现提交均已落库。
