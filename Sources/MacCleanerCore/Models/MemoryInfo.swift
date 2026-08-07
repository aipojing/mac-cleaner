import Foundation
import Darwin

public struct MemoryInfo: Sendable, Equatable {
    public let physicalBytes: UInt64
    public let appMemoryBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedBytes: UInt64
    public let swapUsedBytes: UInt64

    public init(
        physicalBytes: UInt64,
        appMemoryBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedBytes: UInt64,
        swapUsedBytes: UInt64
    ) {
        self.physicalBytes = physicalBytes
        self.appMemoryBytes = appMemoryBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.swapUsedBytes = swapUsedBytes
    }

    /// 已使用内存 = App + Wired + Compressed
    public var usedBytes: UInt64 {
        appMemoryBytes + wiredBytes + compressedBytes
    }

    /// 可用内存 = 物理内存 - 已使用
    public var freeBytes: UInt64 {
        physicalBytes > usedBytes ? physicalBytes - usedBytes : 0
    }

    /// 内存压力百分比 (0~1)
    public var pressureRatio: Double {
        guard physicalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(physicalBytes)
    }

    /// 从系统读取当前内存快照
    public static func current() throws -> MemoryInfo {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw MemoryInfoError.hostStatsFailed(result)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let physical = UInt64(ProcessInfo.processInfo.physicalMemory)

        // App Memory: internal (anonymous) pages minus purgeable
        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let appMemory = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize

        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let cached = UInt64(stats.external_page_count) * pageSize

        // Swap usage via sysctl
        let swapUsed = Self.swapUsage()

        return MemoryInfo(
            physicalBytes: physical,
            appMemoryBytes: appMemory,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached,
            swapUsedBytes: swapUsed
        )
    }

    private static func swapUsage() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return 0 }
        return usage.xsu_used
    }
}

public enum MemoryInfoError: LocalizedError, Sendable {
    case hostStatsFailed(kern_return_t)

    public var errorDescription: String? {
        switch self {
        case .hostStatsFailed(let code):
            return "获取内存信息失败 (kern_return: \(code))"
        }
    }
}
