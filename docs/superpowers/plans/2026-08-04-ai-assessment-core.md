# MacCleaner AI Assessment Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立可测试、可缓存、可取消的 DeepSeek 判断内核，让 AI 只负责解释、风险评级和推荐，不参与选择、删除或进程终止。

**Architecture:** Core 将本地事实编码为强类型 `AIAssessmentSubject`，通过 provider 协议调用 DeepSeek 严格结构化输出，再经本地 schema 校验后写入 actor 管理的 JSON 缓存。API Key 只进入 Keychain 和请求头；业务层只看到“是否已配置”。

**Tech Stack:** Swift 5.9、Swift Concurrency、Foundation、FoundationNetworking/URLSession、CryptoKit、Security、Swift Testing、DeepSeek Chat Completions API。

**Design:** `docs/superpowers/specs/2026-08-04-ai-assessment-and-search-design.md`

## Global Constraints

- 开始本计划前必须完成 `2026-08-04-safety-baseline.md`。
- AI 输出不得包含或覆盖本地目标路径、PID、文件身份、执行命令、选择状态。
- 缓存未命中时不得自动请求；只有显式 `analyze` 或 `reanalyze` 调用才允许访问网络。
- 第一版不脱敏路径，但请求中禁止发送文件内容、环境变量、完整命令行参数、API Key 和用户输入之外的凭据。
- 一个条目的合法 AI 结果必须同时包含解释、风险、建议、置信度、依据与模型标识；任何字段非法都不写缓存。
- `reanalyze` 只有在新结果通过本地校验后才覆盖旧缓存；失败时保留旧结果并返回可展示错误。
- 单批最多 10 项，同时最多 2 个网络请求；尊重取消，不重试 4xx，429/5xx 最多退避重试 2 次。
- 每个提交只包含该任务列出的文件；仓库中已有未提交修改不纳入提交。

## File Structure Map

```text
Sources/MacCleanerCore/
├── Models/
│   ├── AIAssessment.swift                 # AI 输出模型
│   ├── AIAssessmentState.swift            # 未配置/未分析/缓存/加载/失败状态
│   ├── AIAssessmentSubject.swift          # 清理与进程事实输入
│   └── DeepSeekDTO.swift                  # API 请求响应 DTO
├── Protocols/
│   ├── AIAssessmentProviding.swift
│   ├── APIKeyStoreProtocols.swift
│   └── HTTPTransporting.swift
├── Services/
│   ├── AIAssessmentCache.swift            # actor JSON 缓存
│   ├── AIAnalysisCoordinator.swift         # 显式请求、分批、取消、回写
│   ├── AIFingerprintGenerator.swift        # 稳定 SHA-256 指纹
│   ├── DeepSeekAssessmentClient.swift      # 网络 provider
│   ├── KeychainAPIKeyStore.swift           # Keychain 实现
│   └── URLSessionHTTPTransport.swift       # URLSession 适配
Tests/MacCleanerTests/
├── Models/AIAssessmentTests.swift
└── Services/
    ├── AIAssessmentCacheTests.swift
    ├── AIAnalysisCoordinatorTests.swift
    ├── AIFingerprintGeneratorTests.swift
    ├── DeepSeekAssessmentClientTests.swift
    └── KeychainAPIKeyStoreTests.swift
```

---

### Task 1: 定义 AI 输入、输出与 UI 状态

**Files:**
- Create: `Sources/MacCleanerCore/Models/AIAssessment.swift`
- Create: `Sources/MacCleanerCore/Models/AIAssessmentSubject.swift`
- Create: `Sources/MacCleanerCore/Models/AIAssessmentState.swift`
- Create: `Tests/MacCleanerTests/Models/AIAssessmentTests.swift`

- [ ] **Step 1: 写出 Codable、风险建议分离和状态测试**

