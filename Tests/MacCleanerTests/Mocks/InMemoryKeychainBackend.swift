import Foundation
@testable import MacCleanerCore

/// 内存 Keychain 后端：测试用，不触碰开发机真实 Keychain。
final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    struct Write: Equatable {
        let service: String
        let account: String
        let data: Data
    }

    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private(set) var lastWrite: Write?

    func read(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage["\(service)/\(account)"]
    }

    func write(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage["\(service)/\(account)"] = data
        lastWrite = Write(service: service, account: account, data: data)
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: "\(service)/\(account)")
    }
}
