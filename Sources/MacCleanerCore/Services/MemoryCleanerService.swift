import Foundation

/// 内存清理服务协议
public protocol MemoryCleanerService: Sendable {
    func purgeMemory() async throws
}

/// 清理错误
public enum MemoryCleanerError: LocalizedError, Sendable {
    case purgeFailed(String)
    case userCancelled

    public var errorDescription: String? {
        switch self {
        case .purgeFailed(let msg):
            return "内存清理失败：\(msg)"
        case .userCancelled:
            return "用户取消了授权"
        }
    }
}

/// 通过 AppleScript 执行 sudo purge（弹系统密码框）
public final class AppleScriptMemoryCleanerService: MemoryCleanerService, @unchecked Sendable {
    public init() {}

    public func purgeMemory() async throws {
        // 使用 AppleScript 的 "do shell script ... with administrator privileges"
        // 系统会弹出管理员密码输入框
        let script = """
        do shell script "purge" with administrator privileges
        """

        let result = try await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            let output = appleScript?.executeAndReturnError(&error)

            if let error {
                let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
                // 用户点取消时的错误码是 -128
                let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? 0
                if errorNumber == -128 {
                    return Result<Void, MemoryCleanerError>.failure(.userCancelled)
                }
                return Result<Void, MemoryCleanerError>.failure(.purgeFailed(errorMsg))
            }
            return Result<Void, MemoryCleanerError>.success(())
        }.value

        try result.get()
    }
}

/// Mock 用于测试
public final class MockMemoryCleanerService: MemoryCleanerService, @unchecked Sendable {
    public var shouldFail = false
    public var purgeCallCount = 0

    public init() {}

    public func purgeMemory() async throws {
        purgeCallCount += 1
        if shouldFail {
            throw MemoryCleanerError.purgeFailed("mock failure")
        }
    }
}
