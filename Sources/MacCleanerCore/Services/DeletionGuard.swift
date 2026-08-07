import Foundation

/// 删除前安全校验的拒绝原因。AI 结论无权影响以下任何一项判断。
public enum DeletionGuardError: Error, Equatable, Sendable {
    /// 目标不存在或无法访问。
    case targetMissing
    /// 目标超出本模块允许的根目录范围。
    case outsideAllowedRoots
    /// 目标是受保护路径本身（如 / 或用户主目录）。
    case protectedRoot
    /// 目标位于受保护子树内（如 /System）。
    case protectedSubtree
    /// 目标最终解析为符号链接：只删链接本身也拒绝，防止逃逸。
    case symbolicLink
    /// 无法读取目标身份，不能确认它就是用户选中的对象。
    case identityUnavailable
    /// 目标身份（device/inode/类型）与扫描时记录的不一致。
    case identityChanged
}

/// 执行层安全护栏。
///
/// 在真正 trash/remove 之前验证：目标存在、位于允许根目录内、
/// 不是受保护路径或子树、不是符号链接，且 device/inode/对象类型
/// 仍与扫描快照一致。任何一项失败都拒绝执行，不降级。
public struct DeletionGuard: Sendable {
    private let allowedRoots: [String]
    private let identityProvider: any FileIdentityProviding
    private let protectedExactPaths: [String]
    private let protectedSubtrees: [String]

    public init(
        allowedRoots: [String],
        identityProvider: any FileIdentityProviding,
        protectedExactPaths: [String],
        protectedSubtrees: [String]
    ) {
        // 允许根与受保护路径与目标路径必须在同一规范空间下比较：
        // 例如 /var 是 /private/var 的符号链接，目标会被规范化为后者。
        self.allowedRoots = allowedRoots.map { identityProvider.resolvedPath($0) }
        self.identityProvider = identityProvider
        self.protectedExactPaths = protectedExactPaths.map { identityProvider.resolvedPath($0) }
        self.protectedSubtrees = protectedSubtrees.map { identityProvider.resolvedPath($0) }
    }

    /// 验证删除目标。成功时返回当前身份；失败抛出 DeletionGuardError。
    public func validate(
        path: String,
        expectedIdentity: FileIdentity?
    ) throws -> FileIdentity {
        guard identityProvider.exists(at: path) else {
            throw DeletionGuardError.targetMissing
        }

        // 规范化 . / .. / 重复分隔符；不解析最终符号链接。
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path

        // 只对父目录做 realpath，保持最终组件不被符号链接跟随。
        let canonicalParent = try identityProvider.canonicalParent(of: standardized)
        let lastComponent = (standardized as NSString).lastPathComponent
        let canonicalPath = lastComponent.isEmpty
            ? canonicalParent
            : (canonicalParent as NSString).appendingPathComponent(lastComponent)

        // 受保护路径：只拒绝目标本身。
        guard !protectedExactPaths.contains(canonicalPath) else {
            throw DeletionGuardError.protectedRoot
        }
        // 受保护子树：拒绝目录及全部后代（按路径组件边界比较）。
        guard !protectedSubtrees.contains(where: { Self.isInside(root: $0, path: canonicalPath) }) else {
            throw DeletionGuardError.protectedSubtree
        }
        // 必须位于本模块允许的根目录之内。
        guard allowedRoots.contains(where: { Self.isInside(root: $0, path: canonicalPath) }) else {
            throw DeletionGuardError.outsideAllowedRoots
        }

        // 读取当前身份并校验：拒绝符号链接、拒绝身份缺失、拒绝身份变化。
        let current = try identityProvider.identity(at: canonicalPath)
        guard current.kind != .symbolicLink else {
            throw DeletionGuardError.symbolicLink
        }
        guard let expectedIdentity else {
            throw DeletionGuardError.identityUnavailable
        }
        guard current == expectedIdentity else {
            throw DeletionGuardError.identityChanged
        }
        return current
    }

    /// 路径组件边界的包含判断：
    /// "/Users/a/Library/Caches2" 不命中 "/Users/a/Library/Caches"。
    private static func isInside(root: String, path: String) -> Bool {
        guard !root.isEmpty else { return false }
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}
