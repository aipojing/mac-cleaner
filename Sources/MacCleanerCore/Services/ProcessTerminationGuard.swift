import Foundation

/// 进程终止验证结论
public enum ProcessTerminationVerdict: String, Sendable, Equatable {
    case allowed
    case protectedProcess
    case identityChanged
    case identityUnavailable
}

/// 进程信号发送协议：实际 kill 的唯一出口，测试可替换
public protocol ProcessSignalSending: Sendable {
    func send(_ signal: Int32, to pid: Int32) -> Bool
}

/// 基于 Darwin kill 的信号发送实现
public struct DarwinProcessSignalSender: ProcessSignalSending {
    public init() {}

    public func send(_ signal: Int32, to pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, signal) == 0
    }
}

/// 进程终止守卫：发送信号前重新解析同一 PID，
/// 只在 pid、可执行路径、启动时间均一致且不属于受保护集合时放行。
public struct ProcessTerminationGuard: Sendable {
    private let currentPID: Int32
    private let helperBundleIdentifiers: Set<String>
    private let resolver: any ProcessExecutableResolving
    private let sender: any ProcessSignalSending

    public init(
        currentPID: Int32 = getpid(),
        helperBundleIdentifiers: [String] = ["com.maccleaner.helper", "com.maccleaner.app"],
        resolver: any ProcessExecutableResolving = ProcessExecutableResolver(),
        sender: any ProcessSignalSending = DarwinProcessSignalSender()
    ) {
        self.currentPID = currentPID
        self.helperBundleIdentifiers = Set(helperBundleIdentifiers)
        self.resolver = resolver
        self.sender = sender
    }

    /// 验证扫描时记录的进程身份此刻仍然有效
    public func validate(_ scanned: ProcessIdentity) async -> ProcessTerminationVerdict {
        // PID > 1：拒绝 kernel_task/launchd 及非法 PID；拒绝自身与 helper
        guard scanned.pid > 1, scanned.pid != currentPID else { return .protectedProcess }
        if let bundleID = scanned.bundleIdentifier, helperBundleIdentifiers.contains(bundleID) {
            return .protectedProcess
        }

        guard let current = try? await resolver.identity(for: scanned.pid) else {
            return .identityUnavailable
        }

        guard current.executablePath == scanned.executablePath,
              current.startTimeTicks == scanned.startTimeTicks else {
            return .identityChanged
        }

        if let bundleID = current.bundleIdentifier, helperBundleIdentifiers.contains(bundleID) {
            return .protectedProcess
        }

        return .allowed
    }

    /// 验证通过后发送信号；验证失败时不发送任何信号
    public func terminate(_ scanned: ProcessIdentity, force: Bool = false) async -> Bool {
        guard await validate(scanned) == .allowed else { return false }
        return sender.send(force ? SIGKILL : SIGTERM, to: scanned.pid)
    }
}
