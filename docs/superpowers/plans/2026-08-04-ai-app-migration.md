# MacCleaner App AI Judgment Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用显式 DeepSeek 分析与本地缓存展示替换 App 内所有静态风险/推荐判断，同时保持扫描结果默认不选、用户主动触发 AI、用户最终执行以及 Core 本地安全 guard 四条边界。

**Architecture:** 扫描器和进程服务只生产可验证的原始事实；App 的 composition root 注入 AI coordinator、Keychain 与 consent store；Results 和 Activity Monitor 各自维护按 fingerprint 索引的 AI 状态。缓存读取自动发生但不联网，缓存缺失只有用户点击后才调用 DeepSeek。

**Tech Stack:** Swift 5.9、SwiftUI、Observation、Swift Concurrency、Swift Testing、XcodeGen、MacCleanerCore AI Assessment Core。

**Design:** `docs/superpowers/specs/2026-08-04-ai-assessment-and-search-design.md`

## Global Constraints

- 开始本计划前必须完成 `2026-08-04-safety-baseline.md` 和 `2026-08-04-ai-assessment-core.md`。
- App 启动、扫描结束、切换模块、进程列表刷新和搜索输入都不得触发 AI 网络请求。
- 自动动作只允许“按 fingerprint 读取本地缓存并展示”；缓存缺失显示“未分析”和显式 AI 按钮。
- AI 的 `risk`、`recommendation` 与 `confidence` 不得修改 `selectedItemIDs`，也不得绕过 `DeletionGuard` 或 `ProcessTerminationGuard`。
- 第一版明确向用户说明会发送完整路径和进程元数据；不发送文件内容、环境变量、完整 argv。
- 不保留静态规则作为隐藏兜底。迁移完成后删除 `CleaningRules.json`、`ProcessDescriptions.json` 和所有规则推导类型。
- Core 的 `AIRiskLevel` 是 AI 输出；它不能替代本地 guard 的 allowed/rejected 结果。
- 每个提交只包含该任务列出的文件；仓库中已有未提交修改不纳入提交。

## File Structure Map

```text
project.yml                                      # 增加 App 单元测试 target
Sources/MacCleanerCore/
├── Models/
│   ├── CleanableItem.swift                     # 只保留事实与证据标签
│   ├── CleaningProfile.swift                   # 只保留模块组合
│   ├── ProcessInfo.swift                       # 只保留进程事实和身份
│   └── ScanResult.swift                        # 不再计算推荐节省
├── Services/
│   ├── AIAssessmentSubjectFactory.swift        # 事实 -> AI subject
│   ├── ProcessFetcher.swift                    # 删除静态描述推导
│   ├── RulesProvider.swift                     # 删除
│   └── ScheduledScanService.swift              # 候选空间，不做 AI 判断
├── Modules/*.swift                             # 输出 evidenceTags，不输出判断
└── Resources/
    ├── CleaningRules.json                      # 删除
    └── ProcessDescriptions.json                # 删除
Sources/MacCleanerApp/
├── App/
│   ├── AppEnvironment.swift                    # 新增依赖组合
│   └── MacCleanerApp.swift                     # 注入 environment
├── Components/
│   ├── AIAssessmentCard.swift                  # 新增统一 AI 展示
│   └── RiskBadge.swift                         # 删除旧静态 badge
├── Extensions/RiskLevel+UI.swift               # 删除
├── Features/Settings/
│   ├── AISettingsView.swift                    # 新增 Key、连接、隐私、缓存设置
│   ├── AISettingsViewModel.swift
│   ├── AIPrivacyConsentStore.swift              # 隐私说明版本状态
│   └── SettingsView.swift
├── Features/Results/
│   ├── ResultsViewModel.swift                  # 缓存加载与显式分析
│   ├── ResultsView.swift
│   └── ItemRowView.swift
└── Features/ActivityMonitor/
    ├── ActivityMonitorViewModel.swift          # 进程 AI 状态
    └── ActivityMonitorView.swift
Sources/MacCleanerCLI/
├── Commands/CleanCommand.swift                 # 不再按推荐过滤
├── Commands/InteractiveCommand.swift           # 默认不选择
└── TUI/SelectionList.swift                     # 显式选择
Tests/
├── MacCleanerTests/
│   ├── Models/CleanableItemEvidenceTests.swift
│   ├── Models/CleaningProfileTests.swift
│   └── Services/AIAssessmentSubjectFactoryTests.swift
└── MacCleanerAppTests/
    ├── AISettingsViewModelTests.swift
    ├── ActivityMonitorAIViewModelTests.swift
    └── ResultsAIViewModelTests.swift
```

