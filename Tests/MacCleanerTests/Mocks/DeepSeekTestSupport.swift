import Foundation
@testable import MacCleanerCore

/// 内存 API Key 存储：实现管理/提供协议，不触碰真实 Keychain。
final class InMemoryAPIKeyStore: APIKeyManaging, APIKeyProviding, @unchecked Sendable {
    private var key: String?

    init(key: String? = nil) {
        self.key = key
    }

    func isConfigured() throws -> Bool { key != nil }

    func set(_ key: String) throws { self.key = key }

    func delete() throws { key = nil }

    func withAPIKey<T>(_ body: (String) throws -> T) throws -> T {
        guard let key else { throw APIKeyStoreError.notConfigured }
        return try body(key)
    }
}

/// 预制的 HTTP 响应。
struct MockHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// 合法的 submit_assessments 工具响应，匹配 `.cleanupFixture()`。
    static func validToolResponse(
        subjectID: String = AIAssessmentSubject.cleanupFixture().subjectID,
        fingerprint: String = AIAssessmentSubject.cleanupFixture().fingerprint,
        risk: String = "low"
    ) -> MockHTTPResponse {
        chatResponse(payloads: [[
            "subject_id": subjectID,
            "fingerprint": fingerprint,
            "summary": "应用缓存目录",
            "explanation": "应用运行时生成的缓存数据，删除后应用会按需重建，不影响用户数据。",
            "risk": risk,
            "recommendation": "delete",
            "confidence": "medium",
            "evidence": ["位于 Library/Caches 下", "由应用自动重建"],
        ]])
    }

    static func invalidRiskResponse() -> MockHTTPResponse {
        validToolResponse(risk: "extreme")
    }

    static func missingSubjectResponse() -> MockHTTPResponse {
        chatResponse(payloads: [])
    }

    static func extraSubjectResponse() -> MockHTTPResponse {
        chatResponse(payloads: [
            validPayload(),
            validPayload(subjectID: "cleanup:other", fingerprint: String(repeating: "c", count: 64)),
        ])
    }

    static func duplicateSubjectResponse() -> MockHTTPResponse {
        chatResponse(payloads: [validPayload(), validPayload()])
    }

    static func wrongFingerprintResponse() -> MockHTTPResponse {
        chatResponse(payloads: [validPayload(fingerprint: String(repeating: "c", count: 64))])
    }

    /// 无工具调用的纯文本响应。
    static func plainTextResponse() -> MockHTTPResponse {
        let body: [String: Any] = [
            "model": "deepseek-v4-pro",
            "choices": [[
                "message": ["role": "assistant", "content": "这是普通文本回复"],
            ]],
        ]
        return MockHTTPResponse(
            status: 200,
            body: try! JSONSerialization.data(withJSONObject: body)
        )
    }

    private static func validPayload(
        subjectID: String = AIAssessmentSubject.cleanupFixture().subjectID,
        fingerprint: String = AIAssessmentSubject.cleanupFixture().fingerprint
    ) -> [String: Any] {
        [
            "subject_id": subjectID,
            "fingerprint": fingerprint,
            "summary": "应用缓存目录",
            "explanation": "应用运行时生成的缓存数据，删除后应用会按需重建，不影响用户数据。",
            "risk": "low",
            "recommendation": "delete",
            "confidence": "medium",
            "evidence": ["位于 Library/Caches 下"],
        ]
    }

    private static func chatResponse(payloads: [[String: Any]]) -> MockHTTPResponse {
        let arguments = try! JSONSerialization.data(withJSONObject: ["assessments": payloads])
        let body: [String: Any] = [
            "model": "deepseek-v4-pro",
            "choices": [[
                "message": [
                    "role": "assistant",
                    "tool_calls": [[
                        "id": "call-1",
                        "type": "function",
                        "function": [
                            "name": "submit_assessments",
                            "arguments": String(decoding: arguments, as: UTF8.self),
                        ],
                    ]],
                ],
            ]],
        ]
        return MockHTTPResponse(
            status: 200,
            body: try! JSONSerialization.data(withJSONObject: body)
        )
    }
}

/// 记录请求并返回预制响应的 transport。
actor MockHTTPTransport: HTTPTransporting {
    enum Behavior: Sendable {
        case response(MockHTTPResponse)
        case failure(Error)
    }

    private let behavior: Behavior
    private(set) var lastRequest: URLRequest?
    private(set) var requests: [URLRequest] = []

    init(response: MockHTTPResponse) {
        behavior = .response(response)
    }

    init(status: Int, headers: [String: String] = [:]) {
        behavior = .response(MockHTTPResponse(status: status, headers: headers))
    }

    init(error: any Error) {
        behavior = .failure(error)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        requests.append(request)
        switch behavior {
        case let .failure(error):
            throw error
        case let .response(mock):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.deepseek.com/chat/completions")!,
                statusCode: mock.status,
                httpVersion: nil,
                headerFields: mock.headers
            )!
            return (mock.body, response)
        }
    }
}

extension DeepSeekAssessmentClient {
    static func fixture(response: MockHTTPResponse) -> DeepSeekAssessmentClient {
        DeepSeekAssessmentClient(
            configuration: DeepSeekConfiguration(
                baseURL: URL(string: "https://api.deepseek.com")!,
                model: "deepseek-v4-pro"
            ),
            keyStore: InMemoryAPIKeyStore(key: "sk-test"),
            transport: MockHTTPTransport(response: response)
        )
    }

    static func fixture(status: Int, headers: [String: String] = [:]) -> DeepSeekAssessmentClient {
        DeepSeekAssessmentClient(
            configuration: DeepSeekConfiguration(
                baseURL: URL(string: "https://api.deepseek.com")!,
                model: "deepseek-v4-pro"
            ),
            keyStore: InMemoryAPIKeyStore(key: "sk-test"),
            transport: MockHTTPTransport(status: status, headers: headers)
        )
    }
}
