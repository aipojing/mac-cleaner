import Foundation

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let bundleID: String
    public let version: String
    public let path: String
    public let bundleSize: Int64
    public let iconPath: String?
    /// 扫描时记录的应用 bundle 身份。nil 表示无法验证身份，卸载执行会被拒绝。
    public let fileIdentity: FileIdentity?

    public init(
        name: String, bundleID: String, version: String,
        path: String, bundleSize: Int64, iconPath: String? = nil,
        fileIdentity: FileIdentity? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.path = path
        self.bundleSize = bundleSize
        self.iconPath = iconPath
        self.fileIdentity = fileIdentity
    }

    /// 内部完整初始化器：复制时保留同一 id。
    private init(
        id: UUID, name: String, bundleID: String, version: String,
        path: String, bundleSize: Int64, iconPath: String?,
        fileIdentity: FileIdentity?
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.path = path
        self.bundleSize = bundleSize
        self.iconPath = iconPath
        self.fileIdentity = fileIdentity
    }

    /// 返回带指定身份的副本（同一 id）。
    public func withFileIdentity(_ identity: FileIdentity?) -> InstalledApp {
        InstalledApp(
            id: id, name: name, bundleID: bundleID, version: version,
            path: path, bundleSize: bundleSize, iconPath: iconPath,
            fileIdentity: identity
        )
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.id == rhs.id
    }
}
