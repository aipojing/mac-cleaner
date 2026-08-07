import Foundation
@testable import MacCleanerCore

/// 信号发送测试桩：记录发送请求，不触碰真实进程。
final class StubProcessSignalSender: ProcessSignalSending, @unchecked Sendable {
    private(set) var sent: [(signal: Int32, pid: Int32)] = []

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        sent.append((signal, pid))
        return true
    }
}
