import Foundation

public struct ResidualGroup: Identifiable, Sendable {
    public let id: String  // location key
    public let label: String
    public let items: [ResidualItem]

    public var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    public init(id: String, label: String, items: [ResidualItem]) {
        self.id = id
        self.label = label
        self.items = items
    }
}

public struct ResidualItem: Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let name: String
    public let size: Int64
    /// 扫描时记录的文件身份。nil 表示无法验证身份，卸载执行会被拒绝。
    public let fileIdentity: FileIdentity?

    public init(path: String, name: String, size: Int64, fileIdentity: FileIdentity? = nil) {
        self.id = UUID()
        self.path = path
        self.name = name
        self.size = size
        self.fileIdentity = fileIdentity
    }

    /// 内部完整初始化器：复制时保留同一 id。
    private init(id: UUID, path: String, name: String, size: Int64, fileIdentity: FileIdentity?) {
        self.id = id
        self.path = path
        self.name = name
        self.size = size
        self.fileIdentity = fileIdentity
    }

    /// 返回带指定身份的副本（同一 id）。
    public func withFileIdentity(_ identity: FileIdentity?) -> ResidualItem {
        ResidualItem(id: id, path: path, name: name, size: size, fileIdentity: identity)
    }
}

public struct AppResidualFiles: Sendable {
    public let groups: [ResidualGroup]

    public var totalSize: Int64 {
        groups.reduce(0) { $0 + $1.totalSize }
    }

    public var isEmpty: Bool {
        groups.allSatisfy(\.items.isEmpty)
    }

    public var totalItemCount: Int {
        groups.reduce(0) { $0 + $1.items.count }
    }

    public init(groups: [ResidualGroup]) {
        self.groups = groups.filter { !$0.items.isEmpty }
    }
}

public struct UninstallReport: Sendable {
    public let appName: String
    public let appRemoved: Bool
    public let residualsRemoved: Int
    public let failures: Int
    /// 已移入废纸篓的大小。移到废纸篓并未真正释放磁盘空间，
    /// 需要用户清空废纸篓后才释放，因此不命名为"已释放"。
    public let bytesMovedToTrash: Int64

    public init(
        appName: String, appRemoved: Bool, residualsRemoved: Int,
        failures: Int, bytesMovedToTrash: Int64
    ) {
        self.appName = appName
        self.appRemoved = appRemoved
        self.residualsRemoved = residualsRemoved
        self.failures = failures
        self.bytesMovedToTrash = bytesMovedToTrash
    }
}