```swift
import Foundation
import Testing
@testable import MacCleanerCore

@Suite("AI assessment models")
struct AIAssessmentTests {
    @Test("风险与建议互不推导")
    func riskAndRecommendationAreIndependent() throws {
        let value = AIAssessment.fixture(risk: .high, recommendation: .keep)
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AIAssessment.self, from: encoded)

        #expect(decoded.risk == .high)
        #expect(decoded.recommendation == .keep)
    }

    @Test("清理事实不包含文件内容字段")
    func cleanupEvidenceContainsMetadataOnly() throws {
        let subject = AIAssessmentSubject.cleanup(
            id: "cleanup:1",
            fingerprint: "abc",
            evidence: CleanupAIEvidence(
                path: "/Users/me/Library/Caches/x",
                objectKind: .directory,
                logicalSize: 10,
                allocatedSize: 16,
                modificationTime: Date(timeIntervalSince1970: 1),
                module: .applicationCaches,
                tags: ["cache"]
            )
        )
        let json = String(decoding: try JSONEncoder().encode(subject), as: UTF8.self)

        #expect(!json.contains("fileContent"))
        #expect(!json.contains("environment"))
        #expect(!json.contains("arguments"))
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter AIAssessmentTests`

Expected: 编译失败，提示 AI 模型不存在。

- [ ] **Step 3: 实现输出模型**

```swift
public enum AIRiskLevel: String, Codable, CaseIterable, Sendable {
    case low, medium, high, critical, unknown
}

public enum AIRecommendation: String, Codable, CaseIterable, Sendable {
    case delete, keep, inspect, unknown
}

public enum AIConfidence: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

public struct AIAssessment: Codable, Equatable, Sendable {
    public let subjectID: String
    public let fingerprint: String
    public let summary: String
    public let explanation: String
    public let risk: AIRiskLevel
    public let recommendation: AIRecommendation
    public let confidence: AIConfidence
    public let evidence: [String]
    public let model: String
    public let assessedAt: Date
}
```

字段限制由初始化器和 validator 共同保证：`summary` 1…80 字，`explanation` 1…800 字，`evidence` 1…8 项且单项 1…160 字。

- [ ] **Step 4: 实现判别式输入模型**

```swift
public enum AIAssessmentSubject: Codable, Equatable, Sendable {
    case cleanup(id: String, fingerprint: String, evidence: CleanupAIEvidence)
    case process(id: String, fingerprint: String, evidence: ProcessAIEvidence)

    public var subjectID: String {
        switch self {
        case let .cleanup(id, _, _), let .process(id, _, _): id
        }
    }

    public var fingerprint: String {
        switch self {
        case let .cleanup(_, fingerprint, _), let .process(_, fingerprint, _): fingerprint
        }
    }
}

public struct CleanupAIEvidence: Codable, Equatable, Sendable {
    public let path: String
    public let objectKind: FileObjectKind
    public let logicalSize: UInt64
    public let allocatedSize: UInt64
    public let modificationTime: Date?
    public let module: ModuleIdentifier
    public let tags: [String]
}

public struct ProcessAIEvidence: Codable, Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let executableName: String
    public let bundleIdentifier: String?
    public let owner: String
    public let cpuPercent: Double
    public let residentMemoryBytes: UInt64
    public let elapsedSeconds: UInt64?
    public let signedByApple: Bool?
}
```

为 enum 实现显式 `kind` 判别字段；编码结果只能出现对应 evidence，不能出现完整 argv。

- [ ] **Step 5: 实现可展示状态**

```swift
public enum AIAssessmentState: Equatable, Sendable {
    case notConfigured
    case notAnalyzed
    case cached(AIAssessment)
    case loading(previous: AIAssessment?)
    case fresh(AIAssessment)
    case failed(message: String, previous: AIAssessment?)

    public var assessment: AIAssessment? {
        switch self {
        case let .cached(value), let .fresh(value): value
        case let .loading(previous), let .failed(_, previous): previous
        case .notConfigured, .notAnalyzed: nil
        }
    }
}
```

- [ ] **Step 6: 验证并提交**

Run: `swift test --filter AIAssessmentTests`

Expected: 全部通过。

```bash
git add Sources/MacCleanerCore/Models/AIAssessment.swift \
  Sources/MacCleanerCore/Models/AIAssessmentSubject.swift \
  Sources/MacCleanerCore/Models/AIAssessmentState.swift \
  Tests/MacCleanerTests/Models/AIAssessmentTests.swift
git commit -m "Core: define AI assessment domain models"
```

