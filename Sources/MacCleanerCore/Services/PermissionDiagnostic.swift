import Foundation

/// 单个目录的权限探测结果
public struct DirectoryAccessResult: Sendable, Identifiable {
    public let id = UUID()
    public let path: String
    public let displayName: String
    public let status: AccessStatus
    /// 该目录由哪个模块使用
    public let relatedModule: ModuleIdentifier?

    public enum AccessStatus: String, Sendable {
        /// 可正常读取
        case accessible = "accessible"
        /// 目录不存在（不一定是权限问题）
        case notFound = "not_found"
        /// 权限不足，无法读取
        case denied = "denied"
        /// 受沙盒限制
        case sandboxRestricted = "sandbox_restricted"
    }

    public var isAccessible: Bool { status == .accessible }
    public var isDenied: Bool { status == .denied || status == .sandboxRestricted }
}

/// 完整的权限诊断报��
public struct PermissionDiagnosticReport: Sendable {
    public let hasFullDiskAccess: Bool
    public let results: [DirectoryAccessResult]
    public let timestamp: Date

    public var accessibleCount: Int {
        results.filter(\.isAccessible).count
    }

    public var deniedCount: Int {
        results.filter(\.isDenied).count
    }

    public var deniedResults: [DirectoryAccessResult] {
        results.filter(\.isDenied)
    }

    /// 受影响的模块列表
    public var affectedModules: Set<ModuleIdentifier> {
        Set(deniedResults.compactMap(\.relatedModule))
    }

    public var completeness: Double {
        guard !results.isEmpty else { return 1.0 }
        return Double(accessibleCount) / Double(results.count)
    }
}

/// 权限诊断服务：检测哪些目录因 FDA/沙盒限制无法扫描
public struct PermissionDiagnostic: Sendable {
    public init() {}

    private static let home = DiskScanner.homeDirectory

    /// 需要探测的关键目录及其关联模块
    private var probeTargets: [(path: String, name: String, module: ModuleIdentifier?)] {
        let home = Self.home
        return [
            // 开发者缓存
            ("\(home)/.gradle", "Gradle 缓存", .developerCaches),
            ("\(home)/.m2", "Maven 缓存", .developerCaches),
            ("\(home)/.npm", "npm 缓存", .developerCaches),
            ("\(home)/.cocoapods", "CocoaPods 缓存", .developerCaches),

            // Xcode
            ("\(home)/Library/Developer/Xcode/DerivedData", "DerivedData", .xcode),
            ("\(home)/Library/Developer/Xcode/Archives", "Archives", .xcode),
            ("\(home)/Library/Developer/Xcode/iOS DeviceSupport", "DeviceSupport", .xcode),
            ("\(home)/Library/Developer/CoreSimulator", "CoreSimulator", .iosSimulators),

            // 应用缓存
            ("\(home)/Library/Caches", "应用缓存目录", .applicationCaches),

            // AI 工具
            ("\(home)/.cursor", "Cursor", .aiToolCaches),
            ("\(home)/.claude", "Claude Code", .aiToolCaches),

            // 需要 FDA 的受保护目录
            ("\(home)/Library/Safari", "Safari 数据 (FDA 检测)", nil),
            ("\(home)/Library/Mail", "邮件数据 (FDA 检测)", nil),
            ("\(home)/Library/Cookies", "Cookie 数据 (FDA 检测)", nil),

            // 系统级目录
            ("/Library/Caches", "系统缓存目录", nil),
            ("/var/log", "系统日志目录", nil),
        ]
    }

    /// 执行完整的权限诊断
    public func diagnose() -> PermissionDiagnosticReport {
        let fm = FileManager.default
        var results: [DirectoryAccessResult] = []

        for target in probeTargets {
            let status = probeAccess(path: target.path, fileManager: fm)
            results.append(DirectoryAccessResult(
                path: target.path,
                displayName: target.name,
                status: status,
                relatedModule: target.module
            ))
        }

        let hasFDA = checkFullDiskAccess(fileManager: fm)

        return PermissionDiagnosticReport(
            hasFullDiskAccess: hasFDA,
            results: results,
            timestamp: Date()
        )
    }

    /// 探测单个目录的访问状态
    private func probeAccess(path: String, fileManager fm: FileManager) -> DirectoryAccessResult.AccessStatus {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return .notFound
        }

        if isDir.boolValue {
            // 尝试列出目录内容来检测权限
            do {
                _ = try fm.contentsOfDirectory(atPath: path)
                return .accessible
            } catch let error as NSError {
                if error.code == NSFileReadNoPermissionError
                    || error.domain == NSCocoaErrorDomain && error.code == 257 {
                    return .denied
                }
                // 沙盒导致的 "Operation not permitted"
                if error.localizedDescription.contains("not permitted") {
                    return .sandboxRestricted
                }
                return .denied
            }
        } else {
            // 文件：尝试读取属性
            if fm.isReadableFile(atPath: path) {
                return .accessible
            }
            return .denied
        }
    }

    /// 检测是否有完全磁盘访问权限
    /// 通过尝试列出受保护目录来判断——能列出（即使为空）即表示已授权，
    /// 权限不足则会抛出异常。跳过不存在的目录。
    private func checkFullDiskAccess(fileManager fm: FileManager) -> Bool {
        let protectedPaths = [
            "\(Self.home)/Library/Safari",
            "\(Self.home)/Library/Mail",
            "\(Self.home)/Library/Cookies",
        ]

        for path in protectedPaths {
            guard fm.fileExists(atPath: path) else { continue }
            do {
                // 能成功列出即说明有 FDA（内容是否为空不影响判断）
                _ = try fm.contentsOfDirectory(atPath: path)
                return true
            } catch {
                // 权限被拒 → FDA 未授予
                return false
            }
        }
        // 所有受保护目录均不存在，无法确定；保守返回 true 避免误报
        return true
    }
}
