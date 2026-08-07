import Foundation

/// XPC 协议定义（App 和 Helper 各自编译一份）
@objc protocol MemoryCleanerXPCProtocol {
    func purgeMemory(withReply reply: @escaping (NSError?) -> Void)
    func helperVersion(withReply reply: @escaping (String) -> Void)
}