### Task 2: 生成语义稳定且实例敏感的指纹

**Files:**
- Create: `Sources/MacCleanerCore/Services/AIFingerprintGenerator.swift`
- Create: `Tests/MacCleanerTests/Services/AIFingerprintGeneratorTests.swift`

- [ ] **Step 1: 写出确定性和失效测试**

```swift
@Suite("AI fingerprint generator")
struct AIFingerprintGeneratorTests {
    @Test("相同字段顺序无关且指纹稳定")
    func deterministicCleanupFingerprint() throws {
        let generator = AIFingerprintGenerator()
        let first = try generator.cleanupFingerprint(.fixture(tags: ["cache", "npm"]))
        let second = try generator.cleanupFingerprint(.fixture(tags: ["npm", "cache"]))
        #expect(first == second)
    }

    @Test("大小、mtime 或 inode 改变会使实例指纹失效")
    func cleanupInstanceChangesInvalidate() throws {
        let generator = AIFingerprintGenerator()
        let first = try generator.cleanupFingerprint(.fixture(inode: 1, allocatedSize: 10))
        let second = try generator.cleanupFingerprint(.fixture(inode: 2, allocatedSize: 10))
        let third = try generator.cleanupFingerprint(.fixture(inode: 1, allocatedSize: 11))
        #expect(first != second)
        #expect(first != third)
    }

    @Test("进程启动时间变化会使 PID 指纹失效")
    func processRestartInvalidatesFingerprint() throws {
        let generator = AIFingerprintGenerator()
        #expect(
            try generator.processFingerprint(.fixture(startTimeTicks: 1)) !=
            generator.processFingerprint(.fixture(startTimeTicks: 2))
        )
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter AIFingerprintGeneratorTests`

Expected: 编译失败，提示 generator 不存在。

- [ ] **Step 3: 实现规范化 JSON 与 SHA-256**

```swift
public struct AIFingerprintGenerator: Sendable {
    public func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let bytes = try encoder.encode(value)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
```

清理指纹字段固定为 schema version、规范化路径、device、inode、对象类型、allocated size、mtime 毫秒、module、排序去重后的 tags。进程指纹固定为 schema version、PID、可执行路径、bundle ID、启动时间、签名状态；瞬时 CPU 和内存不进入指纹，仍进入请求 evidence。

- [ ] **Step 4: 验证并提交**

Run: `swift test --filter AIFingerprintGeneratorTests`

Expected: 全部通过。

```bash
git add Sources/MacCleanerCore/Services/AIFingerprintGenerator.swift \
  Tests/MacCleanerTests/Services/AIFingerprintGeneratorTests.swift
git commit -m "Core: fingerprint AI assessment subjects"
```

### Task 3: 实现本地 JSON 缓存及损坏恢复

**Files:**
- Create: `Sources/MacCleanerCore/Services/AIAssessmentCache.swift`
- Create: `Tests/MacCleanerTests/Services/AIAssessmentCacheTests.swift`

- [ ] **Step 1: 写出命中、覆盖、过期、损坏和容量测试**

```swift
@Suite("AI assessment cache")
struct AIAssessmentCacheTests {
    @Test("按指纹命中并原子覆盖")
    func storesAndOverwrites() async throws {
        let cache = AIAssessmentCache(fileURL: temporaryURL(), maxRecords: 3)
        try await cache.put(.fixture(fingerprint: "a", summary: "old"))
        try await cache.put(.fixture(fingerprint: "a", summary: "new"))
        #expect(try await cache.lookup(fingerprint: "a")?.summary == "new")
        #expect(try await cache.stats().recordCount == 1)
    }

    @Test("损坏文件隔离后返回空缓存")
    func quarantinesCorruptFile() async throws {
        let url = temporaryURL(contents: Data("not-json".utf8))
        let cache = AIAssessmentCache(fileURL: url, maxRecords: 100)
        #expect(try await cache.lookup(fingerprint: "a") == nil)
        #expect(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
    }

    @Test("超过容量淘汰最久未访问项")
    func evictsLeastRecentlyUsed() async throws {
        let cache = AIAssessmentCache(fileURL: temporaryURL(), maxRecords: 2)
        try await cache.put(.fixture(fingerprint: "a"))
        try await cache.put(.fixture(fingerprint: "b"))
        _ = try await cache.lookup(fingerprint: "a")
        try await cache.put(.fixture(fingerprint: "c"))
        #expect(try await cache.lookup(fingerprint: "b") == nil)
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter AIAssessmentCacheTests`