---

### Task 1: 建立 App 可测试依赖组合

**Files:**
- Modify: `project.yml`
- Create: `Tests/MacCleanerAppTests/Support/AppAITestDoubles.swift`
- Create: `Sources/MacCleanerApp/App/AppEnvironment.swift`
- Create: `Sources/MacCleanerApp/Features/Settings/AIPrivacyConsentStore.swift`
- Modify: `Sources/MacCleanerApp/App/MacCleanerApp.swift`

- [ ] **Step 1: 在 XcodeGen 中增加 App 测试 target**

```yaml
  MacCleanerAppTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests/MacCleanerAppTests
    dependencies:
      - target: MacCleanerApp
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.maccleaner.app.tests
        SWIFT_VERSION: "5.9"
        GENERATE_INFOPLIST_FILE: true
```

- [ ] **Step 2: 生成工程并确认空测试 target 可构建**

Run: `xcodegen generate`

Expected: `MacCleaner.xcodeproj` 包含 `MacCleanerAppTests` target。

Run: `xcodebuild -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build-for-testing`

Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 3: 定义唯一 App 组合根**

```swift
@MainActor
final class AppEnvironment {
    let aiService: any AIAnalysisServing
    let subjectFactory: AIAssessmentSubjectFactory
    let apiKeyStore: any APIKeyManaging
    let privacyConsentStore: any AIPrivacyConsentStoring
    let connectionChecker: any DeepSeekConnectionChecking

    static func production() -> AppEnvironment {
        let keyStore = KeychainAPIKeyStore()
        let client = DeepSeekAssessmentClient(
            configuration: .production,
            keyStore: keyStore,
            transport: URLSessionHTTPTransport()
        )
        return AppEnvironment(
            aiService: AIAnalysisCoordinator(
                provider: client,
                cache: AIAssessmentCache()
            ),
            subjectFactory: AIAssessmentSubjectFactory(),
            apiKeyStore: keyStore,
            privacyConsentStore: UserDefaultsAIPrivacyConsentStore(),
            connectionChecker: client
        )
    }
}
```

App 层定义 `AIAnalysisServing`，只暴露 `state(for:)`、`states(for:)`、`analyze(_:forceRefresh:)` 和 `cancelCurrentAnalysis()`；`AIAnalysisCoordinator` 适配该协议。`MacCleanerApp` 只创建一次 production environment，并通过构造参数传给需要 AI 的 view model；Preview 和测试传入内存 doubles。

隐私 consent 使用版本化协议：

```swift
protocol AIPrivacyConsentStoring: Sendable {
    func acceptedVersion() async -> Int?
    func accept(version: Int) async
    func reset() async
}
```

生产实现使用独立 UserDefaults key `aiPrivacyConsentVersion`，不与 API Key 存在同一存储。

- [ ] **Step 4: 创建线程安全测试 doubles**

实现 `RecordingAIAnalysisCoordinator` 对应的协议抽象、`InMemoryAPIKeyStore`、`InMemoryAIPrivacyConsentStore` 和 `StubConnectionChecker`。Recording double 记录 `state`、`analyze`、`forceRefresh` 调用，供后续断言无自动网络请求。

- [ ] **Step 5: 提交**

```bash
git add project.yml MacCleaner.xcodeproj \
  Sources/MacCleanerApp/App/AppEnvironment.swift \
  Sources/MacCleanerApp/App/MacCleanerApp.swift \
  Sources/MacCleanerApp/Features/Settings/AIPrivacyConsentStore.swift \
  Tests/MacCleanerAppTests/Support/AppAITestDoubles.swift
git commit -m "App: add injectable AI environment"
```

### Task 2: 把清理项迁移为无判断的原始事实

**Files:**
- Modify: `Sources/MacCleanerCore/Models/CleanableItem.swift`
- Modify: `Sources/MacCleanerCore/Models/ScanResult.swift`
- Create: `Sources/MacCleanerCore/Services/AIAssessmentSubjectFactory.swift`
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
- Create: `Tests/MacCleanerTests/Models/CleanableItemEvidenceTests.swift`
- Create: `Tests/MacCleanerTests/Services/AIAssessmentSubjectFactoryTests.swift`
- Modify: `Tests/MacCleanerTests/Modules/ModuleSemanticTests.swift`

