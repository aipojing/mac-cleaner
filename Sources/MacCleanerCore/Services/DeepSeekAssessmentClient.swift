import Foundation

public struct DeepSeekConfiguration: Equatable, Sendable {
    /// strict tool call 属于 Beta 特性，官方要求使用 /beta 基础地址。
    /// 见 https://api-docs.deepseek.com/guides/tool_calls/
    public static let defaultBaseURL = URL(string: "https://api.deepseek.com/beta")!
    public static let defaultModel = "deepseek-v4-pro"

    public let baseURL: URL
    public let model: String
    public let timeout: TimeInterval

    public init(
        baseURL: URL = DeepSeekConfiguration.defaultBaseURL,
        model: String = DeepSeekConfiguration.defaultModel,
        timeout: TimeInterval = 60
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }
}

public enum DeepSeekClientError: Error, Equatable, Sendable {
    case authentication
    case rateLimited(retryAfter: TimeInterval?)
    case serviceUnavailable
    case httpStatus(Int)
    case transport
    case invalidResponse
}

/// DeepSeek 结构化 provider。只负责解释、风险评级和推荐；
/// 自身不重试（重试由 coordinator 统一控制以便响应取消），
/// 不缓存结果，不记录请求头或 key。
public struct DeepSeekAssessmentClient: AIAssessmentProviding {
    public static let maxSubjectsPerRequest = 10

    private let configuration: DeepSeekConfiguration
    private let keyStore: any APIKeyProviding
    private let transport: any HTTPTransporting
    private let now: @Sendable () -> Date

    public init(
        configuration: DeepSeekConfiguration = DeepSeekConfiguration(),
        keyStore: any APIKeyProviding,
        transport: any HTTPTransporting = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.keyStore = keyStore
        self.transport = transport
        self.now = now
    }

    public func assess(_ subjects: [AIAssessmentSubject]) async throws -> [AIAssessment] {
        guard (1...Self.maxSubjectsPerRequest).contains(subjects.count) else {
            throw AssessmentValidationError.mismatchedSubjects
        }

        let request = try keyStore.withAPIKey { key in
            try buildRequest(subjects: subjects, apiKey: key)
        }

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw DeepSeekClientError.transport
        }

        try mapStatus(response)

        let decoded: DeepSeekChatResponse
        do {
            decoded = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        } catch {
            throw AssessmentValidationError.invalidSchema
        }
        return try validate(decoded, against: subjects)
    }

    // MARK: - 请求构造

    /// key 只进入 Authorization 请求头，不写入日志或缓存。
    private func buildRequest(subjects: [AIAssessmentSubject], apiKey: String) throws -> URLRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let subjectsJSON = String(decoding: try encoder.encode(subjects), as: UTF8.self)

        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "stream": false,
            // V4 默认启用 thinking，而 thinking 模式与强制 tool_choice 冲突
            // （服务端会 400），且 thinking 下 temperature 无效；本场景是单轮
            // 严格结构化工具调用，显式关闭 thinking。
            // 见 https://api-docs.deepseek.com/guides/thinking_mode
            "thinking": ["type": "disabled"],
            "messages": [
                ["role": "system", "content": DeepSeekRequestSchema.systemPrompt],
                ["role": "user", "content": "分析以下对象的元数据事实：\n\(subjectsJSON)"],
            ],
            "tools": [[
                "type": "function",
                "function": [
                    "name": DeepSeekRequestSchema.toolName,
                    "description": "提交对每个对象的结构化分析结论。",
                    "strict": true,
                    "parameters": DeepSeekRequestSchema.toolParameters,
                ] as [String: Any],
            ]],
            "tool_choice": [
                "type": "function",
                "function": ["name": DeepSeekRequestSchema.toolName],
            ],
        ]

        var request = URLRequest(
            url: configuration.baseURL.appendingPathComponent("chat/completions"),
            timeoutInterval: configuration.timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - 状态映射

    private func mapStatus(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw DeepSeekClientError.authentication
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw DeepSeekClientError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            throw DeepSeekClientError.serviceUnavailable
        default:
            throw DeepSeekClientError.httpStatus(response.statusCode)
        }
    }

    // MARK: - 响应校验

    /// 只解析 `submit_assessments` 工具调用；校验响应数量、subject ID
    /// 集合和 fingerprint 与本次输入完全一致，拒绝重复、缺失、多余项。
    private func validate(
        _ response: DeepSeekChatResponse,
        against subjects: [AIAssessmentSubject]
    ) throws -> [AIAssessment] {
        let toolCall = response.choices
            .flatMap { $0.message.toolCalls ?? [] }
            .first { $0.function.name == DeepSeekRequestSchema.toolName }
        guard let toolCall else { throw AssessmentValidationError.invalidSchema }

        let arguments: SubmitAssessmentsArguments
        do {
            arguments = try JSONDecoder().decode(
                SubmitAssessmentsArguments.self,
                from: Data(toolCall.function.arguments.utf8)
            )
        } catch {
            throw AssessmentValidationError.invalidSchema
        }

        let payloads = arguments.assessments
        guard payloads.count == subjects.count,
              Set(payloads.map(\.subjectID)).count == payloads.count else {
            throw AssessmentValidationError.mismatchedSubjects
        }

        var byID: [String: SubmitAssessmentsArguments.AssessmentPayload] = [:]
        for payload in payloads {
            byID[payload.subjectID] = payload
        }

        return try subjects.map { subject in
            guard let payload = byID[subject.subjectID] else {
                throw AssessmentValidationError.mismatchedSubjects
            }
            guard payload.fingerprint == subject.fingerprint else {
                throw AssessmentValidationError.mismatchedFingerprint
            }
            guard let risk = AIRiskLevel(rawValue: payload.risk),
                  let recommendation = AIRecommendation(rawValue: payload.recommendation),
                  let confidence = AIConfidence(rawValue: payload.confidence) else {
                throw AssessmentValidationError.invalidSchema
            }
            return try AIAssessment(
                subjectID: payload.subjectID,
                fingerprint: payload.fingerprint,
                summary: payload.summary,
                explanation: payload.explanation,
                risk: risk,
                recommendation: recommendation,
                confidence: confidence,
                evidence: payload.evidence,
                model: response.model,
                assessedAt: now()
            )
        }
    }
}

// MARK: - 连接检查

extension DeepSeekAssessmentClient: DeepSeekConnectionChecking {
    /// `GET /models`：只携带 Authorization 和 Accept，不带 body，
    /// 不构造 subject、prompt 或缓存记录。strict tool call 的 `/beta`
    /// 只用于分析接口，模型列表仍使用官方根地址。401/403/429/5xx
    /// 沿用统一错误映射。
    public func checkConnection() async throws {
        let request = try keyStore.withAPIKey { key -> URLRequest in
            let modelsBaseURL = configuration.baseURL.lastPathComponent == "beta"
                ? configuration.baseURL.deletingLastPathComponent()
                : configuration.baseURL
            var request = URLRequest(
                url: modelsBaseURL.appendingPathComponent("models"),
                timeoutInterval: configuration.timeout
            )
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return request
        }

        let (_, response): (Data, HTTPURLResponse)
        do {
            (_, response) = try await transport.data(for: request)
        } catch {
            throw DeepSeekClientError.transport
        }

        try mapStatus(response)
    }
}
