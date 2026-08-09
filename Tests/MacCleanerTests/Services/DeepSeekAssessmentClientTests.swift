import Foundation
import Testing
@testable import MacCleanerCore

@Suite("DeepSeek assessment client")
struct DeepSeekAssessmentClientTests {
    @Test("请求使用当前保存的模型 ID 和 Base URL")
    func usesCurrentSavedConfiguration() async throws {
        let suiteName = "DeepSeekAssessmentClientTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = UserDefaultsDeepSeekConfigurationStore(defaults: defaults)
        let transport = MockHTTPTransport(response: .validToolResponse())
        let client = DeepSeekAssessmentClient(
            configurationProvider: configurationStore,
            keyStore: InMemoryAPIKeyStore(key: "sk-secret"),
            transport: transport
        )
        try configurationStore.update(
            model: "deepseek-v4-flash",
            baseURL: "https://api.deepseek.com/beta"
        )

        _ = try await client.assess([.cleanupFixture()])

        let request = try #require(await transport.lastRequest)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/beta/chat/completions")
        #expect(body.contains("\"model\":\"deepseek-v4-flash\""))
    }

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

        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret")
        #expect(body.contains("submit_assessments"))
        #expect(body.contains("tool_choice"))
        #expect(body.contains("\"temperature\":0"))
        #expect(body.contains("\"stream\":false"))
        #expect(!body.contains("fileContent"))
        #expect(!body.contains("environment"))
        #expect(!body.contains("fullArguments"))
        #expect(!body.contains("sk-secret"))
    }

    @Test("合法工具响应解析为完整结论")
    func parsesValidResponse() async throws {
        let client = DeepSeekAssessmentClient.fixture(response: .validToolResponse())
        let results = try await client.assess([.cleanupFixture()])

        #expect(results.count == 1)
        let first = try #require(results.first)
        #expect(first.subjectID == AIAssessmentSubject.cleanupFixture().subjectID)
        #expect(first.fingerprint == AIAssessmentSubject.cleanupFixture().fingerprint)
        #expect(first.risk == .low)
        #expect(first.recommendation == .delete)
        #expect(first.model == "deepseek-v4-pro")
    }

    @Test(arguments: [401, 403])
    func mapsAuthenticationFailures(status: Int) async {
        let client = DeepSeekAssessmentClient.fixture(status: status)
        await #expect(throws: DeepSeekClientError.authentication) {
            try await client.assess([.cleanupFixture()])
        }
    }

    @Test("429 映射为限流并携带 Retry-After")
    func mapsRateLimit() async {
        let client = DeepSeekAssessmentClient.fixture(status: 429, headers: ["Retry-After": "2"])
        await #expect(throws: DeepSeekClientError.rateLimited(retryAfter: 2)) {
            try await client.assess([.cleanupFixture()])
        }
    }

    @Test("5xx 映射为服务不可用")
    func mapsServerFailures() async {
        let client = DeepSeekAssessmentClient.fixture(status: 500)
        await #expect(throws: DeepSeekClientError.serviceUnavailable) {
            try await client.assess([.cleanupFixture()])
        }
    }

    @Test("其他非 2xx 映射为 httpStatus")
    func mapsOtherStatuses() async {
        let client = DeepSeekAssessmentClient.fixture(status: 418)
        await #expect(throws: DeepSeekClientError.httpStatus(418)) {
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

    @Test("缺失、多余或重复 subject 都被拒绝")
    func rejectsMismatchedSubjects() async {
        for response in [MockHTTPResponse.missingSubjectResponse(),
                         .extraSubjectResponse(),
                         .duplicateSubjectResponse()] {
            let client = DeepSeekAssessmentClient.fixture(response: response)
            await #expect(throws: AssessmentValidationError.self) {
                try await client.assess([.cleanupFixture()])
            }
        }
    }

    @Test("fingerprint 与输入不一致被拒绝")
    func rejectsMismatchedFingerprint() async {
        let client = DeepSeekAssessmentClient.fixture(response: .wrongFingerprintResponse())
        await #expect(throws: AssessmentValidationError.self) {
            try await client.assess([.cleanupFixture()])
        }
    }


    @Test("缺少 submit_assessments 工具调用被拒绝")
    func rejectsMissingToolCall() async {
        let client = DeepSeekAssessmentClient.fixture(response: .plainTextResponse())
        await #expect(throws: AssessmentValidationError.self) {
            try await client.assess([.cleanupFixture()])
        }
    }

    // MARK: - 连接检查

    @Test("连接检查只发送凭据，不携带本地数据")
    func connectionCheckSendsNoLocalData() async throws {
        let transport = MockHTTPTransport(status: 200)
        let client = DeepSeekAssessmentClient(
            configuration: DeepSeekConfiguration(),
            keyStore: InMemoryAPIKeyStore(key: "sk-secret"),
            transport: transport
        )

        try await client.checkConnection()

        let request = try #require(await transport.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.deepseek.com/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret")
        #expect(request.httpBody == nil, "连接检查不得携带 body")
    }

    @Test("连接检查沿用统一错误映射")
    func connectionCheckMapsErrors() async {
        let unauthorized = DeepSeekAssessmentClient.fixture(status: 401)
        await #expect(throws: DeepSeekClientError.authentication) {
            try await unauthorized.checkConnection()
        }

        let limited = DeepSeekAssessmentClient.fixture(status: 429, headers: ["Retry-After": "5"])
        await #expect(throws: DeepSeekClientError.rateLimited(retryAfter: 5)) {
            try await limited.checkConnection()
        }

        let down = DeepSeekAssessmentClient.fixture(status: 503)
        await #expect(throws: DeepSeekClientError.serviceUnavailable) {
            try await down.checkConnection()
        }
    }
}


