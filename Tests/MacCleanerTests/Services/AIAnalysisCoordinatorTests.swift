import Foundation
import Testing
@testable import MacCleanerCore

@Suite("AI analysis coordinator")
struct AIAnalysisCoordinatorTests {
    @Test("读取状态只查缓存，不调用 provider")
    func stateLookupNeverCallsNetwork() async throws {
        let provider = RecordingAssessmentProvider()
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: AIAssessmentCache(fileURL: temporaryURL()),
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore(key: "sk-test")
        )

        let state = try await coordinator.state(for: .cleanupFixture())

        #expect(state == .notAnalyzed)
        #expect(await provider.callCount == 0)
    }

    @Test("缓存命中直接展示；普通分析不请求，重查才请求并覆盖")
    func cachedAndForcedBehavior() async throws {
        let cache = AIAssessmentCache(fileURL: temporaryURL())
        try await cache.put(.fixture(
            subjectID: AIAssessmentSubject.cleanupFixture().subjectID,
            fingerprint: AIAssessmentSubject.cleanupFixture().fingerprint,
            summary: "cached"
        ))
        let provider = RecordingAssessmentProvider(results: nil, summary: "fresh")
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: cache,
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore(key: "sk-test")
        )

        #expect(try await coordinator.state(for: .cleanupFixture()).assessment?.summary == "cached")
        _ = await coordinator.analyze([.cleanupFixture()], forceRefresh: false)
        #expect(await provider.callCount == 0)
        _ = await coordinator.analyze([.cleanupFixture()], forceRefresh: true)
        #expect(await provider.callCount == 1)
        #expect(
            try await cache.lookup(fingerprint: AIAssessmentSubject.cleanupFixture().fingerprint)?.summary == "fresh"
        )
    }

    @Test("重查失败保留旧结果")
    func failedRefreshPreservesCache() async throws {
        let cached = try AIAssessment.fixture(
            subjectID: AIAssessmentSubject.cleanupFixture().subjectID,
            fingerprint: AIAssessmentSubject.cleanupFixture().fingerprint,
            summary: "cached"
        )
        let cache = AIAssessmentCache(fileURL: temporaryURL())
        try await cache.put(cached)
        let provider = RecordingAssessmentProvider(error: TestError.offline)
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: cache,
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore(key: "sk-test")
        )

        let states = await coordinator.analyze([.cleanupFixture()], forceRefresh: true)

        #expect(states[cached.subjectID]?.assessment == cached)
        #expect(try await cache.lookup(fingerprint: cached.fingerprint) == cached)
    }

    @Test("未配置 key 返回 notConfigured，不调用 provider")
    func unconfiguredNeverCallsProvider() async throws {
        let provider = RecordingAssessmentProvider()
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: AIAssessmentCache(fileURL: temporaryURL()),
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore()
        )

        #expect(try await coordinator.state(for: .cleanupFixture()) == .notConfigured)
        let states = await coordinator.analyze([.cleanupFixture()], forceRefresh: true)
        #expect(states[AIAssessmentSubject.cleanupFixture().subjectID] == .notConfigured)
        #expect(await provider.callCount == 0)
    }

    @Test("21 项拆成 10/10/1 三批")
    func batchesOfTen() async throws {
        let subjects = (0..<21).map {
            AIAssessmentSubject.cleanupFixture(
                id: "cleanup:\($0)",
                fingerprint: String(format: "%064x", $0 + 1)
            )
        }
        let provider = RecordingAssessmentProvider()
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: AIAssessmentCache(fileURL: temporaryURL()),
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore(key: "sk-test")
        )

        let states = await coordinator.analyze(subjects, forceRefresh: false)

        #expect(await provider.batchSizes == [10, 10, 1])
        #expect(states.count == 21)
        #expect(states.values.allSatisfy { $0.assessment != nil })
    }

    @Test("最大并发为 2")
    func concurrencyLimitedToTwo() async throws {
        let subjects = (0..<40).map {
            AIAssessmentSubject.cleanupFixture(
                id: "cleanup:\($0)",
                fingerprint: String(format: "%064x", $0 + 1)
            )
        }
        let provider = RecordingAssessmentProvider(gated: true)
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: AIAssessmentCache(fileURL: temporaryURL()),
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore(key: "sk-test")
        )

        async let analysis: [String: AIAssessmentState] = coordinator.analyze(subjects, forceRefresh: false)
        await provider.waitForCalls(2)
        #expect(await provider.maxInFlight <= 2)
        await provider.openGate()
        _ = await analysis
        #expect(await provider.maxInFlight == 2)
    }

    @Test("401 不重试")
    func authenticationNotRetried() async throws {
        let provider = RecordingAssessmentProvider(error: DeepSeekClientError.authentication)
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: AIAssessmentCache(fileURL: temporaryURL()),
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore(key: "sk-test")
        )

        _ = await coordinator.analyze([.cleanupFixture()], forceRefresh: false)

        #expect(await provider.callCount == 1)
    }

    @Test("429 最多退避重试两次")
    func rateLimitRetriedTwice() async throws {
        let provider = RecordingAssessmentProvider(errors: [
            DeepSeekClientError.rateLimited(retryAfter: nil),
            DeepSeekClientError.rateLimited(retryAfter: nil),
            DeepSeekClientError.rateLimited(retryAfter: nil),
        ])
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: AIAssessmentCache(fileURL: temporaryURL()),
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore(key: "sk-test")
        )

        let states = await coordinator.analyze([.cleanupFixture()], forceRefresh: false)

        #expect(await provider.callCount == 3)
        #expect(states[AIAssessmentSubject.cleanupFixture().subjectID]?.assessment == nil)
    }

    @Test("429 后成功则写缓存")
    func rateLimitThenSuccess() async throws {
        let provider = RecordingAssessmentProvider(errors: [
            DeepSeekClientError.rateLimited(retryAfter: nil),
        ])
        let cache = AIAssessmentCache(fileURL: temporaryURL())
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: cache,
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore(key: "sk-test")
        )

        let states = await coordinator.analyze([.cleanupFixture()], forceRefresh: false)

        #expect(await provider.callCount == 2)
        #expect(states[AIAssessmentSubject.cleanupFixture().subjectID]?.assessment != nil)
        #expect(
            try await cache.lookup(fingerprint: AIAssessmentSubject.cleanupFixture().fingerprint) != nil
        )
    }

    @Test("取消后不再启动新批次")
    func cancelStopsNewBatches() async throws {
        let subjects = (0..<30).map {
            AIAssessmentSubject.cleanupFixture(
                id: "cleanup:\($0)",
                fingerprint: String(format: "%064x", $0 + 1)
            )
        }
        let provider = RecordingAssessmentProvider(gated: true)
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: AIAssessmentCache(fileURL: temporaryURL()),
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore(key: "sk-test")
        )

        async let analysis: [String: AIAssessmentState] = coordinator.analyze(subjects, forceRefresh: false)
        await provider.waitForCalls(2)
        await coordinator.cancelCurrentAnalysis()
        await provider.openGate()
        let states = await analysis

        // 只有第一批在飞的两个请求完成，其余批次不启动
        #expect(await provider.callCount <= 2)
        #expect(states.values.filter { $0.assessment != nil }.count <= 20)
    }

    @Test("响应缺项不覆盖旧缓存")
    func partialResponseDoesNotOverwriteCache() async throws {
        let subject = AIAssessmentSubject.cleanupFixture()
        let cached = try AIAssessment.fixture(
            subjectID: subject.subjectID,
            fingerprint: subject.fingerprint,
            summary: "cached"
        )
        let cache = AIAssessmentCache(fileURL: temporaryURL())
        try await cache.put(cached)
        let provider = RecordingAssessmentProvider(results: [])
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: cache,
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore(key: "sk-test")
        )

        let states = await coordinator.analyze([subject], forceRefresh: true)

        #expect(try await cache.lookup(fingerprint: subject.fingerprint) == cached)
        #expect(states[subject.subjectID]?.assessment == cached)
    }

    private func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-ai-coordinator-\(UUID().uuidString).json")
    }
}

