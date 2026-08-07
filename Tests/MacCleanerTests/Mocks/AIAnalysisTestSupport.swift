import Foundation
@testable import MacCleanerCore

enum TestError: Error, Equatable {
    case offline
}

/// 立即返回的退避时钟：测试不等待真实退避。
struct ImmediateRetryClock: AIRetryClock {
    func sleep(forAttempt attempt: Int, retryAfter: TimeInterval?) async throws {}
}

/// 记录调用并可预制结果/错误的 provider。
/// 支持 gate 阻塞（测试并发上限与取消），不访问真实网络。
actor RecordingAssessmentProvider: AIAssessmentProviding {
    private let fixedResults: [AIAssessment]?
    private let summary: String
    private let repeatingError: (any Error)?
    private var errorQueue: [any Error]
    private var gated: Bool
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private(set) var callCount = 0
    private(set) var batchSizes: [Int] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    /// - Parameters:
    ///   - error: 每次调用都抛出该错误。
    ///   - errors: 按调用顺序依次抛出的错误队列，耗尽后返回成功。
    init(
        results: [AIAssessment]? = nil,
        summary: String = "fresh",
        error: (any Error)? = nil,
        errors: [any Error] = [],
        gated: Bool = false
    ) {
        fixedResults = results
        self.summary = summary
        repeatingError = error
        errorQueue = errors
        self.gated = gated
    }

    func waitForCalls(_ target: Int) async {
        if callCount >= target { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((target, continuation))
        }
    }

    func openGate() {
        gated = false
        let waiters = gateWaiters
        gateWaiters = []
        waiters.forEach { $0.resume() }
    }

    func assess(_ subjects: [AIAssessmentSubject]) async throws -> [AIAssessment] {
        callCount += 1
        batchSizes.append(subjects.count)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)

        let ready = callWaiters.filter { callCount >= $0.target }
        callWaiters.removeAll { callCount >= $0.target }
        ready.forEach { $0.continuation.resume() }

        if gated {
            await withCheckedContinuation { gateWaiters.append($0) }
        }
        inFlight -= 1

        if let repeatingError { throw repeatingError }
        if !errorQueue.isEmpty { throw errorQueue.removeFirst() }
        if let fixedResults { return fixedResults }
        return subjects.map {
            // swiftlint:disable:next force_try
            (try! AIAssessment.fixture(
                subjectID: $0.subjectID,
                fingerprint: $0.fingerprint,
                summary: summary
            ))
        }
    }
}
