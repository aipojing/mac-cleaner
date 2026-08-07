import Foundation

/// 获取系统运行进程列表并解析真实身份。
/// 只负责解析 `ps` 数值并合并 resolver 身份，不读取描述数据库，
/// 也不做名称启发式分类。shell 与 resolver 均可注入：测试用 mock
/// 替代真实 ps 与 libproc。
public struct ProcessFetcher: Sendable {
    private let shell: any ShellExecutor
    private let resolver: any ProcessExecutableResolving
    private let terminationGuard: ProcessTerminationGuard

    public init(
        shell: any ShellExecutor = ProcessRunner(),
        resolver: any ProcessExecutableResolving = ProcessExecutableResolver(),
        terminationGuard: ProcessTerminationGuard = ProcessTerminationGuard()
    ) {
        self.shell = shell
        self.resolver = resolver
        self.terminationGuard = terminationGuard
    }

    // MARK: - 获取进程列表

    /// 获取当前运行的所有进程（异步，调用 ps 命令并解析真实身份）
    public func fetchAll() async throws -> [RunningProcess] {
        // comm 放最后一列 — ps 只对非末列截断宽度，末列完整输出
        // -ww 取消行宽限制，避免长路径被截为 "Xc" 之类的残片
        let output = try await shell.run(
            "/bin/ps",
            arguments: ["-axww", "-o", "pid,rss,%cpu,user,etime,comm"]
        )
        return await parsePS(output: output.stdout)
    }

    /// ps 单行解析结果（身份解析前的中间结构）
    private struct PSRow {
        let pid: Int32
        let memoryBytes: UInt64
        let cpuPercent: Double
        let user: String
        let elapsedSeconds: UInt64?
        let comm: String
    }

    /// 解析 ps 输出为 RunningProcess 数组
    private func parsePS(output: String) async -> [RunningProcess] {
        let lines = output.components(separatedBy: "\n")
        guard lines.count > 1 else { return [] }

        // 跳过表头
        let rows = lines.dropFirst().compactMap(parsePSLine)

        // 并发解析每个进程的真实身份
        return await withTaskGroup(of: RunningProcess?.self) { group in
            for row in rows {
                group.addTask {
                    await self.buildProcess(row: row)
                }
            }
            var processes: [RunningProcess] = []
            for await process in group {
                if let process { processes.append(process) }
            }
            return processes
        }
    }

    /// 解析单行 ps 输出
    /// 格式: PID RSS %CPU USER ETIME COMM（comm 在末列，不会被截断）
    private func parsePSLine(_ line: String) -> PSRow? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 前 5 列是定宽字段，第 6 列起全部是 COMM（可含空格）
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 6 else { return nil }

        guard let pid = Int32(parts[0]) else { return nil }
        guard let rssKB = UInt64(parts[1]) else { return nil }
        guard let cpuPercent = Double(parts[2]) else { return nil }
        let user = String(parts[3])
        let etime = String(parts[4])

        // 第 6 列起是 COMM（末列，完整输出不截断）
        let comm = parts[5...].joined(separator: " ")

        return PSRow(
            pid: pid,
            memoryBytes: rssKB * 1024,
            cpuPercent: cpuPercent,
            user: user,
            elapsedSeconds: Self.parseElapsedSeconds(etime),
            comm: comm
        )
    }

    /// 解析 ps etime（[[dd-]hh:]mm:ss）为秒数；无法解析时返回 nil。
    static func parseElapsedSeconds(_ etime: String) -> UInt64? {
        var days: UInt64 = 0
        var rest = etime
        if let dashIndex = rest.firstIndex(of: "-") {
            guard let parsedDays = UInt64(rest[rest.startIndex..<dashIndex]) else { return nil }
            days = parsedDays
            rest = String(rest[rest.index(after: dashIndex)...])
        }
        let rawComponents = rest.split(separator: ":")
        let components = rawComponents.compactMap { UInt64($0) }
        guard components.count == rawComponents.count else { return nil }
        let timeSeconds: UInt64
        switch components.count {
        case 3:
            timeSeconds = components[0] * 3_600 + components[1] * 60 + components[2]
        case 2:
            timeSeconds = components[0] * 60 + components[1]
        case 1:
            timeSeconds = components[0]
        default:
            return nil
        }
        return days * 86_400 + timeSeconds
    }

    /// 用 resolver 的真实可执行路径构建进程信息；
    /// 无法解析时保留 comm 用于显示，但 identity 为 nil（不可终止）
    private func buildProcess(row: PSRow) async -> RunningProcess? {
        let identity = try? await resolver.identity(for: row.pid)
        let path = identity?.executablePath ?? row.comm

        return RunningProcess(
            id: row.pid,
            name: extractProcessName(from: path),
            path: path,
            user: row.user,
            cpuPercent: row.cpuPercent,
            residentMemoryBytes: row.memoryBytes,
            elapsedSeconds: row.elapsedSeconds,
            signedByApple: nil,
            identity: identity
        )
    }

    // MARK: - 进程名提取

    /// 从完整路径中提取进程名
    private func extractProcessName(from path: String) -> String {
        // ps -o comm 输出完整路径，取最后一段
        (path as NSString).lastPathComponent
    }

    // MARK: - 终止进程

    /// 发送 SIGTERM 请求进程正常退出。
    /// 终止前由 guard 重新验证身份：PID>1、非自身/helper、
    /// 可执行路径与启动时间一致，否则拒绝且不发送任何信号。
    public func terminate(_ process: RunningProcess) async -> Bool {
        guard let identity = process.identity else { return false }
        return await terminationGuard.terminate(identity, force: false)
    }

    /// 发送 SIGKILL 强制终止进程，验证规则同 `terminate`
    public func forceKill(_ process: RunningProcess) async -> Bool {
        guard let identity = process.identity else { return false }
        return await terminationGuard.terminate(identity, force: true)
    }
}
