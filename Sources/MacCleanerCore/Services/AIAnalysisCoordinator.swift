import Foundation

/// 退避时钟边界：便于测试替换为立即返回的实现。
public protocol AIRetryClock: Sendable {
    func sleep(forAttempt attempt: Int, retryAfter: TimeInterval?) async throws
}

/// 生产退避时钟：429/5xx 按 0.5 秒、1 秒两次退避，尊重 Retry-After。
public struct BackoffRetryClock: AIRetryClock {
    public init() {}

    public func sleep(forAttempt attempt: Int, retryAfter: TimeInterval?) async throws {
        let delay = retryAfter ?? (attempt == 0 ? 0.5 : 1.0)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}

/// 编排显式 AI 分析：缓存命中不联网，只有用户显式 analyze
/// 才调用 provider。每批最多 10 项、最多 2 个并发请求，支持取消；
/// 重查失败保留旧缓存。AI 结果不改变任何选择状态。
public actor AIAnalysisCoordinator {
    public static let maxBatchSize = 10
    public static let maxConcurrentBatches = 2
    public static let maxRetries = 2

    private let provider: any AIAssessmentProviding
    private let cache: AIAssessmentCache
    private let keyManager: any APIKeyManaging
    private let retryClock: any AIRetryClock
    private var generation: UInt64 = 0

    public init(
        provider: any AIAssessmentProviding,
        cache: AIAssessmentCache,
        retryClock: any AIRetryClock = BackoffRetryClock(),
        keyManager: any APIKeyManaging = UserDefaultsAPIKeyStore()
    ) {
        self.provider = provider
        self.cache = cache
        self.retryClock = retryClock
        self.keyManager = keyManager
    }

    /// 只读本地缓存和 API Key 配置状态，不调用 provider。
    /// 缓存命中时无论是否配置 key 都直接展示——删除 key 不影响已有缓存；
    /// 缓存缺失时才区分 notConfigured / notAnalyzed。
    public func state(for subject: AIAssessmentSubject) async throws -> AIAssessmentState {
        if let cached = try await cache.lookup(fingerprint: subject.fingerprint) {
            return .cached(cached)
        }
        guard (try? keyManager.isConfigured()) ?? false else { return .notConfigured }
        return .notAnalyzed
    }

    /// 批量只读状态查询，同样不触发网络请求。
    public func states(for subjects: [AIAssessmentSubject]) async -> [String: AIAssessmentState] {
        var result: [String: AIAssessmentState] = [:]
        for subject in subjects {
            if let state = try? await state(for: subject) {
                result[subject.subjectID] = state
            }
        }
        return result
    }

    /// 用户显式发起的分析。`forceRefresh: false` 时缓存命中项不请求；
    /// `true` 时重查全部，失败保留旧缓存。
    public func analyze(
        _ subjects: [AIAssessmentSubject],
        forceRefresh: Bool
    ) async -> [String: AIAssessmentState] {
        guard (try? keyManager.isConfigured()) ?? false else {
            // 未配置 key：不发起任何请求。缓存命中项保留展示
            // （删除 key 不影响已有缓存），只有缓存缺失项才报 notConfigured。
            var states: [String: AIAssessmentState] = [:]
            for subject in subjects {
                if let cached = try? await cache.lookup(fingerprint: subject.fingerprint) {
                    states[subject.subjectID] = .cached(cached)
                } else {
                    states[subject.subjectID] = .notConfigured
                }
            }
            return states
        }

        let generationAtStart = generation
        var result: [String: AIAssessmentState] = [:]
        var pending: [AIAssessmentSubject] = []

        for subject in subjects {
            if !forceRefresh,
               let cached = try? await cache.lookup(fingerprint: subject.fingerprint) {
                result[subject.subjectID] = .cached(cached)
            } else {
                pending.append(subject)
            }
        }

        var batches: [[AIAssessmentSubject]] = []
        var offset = 0
        while offset < pending.count {
            batches.append(Array(pending[offset..<min(offset + Self.maxBatchSize, pending.count)]))
            offset += Self.maxBatchSize
        }

        var index = 0
        while index < batches.count {
            if Task.isCancelled || generation != generationAtStart { break }
            let slice = Array(batches[index..<min(index + Self.maxConcurrentBatches, batches.count)])
            let outcomes = await withTaskGroup(of: [String: AIAssessmentState].self) { group in
                for batch in slice {
                    group.addTask { await self.performBatch(batch, generation: generationAtStart) }
                }
                var collected: [String: AIAssessmentState] = [:]
                for await states in group {
                    collected.merge(states) { _, new in new }
                }
                return collected
            }
            result.merge(outcomes) { _, new in new }
            index += slice.count
        }

        // 取消后未启动的批次不请求，标记为已取消并保留旧缓存。
        if index < batches.count {
            for batch in batches[index...] {
                for subject in batch {
                    result[subject.subjectID] = await cancelledState(for: subject)
                }
            }
        }
        return result
    }

    /// 取消当前分析：不再启动新批次，在飞请求完成后不再覆盖状态。
    public func cancelCurrentAnalysis() {
        generation += 1
    }

    // MARK: - 私有

    private func performBatch(
        _ batch: [AIAssessmentSubject],
        generation generationAtStart: UInt64
    ) async -> [String: AIAssessmentState] {
        var attempt = 0
        while true {
            if Task.isCancelled || generation != generationAtStart {
                return await cancelledStates(batch)
            }
            do {
                let assessments = try await provider.assess(batch)
                if Task.isCancelled || generation != generationAtStart {
                    return await cancelledStates(batch)
                }
                var states: [String: AIAssessmentState] = [:]
                for assessment in assessments {
                    try? await cache.put(assessment)
                    states[assessment.subjectID] = .fresh(assessment)
                }
                // 响应缺项：标记失败，不覆盖旧缓存
                for subject in batch where states[subject.subjectID] == nil {
                    states[subject.subjectID] = await failedState(
                        for: subject,
                        message: "AI 响应缺少该对象"
                    )
                }
                return states
            } catch let error as DeepSeekClientError {
                switch error {
                case let .rateLimited(retryAfter):
                    if attempt < Self.maxRetries, await retryBackoff(attempt: attempt, retryAfter: retryAfter) {
                        attempt += 1
                        continue
                    }
                    return await failedStates(batch, message: "请求过于频繁，请稍后重试")
                case .serviceUnavailable:
                    if attempt < Self.maxRetries, await retryBackoff(attempt: attempt, retryAfter: nil) {
                        attempt += 1
                        continue
                    }
                    return await failedStates(batch, message: "AI 服务暂时不可用")
                case .authentication:
                    return await failedStates(batch, message: "API Key 无效，请检查设置")
                case .httpStatus(let status):
                    return await failedStates(batch, message: "请求失败（HTTP \(status)）")
                case .transport:
                    return await failedStates(batch, message: "网络连接失败")
                case .invalidResponse:
                    return await failedStates(batch, message: "AI 返回结果无法验证")
                }
            } catch {
                if error is CancellationError {
                    return await cancelledStates(batch)
                }
                return await failedStates(batch, message: "AI 返回结果无法验证")
            }
        }
    }

    /// 退避并检查取消；返回 false 表示已取消，不应继续重试。
    private func retryBackoff(attempt: Int, retryAfter: TimeInterval?) async -> Bool {
        do {
            try await retryClock.sleep(forAttempt: attempt, retryAfter: retryAfter)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func failedStates(_ batch: [AIAssessmentSubject], message: String) async -> [String: AIAssessmentState] {
        var states: [String: AIAssessmentState] = [:]
        for subject in batch {
            states[subject.subjectID] = await failedState(for: subject, message: message)
        }
        return states
    }

    private func failedState(for subject: AIAssessmentSubject, message: String) async -> AIAssessmentState {
        let previous = try? await cache.lookup(fingerprint: subject.fingerprint)
        return .failed(message: message, previous: previous ?? nil)
    }

    private func cancelledStates(_ batch: [AIAssessmentSubject]) async -> [String: AIAssessmentState] {
        var states: [String: AIAssessmentState] = [:]
        for subject in batch {
            states[subject.subjectID] = await cancelledState(for: subject)
        }
        return states
    }

    private func cancelledState(for subject: AIAssessmentSubject) async -> AIAssessmentState {
        let previous = try? await cache.lookup(fingerprint: subject.fingerprint)
        return .failed(message: "分析已取消", previous: previous ?? nil)
    }
}