Expected: 编译失败，提示缓存类型不存在。

- [ ] **Step 3: 实现 actor 缓存**

```swift
public actor AIAssessmentCache {
    public struct Stats: Equatable, Sendable {
        public let recordCount: Int
        public let byteCount: UInt64
    }

    public init(
        fileURL: URL = Self.defaultFileURL,
        maxRecords: Int = 5_000,
        now: @escaping @Sendable () -> Date = Date.init
    )

    public func lookup(fingerprint: String) throws -> AIAssessment?
    public func put(_ assessment: AIAssessment) throws
    public func removeAll() throws
    public func stats() throws -> Stats
}
```

默认路径为 `~/Library/Application Support/DevClean/AI/assessments-v1.json`。文档结构含 `schemaVersion`、`records[fingerprint]`、`lastAccessedAt`。写入采用同目录临时文件加 `FileManager.replaceItemAt`；首次解码失败将原文件原子移动为固定的 `.corrupt` 路径后从空文档继续。缓存不保存 API Key、请求头、原始文件内容或完整命令行。

- [ ] **Step 4: 验证并提交**

Run: `swift test --filter AIAssessmentCacheTests`

Expected: 全部通过。

```bash
git add Sources/MacCleanerCore/Services/AIAssessmentCache.swift \
  Tests/MacCleanerTests/Services/AIAssessmentCacheTests.swift
git commit -m "Core: persist validated AI assessments locally"
```

### Task 4: 使用 Keychain 保存用户填写的 DeepSeek Key

**Files:**
- Create: `Sources/MacCleanerCore/Protocols/APIKeyStoreProtocols.swift`
- Create: `Sources/MacCleanerCore/Services/KeychainAPIKeyStore.swift`
- Create: `Tests/MacCleanerTests/Services/KeychainAPIKeyStoreTests.swift`

- [ ] **Step 1: 写出协议行为测试**

```swift
@Suite("API key store")
struct KeychainAPIKeyStoreTests {
    @Test("设置后只暴露 configured 状态")
    func configurationStatus() throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainAPIKeyStore(backend: backend)
        try store.set("sk-user-secret")

        #expect(try store.isConfigured())
        #expect(backend.lastWrite?.service == "com.maccleaner.deepseek")
        #expect(backend.lastWrite?.account == "api-key")
    }

    @Test("空白 key 被拒绝，删除后状态清空")
    func rejectsBlankAndDeletes() throws {
        let store = KeychainAPIKeyStore(backend: InMemoryKeychainBackend())
        #expect(throws: APIKeyStoreError.invalidKey) { try store.set("   ") }
        try store.set("sk-valid")
        try store.delete()
        #expect(!(try store.isConfigured()))
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter KeychainAPIKeyStoreTests`

Expected: 编译失败，提示 Keychain store 不存在。

- [ ] **Step 3: 定义最小权限协议和 Security 实现**

```swift
public protocol APIKeyManaging: Sendable {
    func isConfigured() throws -> Bool
    func set(_ key: String) throws
    func delete() throws
}

public protocol APIKeyProviding: Sendable {
    func withAPIKey<T>(_ body: (String) throws -> T) throws -> T
}
```

