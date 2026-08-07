import Foundation
import Darwin

/// 文件身份提供器。扫描阶段记录身份，删除阶段重新验证。
public protocol FileIdentityProviding: Sendable {
    /// 路径是否存在（lstat，不跟随符号链接）。
    func exists(at path: String) -> Bool
    /// 用 lstat 读取目标身份（device、inode、对象类型）。不跟随符号链接。
    func identity(at path: String) throws -> FileIdentity
    /// 返回父目录的规范化绝对路径（解析父目录的符号链接）。
    /// 不跟随最终目标本身，避免把"链接本身"替换为"链接目标"的身份。
    func canonicalParent(of path: String) throws -> String
    /// 尽力解析整个路径（含最终组件的符号链接）。用于规范化允许根目录
    /// 与受保护路径，使其与目标路径在同一规范空间下比较。
    /// 路径不存在或解析失败时返回标准化后的路径。
    func resolvedPath(_ path: String) -> String
}

public enum FileIdentityError: Error, Sendable {
    /// lstat 失败（目标不存在、权限不足等）。
    case statFailed(path: String)
    /// 父目录规范化失败。
    case canonicalizationFailed(path: String)
}

/// 基于 POSIX lstat/realpath 的生产实现。
public struct POSIXFileIdentityProvider: FileIdentityProviding {
    public init() {}

    public func exists(at path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public func identity(at path: String) throws -> FileIdentity {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw FileIdentityError.statFailed(path: path)
        }
        let kind: FileObjectKind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .regularFile
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
        return FileIdentity(
            device: UInt64(st.st_dev),
            inode: UInt64(st.st_ino),
            kind: kind
        )
    }

    public func canonicalParent(of path: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let target = parent.isEmpty ? "/" : parent
        guard let resolved = realpath(target, nil) else {
            throw FileIdentityError.canonicalizationFailed(path: path)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func resolvedPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// 测试用桩实现：存在性与身份由初始化参数决定；canonicalParent 直接取输入路径
/// 的父目录（不触碰真实文件系统、不解析符号链接），保持确定性。
public struct StubFileIdentityProvider: FileIdentityProviding {
    private let existsResult: Bool
    private let identityResult: Result<FileIdentity, Error>

    public init(
        exists: Bool = true,
        identity: FileIdentity? = nil,
        identityError: Error? = nil
    ) {
        self.existsResult = exists
        if let identityError {
            self.identityResult = .failure(identityError)
        } else if let identity {
            self.identityResult = .success(identity)
        } else {
            self.identityResult = .failure(FileIdentityError.statFailed(path: "<stub>"))
        }
    }

    public func exists(at path: String) -> Bool { existsResult }

    public func identity(at path: String) throws -> FileIdentity {
        try identityResult.get()
    }

    public func canonicalParent(of path: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