- [ ] **Step 1: 写出清理事实模型测试**

```swift
@Suite("Cleanable item evidence")
struct CleanableItemEvidenceTests {
    @Test("模型只含原始事实，不含本地风险和推荐")
    func storesFacts() {
        let item = CleanableItem(
            path: "/tmp/cache",
            displayName: "cache",
            logicalSize: 10,
            allocatedSize: 16,
            category: .developerCaches,
            subcategory: "npm",
            evidenceTags: ["cache", "developer-tool", "npm"],
            fileIdentity: .fixture()
        )

        #expect(item.evidenceTags == ["cache", "developer-tool", "npm"])
        #expect(item.displaySize == 16)
    }
}

@Test("subject factory 不加入文件内容或旧规则")
func subjectUsesOnlyEvidence() throws {
    let subject = try AIAssessmentSubjectFactory().cleanupSubject(for: .fixture())
    let json = String(decoding: try JSONEncoder().encode(subject), as: UTF8.self)
    #expect(!json.contains("ruleKey"))
    #expect(!json.contains("isRecommended"))
    #expect(!json.contains("fileContent"))
}
```

- [ ] **Step 2: 运行并确认当前模型不满足测试**

Run: `swift test --filter 'CleanableItemEvidenceTests|AIAssessmentSubjectFactoryTests'`

Expected: 编译失败，提示新初始化参数和 subject factory 不存在。

- [ ] **Step 3: 增加原始事实字段，暂时保留旧字段以维持中间提交可编译**

```swift
public struct CleanableItem: Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let displayName: String
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let category: ModuleIdentifier
    public let subcategory: String?
    public let evidenceTags: [String]
    public let fileIdentity: FileIdentity?

    public var displaySize: Int64 { allocatedSize }
    public var size: Int64 { allocatedSize }
}
```

标签在 initializer 中去空、去重并按字典序固定，确保 fingerprint 稳定。过渡提交可保留 deprecated 旧属性，但所有模块必须在本任务结束时只调用事实 initializer。

- [ ] **Step 4: 为每个模块写入固定 evidence tags**

| 模块 | 必含 tags | subcategory 来源 |
|---|---|---|
| DeveloperCaches | `cache`, `developer-tool` | npm、CocoaPods、Homebrew、Gradle 等工具标识 |
| Xcode | `cache`, `developer-tool`, `xcode` | DerivedData、Archives、DeviceSupport 等类型 |
| IOSSimulators | `simulator`, `developer-tool` | unavailable-device、runtime、device-data |
| AIToolCaches | `cache`, `ai-tool` | Cursor、Claude、Codex 等工具标识 |
| ApplicationCaches | `cache`, `application` | bundle ID 或目录名 |
| Docker | `cache`, `container`, `docker` | build-cache、image-data 等来源 |
| SystemLogs | `log`, `diagnostic` | app-log、diagnostic-report、crash-report |
| AndroidSDK | `cache`, `developer-tool`, `android` | gradle、emulator、sdk-cache |
| LargeFileScanner | `large-file` | 扩展名或 `unknown-extension` |
| DuplicateFiles | `duplicate-file` | content-hash |

不得把“安全”“危险”“推荐”“可删除”编码为 tag。

- [ ] **Step 5: 实现 subject factory**

factory 使用 `AIFingerprintGenerator` 和条目的 file identity 构造 `CleanupAIEvidence`。`fileIdentity == nil` 时仍可分析，但 fingerprint 明确编码 `identity: null`；删除 guard 仍会拒绝没有身份的执行。

- [ ] **Step 6: 修改 ScanResult 统计**

删除 `recommendedItems` 和 `recommendedSavings`。保留 `items`、`totalSize`，其中 `totalSize` 汇总 `allocatedSize`。不在 Core 中根据 AI 输出生成派生统计。

- [ ] **Step 7: 验证所有模块的语义测试**

Run: `swift test --filter 'CleanableItemEvidenceTests|AIAssessmentSubjectFactoryTests|ModuleSemanticTests|ModuleTests'`

Expected: 所有扫描模块只产出事实字段，测试通过。

- [ ] **Step 8: 提交**

