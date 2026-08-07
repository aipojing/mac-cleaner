import Foundation

/// 文件元数据读取边界。扫描模块只依赖该协议，测试可注入计数桩。
public protocol FileMetadataProviding: Sendable {
    func metadata(at path: String) async throws -> FileMetadata
}

/// 元数据读取的确定性错误（会进入扫描内缓存）。
public enum MetadataError: Error, Equatable, Sendable {
    case notFound(path: String)
    case unreadable(path: String, code: Int32)
}

/// 基于 `lstat` 的元数据 provider。不调用 `stat`，因此不跟随符号链接。
public struct POSIXFileMetadataProvider: FileMetadataProviding {
    public init() {}

    public func metadata(at path: String) async throws -> FileMetadata {
        try metadataSync(at: Self.normalized(path))
    }

    /// 同步版本：供 fts 等同步枚举路径直接复用同一份 lstat 逻辑。
    public func metadataSync(at normalizedPath: String) throws -> FileMetadata {
        var st = stat()
        guard lstat(normalizedPath, &st) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                throw MetadataError.notFound(path: normalizedPath)
            }
            throw MetadataError.unreadable(path: normalizedPath, code: code)
        }
        return FileMetadata.fromStat(
            path: normalizedPath,
            device: UInt64(st.st_dev),
            inode: UInt64(st.st_ino),
            mode: st.st_mode,
            logicalSize: Int64(st.st_size),
            blocks: Int64(st.st_blocks),
            linkCount: UInt64(st.st_nlink),
            modificationTimeNanoseconds: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(st.st_mtimespec.tv_nsec)
        )
    }

    /// 折叠 `.`、`..` 和重复 `/`，但不解析最终符号链接。
    public static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
