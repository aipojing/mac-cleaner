import Foundation

/// 进程身份：终止前验证用，防止 PID 复用误杀
public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let startTimeTicks: UInt64
    public let bundleIdentifier: String?

    public init(pid: Int32, executablePath: String, startTimeTicks: UInt64, bundleIdentifier: String? = nil) {
        self.pid = pid
        self.executablePath = executablePath
        self.startTimeTicks = startTimeTicks
        self.bundleIdentifier = bundleIdentifier
    }
}

/// 运行中的进程信息（不可变值类型）。
/// 只包含可观察事实：名称、路径、用户、CPU、常驻内存、运行时长和身份。
/// 不包含用途描述、风险或操作建议——解释与评级由用户显式触发的 AI 分析提供。
public struct RunningProcess: Identifiable, Sendable {
    public let id: Int32              // PID
    public let name: String           // 进程名
    public let path: String           // 可执行文件路径（无法解析时保留 comm 用于显示）
    public let user: String           // 运行用户
    public let cpuPercent: Double     // CPU 使用率
    public let residentMemoryBytes: UInt64 // 常驻内存（RSS）
    public let elapsedSeconds: UInt64?     // 运行时长（秒）
    public let signedByApple: Bool?   // 是否 Apple 签名（无法确定时为 nil）
    /// 扫描时记录的进程身份；nil 表示无法解析，进程不可终止
    public let identity: ProcessIdentity?

    public init(
        id: Int32, name: String, path: String, user: String,
        cpuPercent: Double, residentMemoryBytes: UInt64, elapsedSeconds: UInt64?,
        signedByApple: Bool? = nil,
        identity: ProcessIdentity? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.user = user
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.elapsedSeconds = elapsedSeconds
        self.signedByApple = signedByApple
        self.identity = identity
    }
}
