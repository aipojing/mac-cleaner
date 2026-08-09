import Foundation

public struct CleanupReport: Sendable {
    public let module: ModuleIdentifier
    public let deletedItems: [CleanedItem]
    public let failedItems: [FailedItem]
    public let dryRun: Bool
    /// 扫描时预估的可回收大小
    public let expectedSize: Int64
    /// 删除后实际确认释放的大小
    public let actualFreed: Int64

    public init(
        module: ModuleIdentifier,
        deletedItems: [CleanedItem] = [],
        failedItems: [FailedItem] = [],
        dryRun: Bool = false,
        expectedSize: Int64 = 0,
        actualFreed: Int64 = 0
    ) {
        self.module = module
        self.deletedItems = deletedItems
        self.failedItems = failedItems
        self.dryRun = dryRun
        self.expectedSize = expectedSize > 0 ? expectedSize : deletedItems.reduce(0) { $0 + $1.expectedSize }
        self.actualFreed = actualFreed > 0 ? actualFreed : deletedItems.reduce(0) { $0 + $1.actualFreed }
    }

    public var totalFreed: Int64 {
        actualFreed > 0 ? actualFreed : deletedItems.reduce(0) { $0 + $1.expectedSize }
    }

    public var successCount: Int { deletedItems.count }
    public var failureCount: Int { failedItems.count }

    /// 移到废纸篓的大小（未真正释放磁盘空间）
    public var trashedSize: Int64 {
        deletedItems.filter(\.movedToTrash).reduce(0) { $0 + $1.expectedSize }
    }

    /// 预计与实际的差异（正值=少于预期，负值=多于预期）
    /// 注意：移到废纸篓的文件未真正释放磁盘空间，不计入 actualFreed，
    /// 但也不应算作差异，故从 expectedSize 中扣除 trashedSize。
    public var discrepancy: Int64 {
        expectedSize - actualFreed - trashedSize
    }

    /// 是否有权限相关的失败
    public var hasPermissionFailures: Bool {
        failedItems.contains { $0.reason == .permissionDenied }
    }
}

public struct CleanedItem: Sendable {
    public let path: String
    /// 扫描时预估大小
    public let expectedSize: Int64
    /// 删除后实际释放大小（永久删除才算真正释放）
    public let actualFreed: Int64
    /// 是否经过删除后验证确认已删除
    public let verified: Bool
    /// 是否移到了废纸篓（磁盘空间未真正释放，需清空废纸篓）
    public let movedToTrash: Bool

    public init(path: String, size: Int64) {
        self.path = path
        self.expectedSize = size
        self.actualFreed = size
        self.verified = false
        self.movedToTrash = false
    }

    public init(path: String, expectedSize: Int64, actualFreed: Int64, verified: Bool, movedToTrash: Bool = false) {
        self.path = path
        self.expectedSize = expectedSize
        self.actualFreed = actualFreed
        self.verified = verified
        self.movedToTrash = movedToTrash
    }
}

/// 删除失败的结构化原因
public enum FailureReason: String, Sendable {
    /// 权限不足（FDA 未开启或目录受保护）
    case permissionDenied = "permission_denied"
    /// 文件被其他进程占用
    case fileInUse = "file_in_use"
    /// 扫描后文件已被删除或移动
    case notFound = "not_found"
    /// 磁盘空间不足（移动到废纸篓时）
    case diskFull = "disk_full"
    /// 目标未通过本地安全校验（越界、受保护路径、符号链接等）
    case unsafeTarget = "unsafe_target"
    /// 目标身份（device/inode/类型）与扫描时不一致
    case identityChanged = "identity_changed"
    /// 无法确认目标身份
    case identityUnavailable = "identity_unavailable"
    /// 文件内容（修改时间/大小）在扫描后发生变化
    case contentModified = "content_modified"
    /// 其他未知错误
    case unknown = "unknown"

    public var localizedDescription: String {
        switch self {
        case .permissionDenied: return "权限不足，请开启完全磁盘访问权限"
        case .fileInUse: return "文件正在被其他程序使用"
        case .notFound: return "文件已被移动或删除"
        case .diskFull: return "磁盘空间不足"
        case .unsafeTarget: return "本地安全校验未通过，已拒绝执行"
        case .identityChanged: return "文件在扫描后已被替换，已拒绝执行"
        case .identityUnavailable: return "无法确认文件身份，已拒绝执行"
        case .contentModified: return "文件内容在扫描后已变化，已拒绝执行"
        case .unknown: return "未知错误"
        }
    }
}

public struct FailedItem: Sendable {
    public let path: String
    public let error: String
    public let reason: FailureReason
    public let expectedSize: Int64

    public init(path: String, error: String) {
        self.path = path
        self.error = error
        self.reason = Self.classifyError(error)
        self.expectedSize = 0
    }

    public init(path: String, error: String, reason: FailureReason, expectedSize: Int64 = 0) {
        self.path = path
        self.error = error
        self.reason = reason
        self.expectedSize = expectedSize
    }

    /// 根据错误信息自动分类失败原因
    private static func classifyError(_ error: String) -> FailureReason {
        let lower = error.lowercased()
        if lower.contains("permission denied") || lower.contains("operation not permitted")
            || lower.contains("not permitted") {
            return .permissionDenied
        }
        if lower.contains("resource busy") || lower.contains("file is locked")
            || lower.contains("in use") {
            return .fileInUse
        }
        if lower.contains("no such file") || lower.contains("does not exist")
            || lower.contains("not found") {
            return .notFound
        }
        if lower.contains("no space") || lower.contains("disk full") {
            return .diskFull
        }
        return .unknown
    }
}
