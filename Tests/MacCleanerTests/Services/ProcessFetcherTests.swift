import Testing
import Foundation
@testable import MacCleanerCore

@Suite("ProcessFetcher Tests")
struct ProcessFetcherTests {
    /// ps 输出中 comm 列带参数的场景：路径必须由 resolver 给出真实可执行路径
    private static let psOutput = """
          PID   RSS  %CPU USER     ELAPSED COMM
            1  99999   0.0 root  10-00:00:00 /sbin/launchd
          432  20480   1.5 ahs       01:02:03 /usr/bin/python3 /Users/ahs/script.py
          777  10240   0.1 ahs       00:10:00 /Applications/Safari.app/Contents/MacOS/Safari
        """

    private static func makeFetcher(
        resolver: StubProcessResolver,
        sender: StubProcessSignalSender = StubProcessSignalSender()
    ) -> (ProcessFetcher, StubProcessSignalSender) {
        let shell = MockShellExecutor()
        shell.setResponse(
            for: "/bin/ps -axww -o pid,rss,%cpu,user,etime,comm",
            stdout: psOutput
        )
        let guardrail = ProcessTerminationGuard(
            currentPID: 300,
            helperBundleIdentifiers: [],
            resolver: resolver,
            sender: sender
        )
        let fetcher = ProcessFetcher(shell: shell, resolver: resolver, terminationGuard: guardrail)
        return (fetcher, sender)
    }

    @Test("进程抓取只返回可观察事实")
    func fetcherReturnsRawFacts() async throws {
        let resolver = StubProcessResolver(identity: .fixture(
            pid: 432,
            executablePath: "/usr/bin/python3",
            startTimeTicks: 100
        ))
        let (fetcher, _) = Self.makeFetcher(resolver: resolver)
        let process = try #require(try await fetcher.fetchAll().first { $0.id == 432 })

        #expect(process.identity?.pid == 432)
        #expect(process.name == "python3")
        #expect(process.path == "/usr/bin/python3")
        #expect(process.user == "ahs")
        #expect(process.cpuPercent == 1.5)
        #expect(process.residentMemoryBytes == 20480 * 1024)
        #expect(process.elapsedSeconds == 3_723)
    }

    @Test("解析 ps 输出并用 resolver 的真实可执行路径")
    func fetchParsesAndResolvesIdentities() async throws {
        let resolver = StubProcessResolver(identities: [
            432: .fixture(pid: 432, executablePath: "/usr/bin/python3", startTimeTicks: 42),
            777: .fixture(pid: 777, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", startTimeTicks: 43),
        ])
        let (fetcher, _) = Self.makeFetcher(resolver: resolver)

        let processes = try await fetcher.fetchAll()

        #expect(processes.count == 3)
        let python = try #require(processes.first { $0.id == 432 })
        #expect(python.path == "/usr/bin/python3", "comm 带参数时不能用 ps 文本当路径")
        #expect(python.name == "python3")
        #expect(python.identity != nil)
        #expect(python.residentMemoryBytes == 20480 * 1024)
    }

    @Test("无法解析身份的进程保留 comm 显示且不可终止")
    func unresolvableProcessIsNotTerminable() async throws {
        let (fetcher, sender) = Self.makeFetcher(resolver: StubProcessResolver())

        let processes = try await fetcher.fetchAll()

        let launchd = try #require(processes.first { $0.id == 1 })
        #expect(launchd.identity == nil)
        #expect(launchd.path == "/sbin/launchd", "无法解析时保留原始命令名用于显示")
        #expect(launchd.name == "launchd")
        #expect(launchd.elapsedSeconds == 10 * 86_400)

        #expect(await fetcher.terminate(launchd) == false)
        #expect(await fetcher.forceKill(launchd) == false)
        #expect(sender.sent.isEmpty, "无身份进程不得发送任何信号")
    }

    @Test("身份一致时 terminate 发送 SIGTERM")
    func terminateSendsSignalWhenIdentityMatches() async throws {
        let scanned = ProcessIdentity.fixture(
            pid: 777,
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            startTimeTicks: 43
        )
        let (fetcher, sender) = Self.makeFetcher(resolver: StubProcessResolver(identity: scanned))

        let processes = try await fetcher.fetchAll()
        let safari = try #require(processes.first { $0.id == 777 })

        #expect(await fetcher.terminate(safari) == true)
        #expect(sender.sent.count == 1)
        #expect(sender.sent.first?.signal == SIGTERM)
        #expect(sender.sent.first?.pid == 777)
    }

    @Test("PID 复用（启动时间变化）时拒绝终止")
    func terminateRejectsReusedPID() async throws {
        // 扫描时记录 startTimeTicks=43，终止时解析到 44 → 身份已变化
        let changed = ProcessIdentity.fixture(
            pid: 777,
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            startTimeTicks: 44
        )
        let shell = MockShellExecutor()
        shell.setResponse(
            for: "/bin/ps -axww -o pid,rss,%cpu,user,etime,comm",
            stdout: Self.psOutput
        )
        let scannedResolver = StubProcessResolver(identities: [
            777: .fixture(pid: 777, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", startTimeTicks: 43),
        ])
        let sender = StubProcessSignalSender()
        let guardrail = ProcessTerminationGuard(
            currentPID: 300,
            helperBundleIdentifiers: [],
            resolver: StubProcessResolver(identity: changed),
            sender: sender
        )
        let fetcher = ProcessFetcher(shell: shell, resolver: scannedResolver, terminationGuard: guardrail)

        let processes = try await fetcher.fetchAll()
        let safari = try #require(processes.first { $0.id == 777 })

        #expect(await fetcher.terminate(safari) == false)
        #expect(await fetcher.forceKill(safari) == false)
        #expect(sender.sent.isEmpty, "PID 复用时不得发送信号")
    }
}
