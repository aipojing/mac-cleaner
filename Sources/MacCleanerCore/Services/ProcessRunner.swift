import Foundation

public struct ProcessRunner: ShellExecutor {
    public init() {}

    public func run(_ command: String, arguments: [String] = []) async throws -> ShellOutput {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 输出收集：进程退出后 pipe 必然 EOF。两条管道各自在并发队列上
        // 同步读到 EOF（避免单边读造成的 buffer 死锁），再取退出状态。
        // 不使用 readabilityHandler——terminationHandler 与 handler 回调
        // 之间存在「已读取未 append」的尾部丢失竞态。
        return try await withCheckedThrowingContinuation { continuation in
            let state = ResumeState(continuation: continuation)
            let collected = CollectedOutput()
            let queue = DispatchQueue(label: "maccleaner.processrunner", attributes: .concurrent)
            let group = DispatchGroup()

            group.enter()
            queue.async {
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                collected.setStdout(data)
                group.leave()
            }
            group.enter()
            queue.async {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                collected.setStderr(data)
                group.leave()
            }
            queue.async {
                group.wait()
                process.waitUntilExit()
                state.resume(ShellOutput(
                    stdout: String(data: collected.stdout, encoding: .utf8) ?? "",
                    stderr: String(data: collected.stderr, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus
                ))
            }

            do {
                try process.run()
            } catch {
                // run 失败：关掉写端让读侧 EOF，收集队列随后退出
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                state.resume(throwing: error)
            }
        }
    }
}

/// 保证 continuation 恰好 resume 一次。
private final class ResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShellOutput, any Error>?

    init(continuation: CheckedContinuation<ShellOutput, any Error>) {
        self.continuation = continuation
    }

    func resume(_ output: ShellOutput) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: output)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}

/// 两条管道读取结果的锁保护容器。
private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    var stdout: Data {
        lock.lock()
        defer { lock.unlock() }
        return stdoutData
    }

    var stderr: Data {
        lock.lock()
        defer { lock.unlock() }
        return stderrData
    }

    func setStdout(_ data: Data) {
        lock.lock()
        stdoutData = data
        lock.unlock()
    }

    func setStderr(_ data: Data) {
        lock.lock()
        stderrData = data
        lock.unlock()
    }
}
