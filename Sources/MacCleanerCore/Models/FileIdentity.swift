import Foundation

/// 文件对象类型。由 `lstat` 的 `st_mode` 推导，不跟随符号链接。
public enum FileObjectKind: String, Codable, Sendable, Hashable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

/// 扫描时刻记录的文件对象身份。
///
/// 用于在执行删除前重新验证目标是否仍然是用户选中的那个对象：
/// device + inode 唯一定位一个文件对象，kind 防止类型被替换
/// （例如被替换成符号链接）。AI 结论不能参与或绕过身份验证。
public struct FileIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let kind: FileObjectKind

    public init(device: UInt64, inode: UInt64, kind: FileObjectKind) {
        self.device = device
        self.inode = inode
        self.kind = kind
    }
}