`KeychainAPIKeyStore` 同时实现两个协议。生产实现使用 `kSecClassGenericPassword`、service `com.maccleaner.deepseek`、account `api-key`、`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。设置页依赖只暴露 set/delete/status 的 `APIKeyManaging`；只有网络 client 依赖 `APIKeyProviding`，通过 `withAPIKey` 在构造请求的同步闭包里读取，闭包结束后不保留引用。日志错误不附带请求头或 key 内容。

- [ ] **Step 4: 验证并提交**

Run: `swift test --filter KeychainAPIKeyStoreTests`

Expected: 全部通过，测试使用内存 backend，不污染开发机 Keychain。

```bash
git add Sources/MacCleanerCore/Protocols/APIKeyStoreProtocols.swift \
  Sources/MacCleanerCore/Services/KeychainAPIKeyStore.swift \
  Tests/MacCleanerTests/Services/KeychainAPIKeyStoreTests.swift
git commit -m "Core: store DeepSeek credentials in Keychain"
```

### Task 5: 实现 DeepSeek 严格结构化 provider

**Files:**
- Create: `Sources/MacCleanerCore/Protocols/AIAssessmentProviding.swift`
- Create: `Sources/MacCleanerCore/Protocols/HTTPTransporting.swift`
- Create: `Sources/MacCleanerCore/Models/DeepSeekDTO.swift`
- Create: `Sources/MacCleanerCore/Services/URLSessionHTTPTransport.swift`
- Create: `Sources/MacCleanerCore/Services/DeepSeekAssessmentClient.swift`
- Create: `Tests/MacCleanerTests/Services/DeepSeekAssessmentClientTests.swift`

- [ ] **Step 1: 写出请求最小化、合法解析和错误映射测试**

```swift
@Suite("DeepSeek assessment client")
struct DeepSeekAssessmentClientTests {
    @Test("请求只发送允许的元数据并强制工具输出")
    func sendsMinimalStructuredRequest() async throws {
        let transport = MockHTTPTransport(response: .validToolResponse())
        let client = DeepSeekAssessmentClient(
            configuration: .init(baseURL: URL(string: "https://api.deepseek.com")!, model: "deepseek-v4-pro"),
            keyStore: InMemoryAPIKeyStore(key: "sk-secret"),
            transport: transport
        )
        _ = try await client.assess([.cleanupFixture()])
        let request = try #require(await transport.lastRequest)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret")
        #expect(body.contains("submit_assessments"))
        #expect(body.contains("tool_choice"))
        #expect(!body.contains("fileContent"))
        #expect(!body.contains("environment"))
        #expect(!body.contains("fullArguments"))
        #expect(!body.contains("sk-secret"))
    }

    @Test(arguments: [401, 429, 500])
    func mapsHTTPFailures(status: Int) async {
        let client = DeepSeekAssessmentClient.fixture(status: status)
        await #expect(throws: DeepSeekClientError.self) {
            try await client.assess([.cleanupFixture()])
        }
    }

    @Test("非法枚举或缺失 subject 不写成结果")
    func rejectsInvalidSchema() async {
        let client = DeepSeekAssessmentClient.fixture(response: .invalidRiskResponse())
        await #expect(throws: AssessmentValidationError.self) {
            try await client.assess([.cleanupFixture()])
        }
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter DeepSeekAssessmentClientTests`

Expected: 编译失败，提示 provider/transport/DTO 不存在。

- [ ] **Step 3: 定义 provider 和 transport 边界**

```swift
public protocol AIAssessmentProviding: Sendable {
    func assess(_ subjects: [AIAssessmentSubject]) async throws -> [AIAssessment]
}

public protocol HTTPTransporting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

- [ ] **Step 4: 构造固定 system prompt 和工具 schema**