```bash
git add Sources/MacCleanerCore/Models/CleanableItem.swift \
  Sources/MacCleanerCore/Models/ScanResult.swift \
  Sources/MacCleanerCore/Services/AIAssessmentSubjectFactory.swift \
  Sources/MacCleanerCore/Modules \
  Tests/MacCleanerTests/Models/CleanableItemEvidenceTests.swift \
  Tests/MacCleanerTests/Services/AIAssessmentSubjectFactoryTests.swift \
  Tests/MacCleanerTests/Modules
git commit -m "Core: emit cleanup evidence without local judgment"
```

### Task 3: 把进程列表迁移为无判断的原始事实

**Files:**
- Modify: `Sources/MacCleanerCore/Models/ProcessInfo.swift`
- Modify: `Sources/MacCleanerCore/Services/ProcessFetcher.swift`
- Modify: `Sources/MacCleanerCore/Services/AIAssessmentSubjectFactory.swift`
- Modify: `Tests/MacCleanerTests/Services/ProcessFetcherTests.swift`
- Modify: `Tests/MacCleanerTests/Services/AIAssessmentSubjectFactoryTests.swift`

- [ ] **Step 1: 写出原始进程事实测试**

```swift
@Test("进程抓取只返回可观察事实")
func fetcherReturnsRawFacts() async throws {
    let resolver = StubProcessResolver(identity: .fixture(
        pid: 42,
        executablePath: "/Applications/Test.app/Contents/MacOS/Test",
        startTimeTicks: 100
    ))
    let fetcher = ProcessFetcher(shell: .fixturePS(), resolver: resolver)
    let process = try #require(try await fetcher.fetch().first)

    #expect(process.identity.pid == 42)
    #expect(process.name == "Test")
    #expect(process.cpuPercent == 1.5)
    #expect(process.residentMemoryBytes == 1024)
}

@Test("进程 subject 不发送完整参数")
func processSubjectOmitsArguments() throws {
    let subject = try AIAssessmentSubjectFactory().processSubject(for: .fixture())
    let json = String(decoding: try JSONEncoder().encode(subject), as: UTF8.self)
    #expect(!json.contains("--token"))
    #expect(!json.contains("arguments"))
}
```

- [ ] **Step 2: 运行并确认当前静态判断字段导致失败**

Run: `swift test --filter 'ProcessFetcherTests|AIAssessmentSubjectFactoryTests'`

Expected: 新测试因 `identity` 和事实字段不存在而失败。

- [ ] **Step 3: 收敛 RunningProcess**

```swift
public struct RunningProcess: Identifiable, Sendable {
    public var id: Int32 { identity.pid }
    public let identity: ProcessIdentity
    public let name: String
    public let user: String
    public let cpuPercent: Double
    public let residentMemoryBytes: UInt64
    public let elapsedSeconds: UInt64?
    public let signedByApple: Bool?
}
```

删除 `description`、`consequence`、`recommendation`、`category`、`risk` 和 `ProcessDescriptionEntry`。`ProcessFetcher` 只负责解析 `ps` 数值并合并 P0 resolver 身份，不再读取描述数据库或使用名称启发式分类。

- [ ] **Step 4: 更新 process subject factory**

factory 将 PID、真实路径、basename、bundle ID、user、CPU、RSS、elapsed、Apple 签名状态写入 `ProcessAIEvidence`。不得加入原始 `ps` 行或 argv。

- [ ] **Step 5: 验证并提交**

Run: `swift test --filter 'ProcessFetcherTests|AIAssessmentSubjectFactoryTests|ProcessTerminationGuardTests'`

Expected: 全部通过，终止 guard 继续只依据本地身份。

```bash
git add Sources/MacCleanerCore/Models/ProcessInfo.swift \
  Sources/MacCleanerCore/Services/ProcessFetcher.swift \
  Sources/MacCleanerCore/Services/AIAssessmentSubjectFactory.swift \
  Tests/MacCleanerTests/Services/ProcessFetcherTests.swift \
  Tests/MacCleanerTests/Services/AIAssessmentSubjectFactoryTests.swift
git commit -m "Core: emit process facts without local judgment"
```

### Task 4: 实现 DeepSeek 设置、隐私确认和缓存管理

**Files:**
- Modify: `Sources/MacCleanerCore/Protocols/AIAssessmentProviding.swift`
- Modify: `Sources/MacCleanerCore/Services/DeepSeekAssessmentClient.swift`
- Create: `Sources/MacCleanerApp/Features/Settings/AISettingsViewModel.swift`
- Create: `Sources/MacCleanerApp/Features/Settings/AISettingsView.swift`
- Modify: `Sources/MacCleanerApp/Features/Settings/SettingsView.swift`
- Modify: `Sources/MacCleanerApp/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/MacCleanerApp/Resources/en.lproj/Localizable.strings`
- Create: `Tests/MacCleanerAppTests/AISettingsViewModelTests.swift`
- Modify: `Tests/MacCleanerTests/Services/DeepSeekAssessmentClientTests.swift`

