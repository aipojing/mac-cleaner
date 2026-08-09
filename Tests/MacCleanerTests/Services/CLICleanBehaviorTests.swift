import Foundation
import Testing
@testable import MacCleanerCore

/// CLI 行为集成测试：通过已构建的 mac-cleaner 二进制验证
/// 安全语义（--all 排除大文件、路径可审阅、错误非零退出、flag 冲突）。
@Suite("CLI clean/scan behavior")
struct CLICleanBehaviorTests {
    /// swift test 运行前会构建整个 package（含可执行文件）。
    private static var cliBinary: String {
        FileManager.default.currentDirectoryPath + "/.build/debug/mac-cleaner"
    }

    private struct CLIResult {
        let status: Int32
        let output: String
    }

    private func runCLI(_ arguments: [String]) throws -> CLIResult {
        let binary = Self.cliBinary
        guard FileManager.default.fileExists(atPath: binary) else {
            Issue.record("CLI 二进制不存在: \(binary)")
            return CLIResult(status: -1, output: "")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        // 确认提示不应阻塞：stdin 置空，readLine 立即返回 nil
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return CLIResult(status: process.terminationStatus, output: output)
    }

    @Test("不存在的 profile 报错并以非零退出")
    func unknownProfileExitsNonZero() async throws {
        let result = try runCLI(["clean", "--profile", "不存在的方案"])
        #expect(result.status != 0)
        #expect(result.output.contains("未找到方案"))
    }

    @Test("scan --modules 含未识别模块名时报错并非零退出")
    func scanWithUnknownModuleExitsNonZero() async throws {
        let result = try runCLI(["scan", "--modules", "simulator"])
        #expect(result.status != 0)
        #expect(result.output.contains("未识别"))
        #expect(result.output.contains("simulator"))
    }

    @Test("--all 与单模块 flag 同用时明确报错")
    func allConflictsWithModuleFlag() async throws {
        let result = try runCLI(["clean", "--all", "--dev-caches"])
        #expect(result.status != 0)
        #expect(result.output.contains("--all"))
    }

    @Test("--list-profiles 与其它 flag 同用时明确报错")
    func listProfilesConflictsWithOtherFlags() async throws {
        let result = try runCLI(["clean", "--list-profiles", "--all"])
        #expect(result.status != 0)
        #expect(result.output.contains("--list-profiles"))
    }

    @Test("--all --dry-run 的扫描模块不包含大文件")
    func allDryRunExcludesLargeFiles() async throws {
        let result = try runCLI(["clean", "--all", "--dry-run"])
        #expect(result.status == 0)
        // 多模块扫描确实发生（以系统日志为探针），但用户数据模块不出现
        #expect(result.output.contains("扫描 系统日志"))
        #expect(!result.output.contains("大文件"))
    }

    @Test("--dry-run 预览逐条列出候选完整路径")
    func dryRunListsCandidatePaths() async throws {
        let home = NSHomeDirectory()
        let fakeDir = "\(home)/Library/Logs/DevCleanTest-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: fakeDir, withIntermediateDirectories: true)
        // 用户日志候选阈值 > 1MB
        let payload = Data(repeating: 0x61, count: 2 * 1024 * 1024)
        try payload.write(to: URL(fileURLWithPath: "\(fakeDir)/test.log"))
        defer { try? fm.removeItem(atPath: fakeDir) }

        let result = try runCLI(["clean", "--profile", "日志清理", "--dry-run"])
        #expect(result.status == 0)
        #expect(result.output.contains(fakeDir))
        #expect(result.output.contains("试运行"))
    }
}
