import Foundation

/// 进程可执行身份解析协议：获取指定 PID 的真实可执行路径与启动时间
public protocol ProcessExecutableResolving: Sendable {
    func identity(for pid: Int32) async throws -> ProcessIdentity
}

public enum ProcessExecutableResolverError: Error, LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "无法解析进程身份"
        }
    }
}

/// 基于 libproc 的进程身份解析：`proc_pidpath` 取完整绝对路径，
/// `proc_pidinfo` 取启动时间，用于终止前身份一致性校验。
public struct ProcessExecutableResolver: ProcessExecutableResolving {
    public init() {}

    public func identity(for pid: Int32) async throws -> ProcessIdentity {
        guard pid > 0 else { throw ProcessExecutableResolverError.unavailable }
        let path = try Self.executablePath(for: pid)
        let startTimeTicks = try Self.startTimeTicks(for: pid)
        return ProcessIdentity(
            pid: pid,
            executablePath: path,
            startTimeTicks: startTimeTicks,
            bundleIdentifier: Self.bundleIdentifier(forExecutablePath: path)
        )
    }

    /// 完整可执行文件绝对路径（不受 ps comm 截断/带参数影响）
    static func executablePath(for pid: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { throw ProcessExecutableResolverError.unavailable }
        return String(cString: buffer)
    }

    /// 进程启动时间（秒 * 1_000_000 + 微秒），用于检测 PID 复用
    static func startTimeTicks(for pid: Int32) throws -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { throw ProcessExecutableResolverError.unavailable }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    /// 从 .app 包内可执行路径推导 bundle 标识符（不加载 bundle）
    static func bundleIdentifier(forExecutablePath path: String) -> String? {
        guard let appRange = path.range(of: ".app/", options: .backwards) else { return nil }
        let appPath = String(path[..<appRange.lowerBound]) + ".app"
        return Bundle(path: appPath)?.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String
    }
}
