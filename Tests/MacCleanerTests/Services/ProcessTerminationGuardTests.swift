import Foundation
import Testing
@testable import MacCleanerCore

extension ProcessIdentity {
    static func fixture(
        pid: Int32 = 42,
        executablePath: String = "/Applications/A.app/Contents/MacOS/A",
        startTimeTicks: UInt64 = 100,
        bundleID: String? = nil
    ) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            executablePath: executablePath,
            startTimeTicks: startTimeTicks,
            bundleIdentifier: bundleID
        )
    }
}

@Suite("Process termination guard")
struct ProcessTerminationGuardTests {
    @Test("拒绝 PID 1、自身和 helper")
    func rejectsProtectedProcesses() async {
        let guardrail = ProcessTerminationGuard(
            currentPID: 300,
            helperBundleIdentifiers: ["com.maccleaner.helper"],
            resolver: StubProcessResolver()
        )

        #expect(await guardrail.validate(.fixture(pid: 1)) == .protectedProcess)
        #expect(await guardrail.validate(.fixture(pid: 300)) == .protectedProcess)
        #expect(await guardrail.validate(.fixture(bundleID: "com.maccleaner.helper")) == .protectedProcess)
    }

    @Test("拒绝 PID 相同但可执行路径或启动时间变化")
    func rejectsReusedPID() async {
        let scanned = ProcessIdentity(pid: 99, executablePath: "/Applications/A.app/A", startTimeTicks: 10)
        let resolver = StubProcessResolver(
            identity: ProcessIdentity(pid: 99, executablePath: "/Applications/B.app/B", startTimeTicks: 11)
        )
        let guardrail = ProcessTerminationGuard(
            currentPID: 300,
            helperBundleIdentifiers: [],
            resolver: resolver
        )

        #expect(await guardrail.validate(scanned) == .identityChanged)
    }

    @Test("身份无法解析时拒绝终止")
    func rejectsUnavailableIdentity() async {
        let guardrail = ProcessTerminationGuard(
            currentPID: 300,
            helperBundleIdentifiers: [],
            resolver: StubProcessResolver()
        )

        #expect(await guardrail.validate(.fixture(pid: 99)) == .identityUnavailable)
    }

    @Test("身份一致时放行并按请求发送信号")
    func allowsMatchingIdentity() async {
        let scanned = ProcessIdentity.fixture(pid: 99, startTimeTicks: 555)
        let sender = StubProcessSignalSender()
        let guardrail = ProcessTerminationGuard(
            currentPID: 300,
            helperBundleIdentifiers: [],
            resolver: StubProcessResolver(identity: scanned),
            sender: sender
        )

        #expect(await guardrail.validate(scanned) == .allowed)
        #expect(await guardrail.terminate(scanned) == true)
        #expect(sender.sent.count == 1)
        #expect(sender.sent.first?.signal == SIGTERM)
        #expect(sender.sent.first?.pid == 99)

        #expect(await guardrail.terminate(scanned, force: true) == true)
        #expect(sender.sent.last?.signal == SIGKILL)
    }

    @Test("验证失败时不得发送任何信号")
    func failedValidationSendsNoSignal() async {
        let scanned = ProcessIdentity.fixture(pid: 99)
        let changed = ProcessIdentity.fixture(pid: 99, startTimeTicks: 999)
        let sender = StubProcessSignalSender()
        let guardrail = ProcessTerminationGuard(
            currentPID: 300,
            helperBundleIdentifiers: [],
            resolver: StubProcessResolver(identity: changed),
            sender: sender
        )

        #expect(await guardrail.terminate(scanned) == false)
        #expect(await guardrail.terminate(scanned, force: true) == false)
        #expect(sender.sent.isEmpty, "guard 失败时不得发送 SIGTERM 或 SIGKILL")
    }
}
