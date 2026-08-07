import Foundation

/// 单个对象的 AI 判断视图状态。状态独立于用户选择状态，
/// AI 状态变化不得改动选择。
public enum AIAssessmentState: Equatable, Sendable {
    /// 未配置 API Key。
    case notConfigured
    /// 缓存缺失且未请求过；不自动触发网络请求。
    case notAnalyzed
    /// 本地缓存命中，直接展示。
    case cached(AIAssessment)
    /// 用户已发起请求，等待结果。
    case loading(previous: AIAssessment?)
    /// 本次请求刚返回并通过校验。
    case fresh(AIAssessment)
    /// 请求或校验失败；重查失败时保留旧结果。
    case failed(message: String, previous: AIAssessment?)

    public var assessment: AIAssessment? {
        switch self {
        case let .cached(value), let .fresh(value): value
        case let .loading(previous), let .failed(_, previous): previous
        case .notConfigured, .notAnalyzed: nil
        }
    }
}
