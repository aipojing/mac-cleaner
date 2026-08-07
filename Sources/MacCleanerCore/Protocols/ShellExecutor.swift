import Foundation

public struct ShellOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var isSuccess: Bool { exitCode == 0 }
}

public protocol ShellExecutor: Sendable {
    func run(_ command: String, arguments: [String]) async throws -> ShellOutput
}
