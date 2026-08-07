import Foundation

/// 设置页依赖的最小权限接口：只暴露配置状态、写入和删除。
public protocol APIKeyManaging: Sendable {
    func isConfigured() throws -> Bool
    func set(_ key: String) throws
    func delete() throws
}

/// 网络 client 依赖的读取接口：key 只在同步闭包内暴露，
/// 闭包结束后不保留引用，不回显、不入日志。
public protocol APIKeyProviding: Sendable {
    func withAPIKey<T>(_ body: (String) throws -> T) throws -> T
}

public enum APIKeyStoreError: Error, Equatable, Sendable {
    case invalidKey
    case notConfigured
    case keychainFailure
}
