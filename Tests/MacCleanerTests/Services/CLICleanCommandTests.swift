import Foundation
import Testing
@testable import MacCleanerCore

/// CLI 集成测试：直接启动已构建的 mac-cleaner 二进制，
/// 验证清理语义收敛后的命令行行为。
@Suite("CLI clean command integration")
struct CLICleanCommandTests {
    /// swift test 运行前会构建整个 package（含可执行文件）。
    private static var cliBinary: String {
        FileManager.default.currentDirectoryPath + "/.build/debug/mac-cleaner"
    }

    @Test("不传模块、profile 或 --all 时拒绝执行")
    func cleanWithoutSelectionIsRejected() async throws {
        let binary = Self.cliBinary
        guard FileManager.default.fileExists(atPath: binary) else {
            Issue.record("CLI 二进制不存在: \(binary)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["clean", "--dry-run", "--yes"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus != 0)
        #expect(output.contains("请指定模块或 --all"))
    }
}
