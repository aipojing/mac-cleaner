import Foundation
import MacCleanerCore

final class MockShellExecutor: ShellExecutor, @unchecked Sendable {
    var responses: [String: ShellOutput] = [:]
    var executedCommands: [(command: String, arguments: [String])] = []

    func run(_ command: String, arguments: [String]) async throws -> ShellOutput {
        executedCommands.append((command, arguments))
        let key = ([command] + arguments).joined(separator: " ")
        if let response = responses[key] {
            return response
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
    }

    func setResponse(for command: String, stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        responses[command] = ShellOutput(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}