请求固定到 `/chat/completions`，设置 `temperature: 0`，`stream: false`，并强制调用 `submit_assessments`。工具参数顶层为：

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["assessments"],
  "properties": {
    "assessments": {
      "type": "array",
      "minItems": 1,
      "maxItems": 10,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["subject_id", "fingerprint", "summary", "explanation", "risk", "recommendation", "confidence", "evidence"],
        "properties": {
          "subject_id": { "type": "string" },
          "fingerprint": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
          "summary": { "type": "string", "maxLength": 80 },
          "explanation": { "type": "string", "maxLength": 800 },
          "risk": { "type": "string", "enum": ["low", "medium", "high", "critical", "unknown"] },
          "recommendation": { "type": "string", "enum": ["delete", "keep", "inspect", "unknown"] },
          "confidence": { "type": "string", "enum": ["low", "medium", "high"] },
          "evidence": { "type": "array", "minItems": 1, "maxItems": 8, "items": { "type": "string", "maxLength": 160 } }
        }
      }
    }
  }
}
```

system prompt 明确：只解释事实、给风险和建议；不得声称已经删除、结束、选择或验证安全；信息不足时返回 `unknown` 或 `inspect`；不得编造未提供的文件内容。

- [ ] **Step 5: 校验响应与输入一一对应**

只解析 `tool_calls[].function.name == "submit_assessments"` 的 arguments。校验响应数量、subject ID 集合和 fingerprint 与本次输入完全一致；拒绝重复、缺失、多余项和超长文本。`model` 从服务响应读取，`assessedAt` 由本地 `now` 注入。

- [ ] **Step 6: 实现错误与重试边界**

401/403 映射为 `.authentication`，429 映射为 `.rateLimited(retryAfter:)`，5xx 映射为 `.serviceUnavailable`，其余非 2xx 映射为 `.httpStatus(Int)`。provider 自身不重试；重试由 coordinator 统一控制，以便响应取消。

- [ ] **Step 7: 验证并提交**

Run: `swift test --filter DeepSeekAssessmentClientTests`

Expected: 请求、合法响应、非法 schema 和错误映射测试全部通过。

```bash
git add Sources/MacCleanerCore/Protocols/AIAssessmentProviding.swift \
  Sources/MacCleanerCore/Protocols/HTTPTransporting.swift \
  Sources/MacCleanerCore/Models/DeepSeekDTO.swift \
  Sources/MacCleanerCore/Services/URLSessionHTTPTransport.swift \
  Sources/MacCleanerCore/Services/DeepSeekAssessmentClient.swift \
  Tests/MacCleanerTests/Services/DeepSeekAssessmentClientTests.swift
git commit -m "Core: add structured DeepSeek assessment client"
```

### Task 6: 编排显式分析、缓存命中、重查与取消

**Files:**
- Create: `Sources/MacCleanerCore/Services/AIAnalysisCoordinator.swift`
- Create: `Tests/MacCleanerTests/Services/AIAnalysisCoordinatorTests.swift`

- [ ] **Step 1: 写出“不自动请求”与重查覆盖测试**

```swift
@Suite("AI analysis coordinator")
struct AIAnalysisCoordinatorTests {
    @Test("读取状态只查缓存，不调用 provider")
    func stateLookupNeverCallsNetwork() async throws {
        let provider = RecordingAssessmentProvider()
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: AIAssessmentCache(fileURL: temporaryURL()),
            retryClock: ImmediateRetryClock()
        )

        let state = try await coordinator.state(for: .cleanupFixture())

        #expect(state == .notAnalyzed)
        #expect(await provider.callCount == 0)
    }

    @Test("缓存命中直接展示；普通分析不请求，重查才请求并覆盖")
    func cachedAndForcedBehavior() async throws {
        let cache = AIAssessmentCache(fileURL: temporaryURL())
        try await cache.put(.fixture(fingerprint: AIAssessmentSubject.cleanupFixture().fingerprint, summary: "cached"))
        let provider = RecordingAssessmentProvider(results: [.fixture(summary: "fresh")])
        let coordinator = AIAnalysisCoordinator(provider: provider, cache: cache, retryClock: ImmediateRetryClock())

        #expect(try await coordinator.state(for: .cleanupFixture()).assessment?.summary == "cached")
        _ = try await coordinator.analyze([.cleanupFixture()], forceRefresh: false)
        #expect(await provider.callCount == 0)
        _ = try await coordinator.analyze([.cleanupFixture()], forceRefresh: true)
        #expect(await provider.callCount == 1)
        #expect(try await cache.lookup(fingerprint: AIAssessmentSubject.cleanupFixture().fingerprint)?.summary == "fresh")
    }

    @Test("重查失败保留旧结果")
    func failedRefreshPreservesCache() async throws {
        let cached = AIAssessment.fixture(
            fingerprint: AIAssessmentSubject.cleanupFixture().fingerprint,
            summary: "cached"
        )
        let cache = AIAssessmentCache(fileURL: temporaryURL())
        try await cache.put(cached)
        let provider = RecordingAssessmentProvider(error: TestError.offline)
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: cache,
            retryClock: ImmediateRetryClock()
        )

        let states = await coordinator.analyze([.cleanupFixture()], forceRefresh: true)

        #expect(states[cached.subjectID]?.assessment == cached)
        #expect(try await cache.lookup(fingerprint: cached.fingerprint) == cached)
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `swift test --filter AIAnalysisCoordinatorTests`