- [ ] **Step 1: 写出设置 view model 测试**

```swift
@MainActor
@Suite("AI settings view model")
struct AISettingsViewModelTests {
    @Test("载入设置不回填明文 key")
    func neverLoadsPlaintextKey() async {
        let keyStore = InMemoryAPIKeyStore(key: "sk-existing")
        let viewModel = AISettingsViewModel.fixture(keyStore: keyStore)
        await viewModel.load()
        #expect(viewModel.isConfigured)
        #expect(viewModel.apiKeyInput.isEmpty)
    }

    @Test("保存前必须确认完整路径发送说明")
    func requiresPrivacyConsent() async {
        let consent = InMemoryAIPrivacyConsentStore(hasConsented: false)
        let keyStore = InMemoryAPIKeyStore()
        let viewModel = AISettingsViewModel.fixture(
            keyStore: keyStore,
            consentStore: consent
        )
        viewModel.apiKeyInput = "sk-new"
        await viewModel.saveKey()
        #expect(viewModel.presentPrivacyConsent)
        #expect(!(try keyStore.isConfigured()))
    }

    @Test("连接测试不发送本地文件或进程信息")
    func connectionCheckUsesMetadataFreeEndpoint() async {
        let checker = StubConnectionChecker(result: .success(()))
        let viewModel = AISettingsViewModel.fixture(connectionChecker: checker)
        await viewModel.testConnection()
        #expect(await checker.callCount == 1)
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacCleanerAppTests/AISettingsViewModelTests`

Expected: 编译失败，提示设置 view model 不存在。

- [ ] **Step 3: 增加无本地数据的连接检查**

```swift
public protocol DeepSeekConnectionChecking: Sendable {
    func checkConnection() async throws
}
```

`DeepSeekAssessmentClient.checkConnection` 请求 `GET /models`，只携带 Authorization 和 Accept，不构造 subject、prompt 或缓存记录。测试断言 body 为空；401/403/429/5xx 沿用现有错误映射。

- [ ] **Step 4: 实现设置状态机**

`AISettingsViewModel` 只公开 `apiKeyInput`、`isConfigured`、`connectionState`、`cacheStats`、`presentPrivacyConsent`。保存成功立即把 `apiKeyInput` 清空。删除 key 与清空缓存是两个独立按钮和确认框；删除 key 不删除缓存，清缓存不删除 key。

- [ ] **Step 5: 实现隐私说明 UI**

中文正文固定说明：

> AI 分析会把所选清理项的完整路径、大小、时间、类型和来源标签，或所选进程的 PID、可执行路径、用户、CPU、内存、运行时长与签名状态发送给 DeepSeek。不会发送文件内容、环境变量或完整命令行。AI 只提供解释、风险评级和建议，不会自动选择、删除或结束进程。

用户点击“同意并保存”后写 consent version `1`；点击取消不保存 key。设置页还显示模型、缓存条数、缓存占用、清空缓存和删除 Key。

- [ ] **Step 6: 验证并提交**

Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacCleanerAppTests/AISettingsViewModelTests`

Expected: 全部通过。

```bash
git add Sources/MacCleanerCore/Protocols/AIAssessmentProviding.swift \
  Sources/MacCleanerCore/Services/DeepSeekAssessmentClient.swift \
  Sources/MacCleanerApp/Features/Settings \
  Sources/MacCleanerApp/Resources \
  Tests/MacCleanerAppTests/AISettingsViewModelTests.swift \
  Tests/MacCleanerTests/Services/DeepSeekAssessmentClientTests.swift
