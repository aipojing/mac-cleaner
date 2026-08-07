import Foundation

/// 重复文件保留策略
public enum DuplicateRetentionStrategy: String, Sendable {
    /// 保留最新修改的文件
    case keepNewest = "keep_newest"
    /// 保留路径最短的文件（通常是原始位置）
    case keepShortestPath = "keep_shortest_path"
    /// 保留指定目录下的文件
    case keepInDirectory = "keep_in_directory"
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String  // full hash
    public let fileSize: Int64
    public let files: [DuplicateFile]

    /// 重复组浪费的物理空间：按 (device, inode) 去重——同 inode 的
    /// 多条硬链接路径共享同一物理对象，全删也只释放一次。
    /// 无身份信息的文件按独立对象计入。
    public var totalWastedSpace: Int64 {
        var objectKeys: Set<String> = []
        var unidentifiedCount = 0
        for file in files {
            if let identity = file.fileIdentity {
                objectKeys.insert("\(identity.device):\(identity.inode)")
            } else {
                unidentifiedCount += 1
            }
        }
        let objectCount = objectKeys.count + unidentifiedCount
        return fileSize * Int64(max(0, objectCount - 1))
    }

    public var duplicateCount: Int { files.count }

    public init(id: String, fileSize: Int64, files: [DuplicateFile]) {
        self.id = id
        self.fileSize = fileSize
        self.files = files
    }

    // MARK: - 保留策略

    /// 应用策略后返回应删除的文件列表（保留 1 份，其余标为删除）
    public func filesToRemove(strategy: DuplicateRetentionStrategy, preferredDirectory: String? = nil) -> [DuplicateFile] {
        guard files.count >= 2 else { return [] }

        let keepFile: DuplicateFile?
        switch strategy {
        case .keepNewest:
            keepFile = files.max(by: { $0.modifiedDate < $1.modifiedDate })
        case .keepShortestPath:
            keepFile = files.min(by: { $0.path.count < $1.path.count })
        case .keepInDirectory:
            guard let dir = preferredDirectory else {
                // 无指定目录时回退到 keepNewest
                keepFile = files.max(by: { $0.modifiedDate < $1.modifiedDate })
                break
            }
            keepFile = files.first { $0.path.hasPrefix(dir) }
                ?? files.max(by: { $0.modifiedDate < $1.modifiedDate })
        }

        guard let keep = keepFile else { return [] }
        return files.filter { $0.id != keep.id }
    }

    /// 保留最新修改的文件，返回要删除的列表
    public func keepNewest() -> [DuplicateFile] {
        filesToRemove(strategy: .keepNewest)
    }

    /// 保留路径最短的文件，返回要删除的列表
    public func keepShortestPath() -> [DuplicateFile] {
        filesToRemove(strategy: .keepShortestPath)
    }

    /// 保留指定目录下的文件，返回要删除的列表
    public func keepInDirectory(_ directory: String) -> [DuplicateFile] {
        filesToRemove(strategy: .keepInDirectory, preferredDirectory: directory)
    }
}

public struct DuplicateFile: Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let size: Int64
    public let modifiedDate: Date
    /// 扫描时记录的文件身份；nil 表示无法验证，删除 guard 会拒绝。
    public let fileIdentity: FileIdentity?

    public var name: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }

    public init(path: String, size: Int64, modifiedDate: Date, fileIdentity: FileIdentity? = nil) {
        self.id = UUID()
        self.path = path
        self.size = size
        self.modifiedDate = modifiedDate
        self.fileIdentity = fileIdentity
    }
}
