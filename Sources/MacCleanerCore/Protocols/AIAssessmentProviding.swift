import Foundation

/// AI provider 边界。实现只返回解释、风险和建议，
/// 不参与选择、删除或进程终止。
public protocol AIAssessmentProviding: Sendable {
    func assess(_ subjects: [AIAssessmentSubject]) async throws -> [AIAssessment]
}

/// 连接检查边界。请求只携带凭据，不构造 subject、prompt 或缓存记录。
public protocol DeepSeekConnectionChecking: Sendable {
    func checkConnection() async throws
}
