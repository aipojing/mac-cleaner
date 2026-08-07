import Foundation
import Testing
@testable import MacCleanerCore

@Suite("ProcessRunner output collection")
struct ProcessRunnerTests {
    @Test("大输出完整收集：stdout/stderr 都不丢尾部")
    func largeOutputFullyCollected() async throws {
        // 300 KB 远超 pipe 缓冲区（64 KB）：单边顺序读会死锁，
        // terminationHandler 拷贝缓冲区会丢尾部，两种缺陷都能暴露。
        let runner = ProcessRunner()
        let output = try await runner.run("python3", arguments: [
            "-c",
            "import sys; sys.stdout.write('A' * 300000); sys.stderr.write('B' * 300000)",
        ])

        #expect(output.exitCode == 0)
        #expect(output.stdout.count == 300_000, "stdout 尾部数据丢失")
        #expect(output.stderr.count == 300_000, "stderr 尾部数据丢失")
    }

    @Test("正常命令返回退出码与输出")
    func basicExecution() async throws {
        let runner = ProcessRunner()
        let output = try await runner.run("echo", arguments: ["hello"])
        #expect(output.exitCode == 0)
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }
}
