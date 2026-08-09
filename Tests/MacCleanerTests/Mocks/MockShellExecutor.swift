import Foundation
import MacCleanerCore

/// 未打桩命令错误：默认失败，防止测试隐式依赖“未匹配也成功”的假象。
struct UnstubbedCommandError: Error, CustomStringConvertible {
    let command: String
    var description: String { "MockShellExecutor: unstubbed command '\(command)'" }
}

final class MockShellExecutor: ShellExecutor, @unchecked Sendable {
    var responses: [String: ShellOutput] = [:]
    var executedCommands: [(command: String, arguments: [String])] = []
    /// 未命中 responses 的调用（每次都会抛 UnstubbedCommandError）；
    /// 测试可断言“没有意外的 shell 调用”。
    private(set) var unmatchedCommands: [String] = []

    func run(_ command: String, arguments: [String]) async throws -> ShellOutput {
        executedCommands.append((command, arguments))
        let key = ([command] + arguments).joined(separator: " ")
        if let response = responses[key] {
            return response
        }
        unmatchedCommands.append(key)
        throw UnstubbedCommandError(command: key)
    }

    func setResponse(for command: String, stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        responses[command] = ShellOutput(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}
