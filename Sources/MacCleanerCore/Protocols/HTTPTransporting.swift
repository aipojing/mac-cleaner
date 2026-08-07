import Foundation

/// 网络传输边界，便于测试注入 mock，避免真实网络请求。
public protocol HTTPTransporting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