extension AIAnalysisCoordinatorTests {
    @Test("删除 key 后缓存命中仍然可见，缓存缺失才报 notConfigured")
    func cachedVisibleWithoutKey() async throws {
        let cache = AIAssessmentCache(fileURL: temporaryURL())
        let subject = AIAssessmentSubject.cleanupFixture()
        try await cache.put(.fixture(
            subjectID: subject.subjectID,
            fingerprint: subject.fingerprint,
            summary: "cached"
        ))
        let provider = RecordingAssessmentProvider()
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: cache,
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore()  // 未配置 key
        )

        // 缓存命中：无 key 也要展示
        #expect(try await coordinator.state(for: subject).assessment?.summary == "cached")
        // 缓存缺失：无 key 报 notConfigured
        let missing = AIAssessmentSubject.cleanupFixture(
            id: "cleanup:other",
            fingerprint: String(repeating: "b", count: 64)
        )
        #expect(try await coordinator.state(for: missing) == .notConfigured)
        #expect(await provider.callCount == 0)
    }
}

extension AIAnalysisCoordinatorTests {
    @Test("无 key 时重查保留缓存卡片，不调用 provider")
    func analyzeWithoutKeyPreservesCache() async throws {
        let cache = AIAssessmentCache(fileURL: temporaryURL())
        let cachedSubject = AIAssessmentSubject.cleanupFixture()
        try await cache.put(.fixture(
            subjectID: cachedSubject.subjectID,
            fingerprint: cachedSubject.fingerprint,
            summary: "cached"
        ))
        let uncachedSubject = AIAssessmentSubject.cleanupFixture(
            id: "cleanup:uncached",
            fingerprint: String(repeating: "c", count: 64)
        )
        let provider = RecordingAssessmentProvider()
        let coordinator = AIAnalysisCoordinator(
            provider: provider,
            cache: cache,
            retryClock: ImmediateRetryClock(),
            keyManager: InMemoryAPIKeyStore()  // 未配置 key
        )

        let states = await coordinator.analyze(
            [cachedSubject, uncachedSubject],
            forceRefresh: true
        )

        #expect(states[cachedSubject.subjectID]?.assessment?.summary == "cached",
                "缓存命中项必须保留旧卡片")
        #expect(states[uncachedSubject.subjectID] == .notConfigured)
        #expect(await provider.callCount == 0)
    }
}