@Suite("DeepSeek tool call configuration")
struct DeepSeekToolCallConfigurationTests {
    @Test("默认基础地址使用公开 Chat API")
    func defaultBaseURLUsesPublicChatAPI() {
        #expect(DeepSeekConfiguration.defaultBaseURL.absoluteString == "https://api.deepseek.com")
    }

    @Test("工具 schema 不含服务端方言约束关键字")
    func schemaAvoidsServiceSpecificConstraints() {
        let data = try! JSONSerialization.data(withJSONObject: DeepSeekRequestSchema.toolParameters)
        let json = String(decoding: data, as: UTF8.self)
        for key in ["minLength", "maxLength", "minItems", "maxItems"] {
            #expect(!json.contains("\"\(key)\""), "工具 schema 不得包含 \(key)")
        }
        // 每个 object 均禁止额外字段，便于本地严格校验返回结果。
        #expect(json.contains("\"additionalProperties\":false"))
    }
}

extension DeepSeekToolCallConfigurationTests {
    @Test("默认请求使用公开地址且不启用 strict Beta 模式")
    func defaultRequestUsesPublicEndpointWithoutStrictMode() async throws {
        let transport = MockHTTPTransport(response: .validToolResponse())
        let client = DeepSeekAssessmentClient(
            configuration: DeepSeekConfiguration(),
            keyStore: InMemoryAPIKeyStore(key: "sk-secret"),
            transport: transport
        )

        _ = try await client.assess([.cleanupFixture()])

        let request = try #require(await transport.lastRequest)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(!body.contains("\"strict\":true"))
    }

    @Test("请求显式关闭 thinking（V4 默认开启，与强制 tool_choice 冲突）")
    func requestDisablesThinking() async throws {
        let transport = MockHTTPTransport(response: .validToolResponse())
        let client = DeepSeekAssessmentClient(
            configuration: DeepSeekConfiguration(),
            keyStore: InMemoryAPIKeyStore(key: "sk-secret"),
            transport: transport
        )
        _ = try await client.assess([.cleanupFixture()])
        let request = try #require(await transport.lastRequest)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)

        #expect(body.contains("\"thinking\""), "必须显式设置 thinking 参数")
        #expect(body.contains("\"disabled\""), "thinking 必须显式 disabled")
    }
}
