import Foundation

/// URLSession 的 `HTTPTransporting` 适配。
public struct URLSessionHTTPTransport: HTTPTransporting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekClientError.invalidResponse
        }
        return (data, http)
    }
}
