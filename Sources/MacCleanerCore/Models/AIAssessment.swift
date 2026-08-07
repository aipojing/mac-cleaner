import Foundation

/// AI 风险评级。与 `AIRecommendation` 彼此独立，互不推导。
public enum AIRiskLevel: String, Codable, CaseIterable, Sendable {
    case low, medium, high, critical, unknown
}

/// AI 操作建议。只描述建议，不触发任何选择或执行。
public enum AIRecommendation: String, Codable, CaseIterable, Sendable {
    case delete, keep, inspect, unknown
}

/// AI 结论置信度。
public enum AIConfidence: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

/// AI 结论的结构校验错误。任何字段非法都不写缓存。
public enum AssessmentValidationError: Error, Equatable, Sendable {
    case emptySubjectID
    case invalidSummaryLength
    case invalidExplanationLength
    case invalidEvidence
    case mismatchedFingerprint
    case mismatchedSubjects
    case invalidSchema
}

/// 一次 AI 判断的结果。只包含解释、风险、建议和依据，
/// 不包含也不覆盖本地目标路径、PID、文件身份、执行命令或选择状态。
public struct AIAssessment: Codable, Equatable, Sendable {
    public static let summaryLength = 1...80
    public static let explanationLength = 1...800
    public static let evidenceItemLength = 1...160
    public static let evidenceCount = 1...8

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

    public init(
        subjectID: String,
        fingerprint: String,
        summary: String,
        explanation: String,
        risk: AIRiskLevel,
        recommendation: AIRecommendation,
        confidence: AIConfidence,
        evidence: [String],
        model: String,
        assessedAt: Date
    ) throws {
        guard !subjectID.isEmpty else { throw AssessmentValidationError.emptySubjectID }
        guard Self.summaryLength.contains(summary.count) else {
            throw AssessmentValidationError.invalidSummaryLength
        }
        guard Self.explanationLength.contains(explanation.count) else {
            throw AssessmentValidationError.invalidExplanationLength
        }
        guard Self.evidenceCount.contains(evidence.count),
              evidence.allSatisfy({ Self.evidenceItemLength.contains($0.count) }) else {
            throw AssessmentValidationError.invalidEvidence
        }
        self.subjectID = subjectID
        self.fingerprint = fingerprint
        self.summary = summary
        self.explanation = explanation
        self.risk = risk
        self.recommendation = recommendation
        self.confidence = confidence
        self.evidence = evidence
        self.model = model
        self.assessedAt = assessedAt
    }
}
