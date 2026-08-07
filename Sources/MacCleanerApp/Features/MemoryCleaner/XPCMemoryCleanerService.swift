import Foundation
import MacCleanerCore

/// XPC 协议定义（App 侧编译一份，与 helper 保持一致）
@objc protocol MemoryCleanerXPCProtocol {
    func purgeMemory(withReply reply: @escaping (NSError?) -> Void)
    func helperVersion(withReply reply: @escaping (String) -> Void)
}

/// 通过 XPC 连接特权 Helper 执行内存清理
final class XPCMemoryCleanerService: MemoryCleanerService, @unchecked Sendable {

    private let machServiceName = "com.maccleaner.helper"

    init() {}

    func purgeMemory() async throws {
        let proxy = try connect()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.purgeMemory { error in
                if let error {
                    continuation.resume(throwing: MemoryCleanerError.purgeFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// 查询 Helper 版本（可用于检测 Helper 是否已安装）
    func helperVersion() async throws -> String {
        let proxy = try connect()

        return try await withCheckedThrowingContinuation { continuation in
            proxy.helperVersion { version in
                continuation.resume(returning: version)
            }
        }
    }

    /// 检查 Helper 是否可连接
    func isHelperAvailable() async -> Bool {
        do {
            _ = try await helperVersion()
            return true
        } catch {
            return false
        }
    }

    private func connect() throws -> MemoryCleanerXPCProtocol {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: MemoryCleanerXPCProtocol.self)
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            // 连接错误会在 continuation 中处理
        }) as? MemoryCleanerXPCProtocol else {
            throw MemoryCleanerError.purgeFailed("无法连接到特权助手服务")
        }
        return proxy
    }
}
