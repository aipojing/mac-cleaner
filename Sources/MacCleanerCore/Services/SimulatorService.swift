import Foundation

public struct SimulatorService: Sendable {
    private let shell: ShellExecutor

    public init(shell: ShellExecutor = ProcessRunner()) {
        self.shell = shell
    }

    public func deleteUnavailable() async throws -> ShellOutput {
        try await shell.run("xcrun", arguments: ["simctl", "delete", "unavailable"])
    }

    public func deleteDevice(udid: String) async throws -> ShellOutput {
        try await shell.run("xcrun", arguments: ["simctl", "delete", udid])
    }
}