git commit -m "App: add DeepSeek and privacy settings"
```

### Task 5: 在清理结果页接入缓存与显式 AI 分析

**Files:**
- Create: `Sources/MacCleanerApp/Components/AIAssessmentCard.swift`
- Modify: `Sources/MacCleanerApp/Features/Results/ResultsViewModel.swift`
- Modify: `Sources/MacCleanerApp/Features/Results/ResultsView.swift`
- Modify: `Sources/MacCleanerApp/Features/Results/ItemRowView.swift`
- Create: `Tests/MacCleanerAppTests/ResultsAIViewModelTests.swift`

- [ ] **Step 1: 写出缓存、缺失点击和选择隔离测试**

```swift
@MainActor
@Suite("Results AI view model")
struct ResultsAIViewModelTests {
    @Test("初始化只读缓存，不调用分析")
    func initializationReadsCacheOnly() async {
        let ai = RecordingAIService(states: ["item-1": .notAnalyzed])
        let viewModel = ResultsViewModel.fixture(aiService: ai)
        await viewModel.loadCachedAssessments()
        #expect(await ai.stateLookupCount == 1)
        #expect(await ai.analysisCallCount == 0)
        #expect(viewModel.selectedItemIDs.isEmpty)
    }

    @Test("缓存缺失只有用户点击后请求")
    func missingRequiresExplicitClick() async {
        let ai = RecordingAIService(states: ["item-1": .notAnalyzed])
        let viewModel = ResultsViewModel.fixture(aiService: ai)
        await viewModel.loadCachedAssessments()
        #expect(await ai.analysisCallCount == 0)
        await viewModel.analyzeItem(viewModel.allItems[0])
        #expect(await ai.analysisCallCount == 1)
    }

    @Test("AI 建议删除也不改变选择")
    func assessmentNeverSelectsItem() async {
        let ai = RecordingAIService(result: .fixture(recommendation: .delete))
        let viewModel = ResultsViewModel.fixture(aiService: ai)
        await viewModel.analyzeItem(viewModel.allItems[0])
        #expect(viewModel.selectedItemIDs.isEmpty)
    }

