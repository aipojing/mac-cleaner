import Foundation

/// 单次扫描中文件对象的不可变元数据快照。
///
/// `allocatedSize` 来自 `lstat` 的 `st_blocks * 512`（磁盘实际占用），
/// `logicalSize` 保留 `st_size` 供详情展示。符号链接只描述链接自身，
/// 不跟随目标。硬链接通过 `identity`（device + inode）识别，
/// 物理空间统计只计一次。
public struct FileMetadata: Hashable, Sendable {
    /// 标准化路径（折叠 `.`、`..` 和重复 `/`，不解析最终符号链接）。
    public let path: String
    public let identity: FileIdentity
    public let logicalSize: Int64
    public let allocatedSize: Int64
    /// st_nlink：该 inode 的硬链接数量。
    public let linkCount: UInt64
    public let modificationTimeNanoseconds: Int64

    public var kind: FileObjectKind { identity.kind }

    public init(
        path: String,
        identity: FileIdentity,
        logicalSize: Int64,
        allocatedSize: Int64,
        linkCount: UInt64,
        modificationTimeNanoseconds: Int64
    ) {
        self.path = path
        self.identity = identity
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.linkCount = linkCount
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
    }

    /// 从 lstat 字段构建。`st_blocks` 为 512 字节块数，负值按 0 处理。
    public static func fromStat(
        path: String,
        device: UInt64,
        inode: UInt64,
        mode: mode_t,
        logicalSize: Int64,
        blocks: Int64,
        linkCount: UInt64,
        modificationTimeNanoseconds: Int64
    ) -> FileMetadata {
        FileMetadata(
            path: path,
            identity: FileIdentity(device: device, inode: inode, kind: kind(from: mode)),
            logicalSize: logicalSize,
            allocatedSize: max(0, blocks) * 512,
            linkCount: linkCount,
            modificationTimeNanoseconds: modificationTimeNanoseconds
        )
    }

    /// st_mode → 对象类型；不认识的类型归为 other。
    static func kind(from mode: mode_t) -> FileObjectKind {
        switch mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }
}