Expected: 编译失败，提示 coordinator 不存在。

- [ ] **Step 3: 实现 coordinator 公共接口**

```swift
public actor AIAnalysisCoordinator {
    public func state(for subject: AIAssessmentSubject) async throws -> AIAssessmentState

    public func states(
        for subjects: [AIAssessmentSubject]
    ) async -> [String: AIAssessmentState]

    public func analyze(
        _ subjects: [AIAssessmentSubject],
        forceRefresh: Bool
    ) async -> [String: AIAssessmentState]

    public func cancelCurrentAnalysis()
}
```

`state` 和 `states` 只读 Keychain 配置状态与本地缓存。`analyze(forceRefresh: false)` 过滤掉缓存命中项；当剩余为空时直接返回。未配置 key 返回 `.notConfigured`，不得调用 provider。

- [ ] **Step 4: 实现限流、部分失败与取消**

按输入顺序切为每批最多 10 项，最多 2 个 child task 同时调用 provider。429/5xx 采用 0.5 秒、1 秒两次退避；退避和网络调用前后检查 `Task.checkCancellation()`。某批失败只把该批标为 `.failed`，其他批的合法结果仍写缓存。取消后不再启动新批次，已返回并验证通过的结果允许保留。

- [ ] **Step 5: 补齐并运行所有 coordinator 测试**

增加：21 项拆成 10/10/1、最大并发为 2、401 不重试、429 重试两次、取消停止新批次、响应缺项不覆盖旧缓存。

Run: `swift test --filter AIAnalysisCoordinatorTests`

Expected: 全部通过。

- [ ] **Step 6: 提交**

```bash
git add Sources/MacCleanerCore/Services/AIAnalysisCoordinator.swift \
  Tests/MacCleanerTests/Services/AIAnalysisCoordinatorTests.swift
git commit -m "Core: coordinate cached AI analysis requests"
```

### Task 7: AI Core 总体验收

**Files:**
- Modify only if verification exposes a regression in files touched by Tasks 1–6.

- [ ] **Step 1: 运行 AI 专项测试**

Run: `swift test --filter 'AIAssessment|AIFingerprint|DeepSeek|APIKey|AIAnalysis'`

Expected: 所有 AI 专项测试通过，0 issues。

- [ ] **Step 2: 运行完整测试和并发检查**

Run: `swift test`

Expected: 所有 suite 通过，0 issues。

Run: `swift build -Xswiftc -strict-concurrency=complete`

Expected: 编译成功；新增 AI 类型无并发安全警告。

- [ ] **Step 3: 审计敏感数据边界**

Run: `rg -n 'fileContent|environment|fullArguments|Authorization|api-key|sk-' Sources/MacCleanerCore Tests/MacCleanerTests`

Expected: `Authorization` 和 `api-key` 只出现在 DeepSeek/Keychain 实现及对应测试；生产模型和缓存中不存在 `fileContent`、`environment`、`fullArguments` 字段；生产源码不存在硬编码 `sk-` key。

- [ ] **Step 4: 检查缓存内容**

使用测试 key 发起一次单项分析后，打开 `~/Library/Application Support/DevClean/AI/assessments-v1.json`，确认只含 validated assessment、fingerprint 和时间戳，不含 key、请求头、文件内容、环境变量或完整 argv。