    @Test("重查失败保留旧卡片")
    func failedRefreshKeepsPreviousAssessment() async {
        let cached = AIAssessment.fixture(summary: "旧结果")
        let ai = RecordingAIService(refreshError: TestError.offline)
        let viewModel = ResultsViewModel.fixture(aiService: ai, cached: cached)
        await viewModel.reanalyzeItem(viewModel.allItems[0])
        #expect(viewModel.assessmentStates[viewModel.allItems[0].id]?.assessment == cached)
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacCleanerAppTests/ResultsAIViewModelTests`

Expected: 新 AI 行为尚未实现，测试失败。

- [ ] **Step 3: 实现 view model 状态与方法**

```swift
var assessmentStates: [UUID: AIAssessmentState] = [:]
var isBatchAnalyzing = false

func loadCachedAssessments() async
func analyzeItem(_ item: CleanableItem) async
func reanalyzeItem(_ item: CleanableItem) async
func analyzeMissingItems() async
func cancelAIAnalysis() async
```

`loadCachedAssessments` 在扫描结果页出现后调用，只执行 coordinator `states`。`analyzeItem` 与 `analyzeMissingItems` 必须由 Button action 调用；批量按钮只分析 `.notAnalyzed` 与用户主动选择重试的 `.failed(previous: nil)`，不会重查已有缓存。`reanalyzeItem` 明确传 `forceRefresh: true`。

- [ ] **Step 4: 实现行内与批量交互**

每行未分析时显示“AI 分析”按钮；缓存命中显示风险、建议、置信度、说明、依据以及“来自本地缓存”，旁边显示“AI 重新检查”。加载时可取消；失败显示错误和重试。顶部显示“AI 分析未判断项（N）”，N 为 0 时禁用。AI 卡片不含选择控件，不在结果回调中调用 `toggleItem`。

本地 guard 的不可执行状态优先于 AI 卡片展示：即使 AI 返回 `delete`，行仍显示“本地安全校验未通过，无法执行”。

- [ ] **Step 5: 验证并提交**

Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacCleanerAppTests/ResultsAIViewModelTests`

Expected: 全部通过。

```bash
git add Sources/MacCleanerApp/Components/AIAssessmentCard.swift \
  Sources/MacCleanerApp/Features/Results \
  Tests/MacCleanerAppTests/ResultsAIViewModelTests.swift
git commit -m "App: add explicit AI analysis to cleanup results"
```

### Task 6: 在活动监视器接入缓存与显式 AI 分析

**Files:**
- Modify: `Sources/MacCleanerApp/Features/ActivityMonitor/ActivityMonitorViewModel.swift`
- Modify: `Sources/MacCleanerApp/Features/ActivityMonitor/ActivityMonitorView.swift`
- Create: `Tests/MacCleanerAppTests/ActivityMonitorAIViewModelTests.swift`

- [ ] **Step 1: 写出刷新不联网与终止 guard 独立测试**

```swift
@MainActor
@Suite("Activity monitor AI view model")
struct ActivityMonitorAIViewModelTests {
    @Test("三秒刷新只加载新 fingerprint 的缓存")
    func refreshNeverAnalyzesAutomatically() async {
        let ai = RecordingAIService()
        let viewModel = ActivityMonitorViewModel.fixture(aiService: ai)
        await viewModel.refresh()
        await viewModel.refresh()
        #expect(await ai.analysisCallCount == 0)
        #expect(await ai.stateLookupCount == 1)
    }

    @Test("AI 建议关闭不能绕过本地 guard")
    func recommendationCannotTerminate() async {
        let ai = RecordingAIService(result: .fixture(recommendation: .delete))
        let termination = RecordingTerminationService(result: .protectedProcess)
        let viewModel = ActivityMonitorViewModel.fixture(
            aiService: ai,
            terminationService: termination
        )
        let process = try #require(viewModel.processes.first)
        await viewModel.analyze(process)
        #expect(await termination.signalCount == 0)
        await viewModel.requestTermination(process)
        #expect(await termination.signalCount == 0)
        #expect(viewModel.terminationError == .protectedProcess)
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacCleanerAppTests/ActivityMonitorAIViewModelTests`

Expected: 新 AI 行为尚未实现，测试失败。

- [ ] **Step 3: 实现 fingerprint 状态索引**

进程每次刷新后，对首次出现的 fingerprint 只调用 `state(for:)` 读缓存；同一 fingerprint 不重复读取。进程退出后移除内存 UI 状态。单项“AI 分析”、批量“分析未判断进程”和“AI 重新检查”复用 Results 的行为约束。

- [ ] **Step 4: 更新进程行和详情**

未分析时只显示 name、PID、path、user、CPU、内存、运行时长和 AI 按钮；缓存命中显示 AI 卡片。删除旧 category/risk/description/consequence/recommendation UI。终止按钮始终调用 P0 `ProcessTerminationGuard`，AI 结果只作为解释信息。

- [ ] **Step 5: 验证并提交**

Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacCleanerAppTests/ActivityMonitorAIViewModelTests`

Expected: 全部通过。

```bash
git add Sources/MacCleanerApp/Features/ActivityMonitor \
  Tests/MacCleanerAppTests/ActivityMonitorAIViewModelTests.swift
git commit -m "App: add explicit AI process assessment"
```

### Task 7: 移除旧判断系统并收敛 CLI 与定时扫描语义

**Files:**
- Delete: `Sources/MacCleanerCore/Services/RulesProvider.swift`
- Delete: `Sources/MacCleanerCore/Resources/CleaningRules.json`
- Delete: `Sources/MacCleanerCore/Resources/ProcessDescriptions.json`
- Delete: `Sources/MacCleanerApp/Components/RiskBadge.swift`
- Delete: `Sources/MacCleanerApp/Extensions/RiskLevel+UI.swift`
- Delete: `Tests/MacCleanerTests/Models/RiskLevelTests.swift`
- Modify: `Sources/MacCleanerCore/Models/CleanableItem.swift`
- Modify: `Sources/MacCleanerCore/Models/CleaningProfile.swift`
- Modify: `Sources/MacCleanerCore/Services/ScheduledScanService.swift`
- Modify: `Sources/MacCleanerCLI/Commands/CleanCommand.swift`
- Modify: `Sources/MacCleanerCLI/Commands/InteractiveCommand.swift`
- Modify: `Sources/MacCleanerCLI/TUI/SelectionList.swift`
- Modify: `Tests/MacCleanerTests/Models/CleaningProfileTests.swift`
- Modify: `Tests/MacCleanerTests/Services/ScheduledScanTests.swift`
- Modify: `Tests/MacCleanerTests/ViewModels/ResultsViewModelTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: 写出 CLI/profile/定时扫描的新语义测试**

```swift
@Test("清理方案只筛选模块，不筛选条目")
func profileOnlyFiltersModules() {
    let profile = CleaningProfile(
        name: "日志候选",
        description: "扫描日志候选",
        moduleIDs: [ModuleIdentifier.systemLogs.rawValue],
        isBuiltIn: true,
        icon: "doc.plaintext"
    )
    #expect(profile.filterModules(ModuleIdentifier.allCases) == [.systemLogs])
}

@Test("定时扫描统计全部过滤后候选，不称为推荐空间")
func scheduledScanStoresCandidateBytes() async {
    let service = ScheduledScanService.fixture(results: [.fixture(totalSize: 42)])
    await service.performScanForTesting()
    #expect(await service.lastScanCandidateBytes == 42)
}
```

CLI 集成测试启动 `mac-cleaner clean --dry-run --yes` 且不传模块或 `--all`，断言非零退出并提示“请指定模块或 --all”；启动 `--all --dry-run --yes`，断言打印“全部候选”而非“推荐项”。

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter 'CleaningProfileTests|ScheduledScanTests'`

Expected: 旧推荐/风险字段仍在，测试失败。

- [ ] **Step 3: 删除所有旧判断字段与资源**

从 `CleanableItem` 删除 `RiskLevel`、`isRecommended`、`riskLevel`、`detail`、`ruleKey` 和规则 initializer。从 `CleaningProfile` 删除 `maxRiskLevel`、`onlyRecommended`、`filterItems`；内置方案只表示模块组合，并将“仅安全项”删除，因为无 AI/本地判断时无法兑现该含义。删除旧资源后，`Package.swift` 的 Core target 去掉 `.process("Resources")`。

- [ ] **Step 4: 收敛 CLI 行为**

`--all` 帮助改成“扫描并清理所有候选（执行前仍需确认）”。未传模块、profile 或 `--all` 时拒绝执行，不再默认扫描并清理所有模块。模块 scan 的全部过滤后候选进入确认列表；TUI 初始选择为空。CLI 不调用 DeepSeek，也不根据本地缓存自动选择。

- [ ] **Step 5: 收敛定时扫描文案与统计**

将 `lastScanReclaimable` 重命名为 `lastScanCandidateBytes`，通知正文改成“发现候选占用空间”，不得表述为“建议清理”或“可安全回收”。定时扫描只扫描、统一排除和统计，不调用 AI。

- [ ] **Step 6: 检查旧系统引用归零**

Run: `rg -n 'RulesProvider|CleaningRules|ProcessDescriptions|ProcessRisk|isRecommended|recommendedItems|recommendedSavings|onlyRecommended|maxRiskLevel|ruleKey' Sources Tests Package.swift`

Expected: 0 matches。

Run: `rg -n '\bRiskLevel\b' Sources Tests Package.swift`

Expected: 0 matches；`AIRiskLevel` 保留且不应被该独立单词表达式命中。

- [ ] **Step 7: 验证并提交**

Run: `swift test`

Expected: 所有 Core/CLI 测试通过。

Run: `xcodegen generate && xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

Expected: App 和 App tests 全部通过。

```bash
git add Package.swift Sources/MacCleanerCore Sources/MacCleanerCLI \
  Sources/MacCleanerApp Tests
git commit -m "Core: remove built-in risk and recommendation rules"
```

### Task 8: App AI 迁移总体验收

**Files:**
- Modify only if verification exposes a regression in files touched by Tasks 1–7.

- [ ] **Step 1: 运行所有自动化测试**

Run: `swift test`

Expected: 所有 suite 通过，0 issues。

Run: `xcodebuild test -project MacCleaner.xcodeproj -scheme MacCleanerApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

Expected: `** TEST SUCCEEDED **`。

- [ ] **Step 2: 验证完全离线流程**

断开网络并启动 App：扫描完成后 0 项选中；已有缓存立即展示；缓存缺失显示“未分析”；不出现网络错误，直到用户点击 AI；用户仍能查看事实、手工选择并由本地 guard 执行。

- [ ] **Step 3: 验证用户填写 Key 流程**

首次保存 Key 时出现完整路径发送说明；取消后 Keychain 不新增；同意后保存且输入框清空；重启 App 只显示“已配置”，不回填 Key；删除 Key 后已有本地缓存仍可查看。

- [ ] **Step 4: 验证单项与批量 AI**

对一个未分析项点击 AI，只有该项进入 loading；点击批量按钮只请求未分析项；已有缓存不重查；点击“AI 重新检查”才强制联网；失败时旧结果保留。所有场景下 `selectedItemIDs` 保持不变。

- [ ] **Step 5: 验证执行隔离**

构造 AI 建议删除但本地 guard 拒绝的符号链接、身份变化文件和受保护进程；确认 UI 展示 AI 建议的同时禁用执行并显示本地拒绝原因。网络响应、缓存文件和 UI action 中均没有把 AI 返回值转换为路径、PID 或 shell 命令的代码路径。
