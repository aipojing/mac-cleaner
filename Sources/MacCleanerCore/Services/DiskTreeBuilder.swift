import Foundation

public struct DiskTreeBuilder: Sendable {
    public init() {}

    /// 用 fts 构建深度有限的目录树。
    /// 在调用任务上下文中执行（继承取消与优先级）：页面关闭取消任务后，
    /// 许可等待立即抛 CancellationError，遍历循环也会在下一轮中止。
    /// 取消或失败时返回空根节点（调用方是正在关闭的页面，无需错误细节）。
    public func buildTree(at path: String, maxDepth: Int = 3) async -> DirectoryNode {
        do {
            return try await buildTreeFTS(at: path, maxDepth: maxDepth)
        } catch {
            return DirectoryNode(
                name: (path as NSString).lastPathComponent,
                path: path,
                size: 0,
                children: []
            )
        }
    }

    /// 单次 fts 遍历构建目录树：自底向上累计每个目录的 allocated size，
    /// 不再对每个子目录重复遍历其子树（旧实现是 O(深度) 次全树遍历）。
    /// 整个遍历只占用一个 FTSTraversalGate 许可；可取消。
    private func buildTreeFTS(at rootPath: String, maxDepth: Int) async throws -> DirectoryNode {
        let skipNames: Set<String> = [".Trash", ".Spotlight-V100", ".fseventsd"]
        let rootName = (rootPath as NSString).lastPathComponent

        // 遍历结果：所有目录的完整大小 + maxDepth 范围内的直接子项记录
        struct TraversalResult {
            var dirSizes: [String: Int64] = [:]
            var childRecords: [String: [(name: String, path: String, isDir: Bool, size: Int64)]] = [:]
        }

        let traversal = try await FTSTraversalGate.withPermit { () throws -> TraversalResult in
            var result = TraversalResult()

            let cPath = rootPath.withCString { strdup($0) }
            guard let cPath else { return result }
            defer { free(cPath) }

            var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return result }
            defer { fts_close(fts) }

            // 目录帧栈：文件大小先入当前目录帧，目录收尾时向父帧传播
            var frames: [(path: String, size: Int64)] = []
            var seenObjects: Set<String> = []
            let progress = ScanProgress.shared

            while let entry = fts_read(fts) {
                if Task.isCancelled { throw CancellationError() }

                let info = entry.pointee.fts_info
                let path = String(cString: entry.pointee.fts_path)
                let level = Int(entry.pointee.fts_level)

                switch Int32(info) {
                case FTS_D:
                    let name = (path as NSString).lastPathComponent
                    if skipNames.contains(name) {
                        fts_set(fts, entry, FTS_SKIP)
                        continue
                    }
                    if level > 0 && level - 1 <= maxDepth {
                        let parent = (path as NSString).deletingLastPathComponent
                        result.childRecords[parent, default: []].append((name, path, true, 0))
                    }
                    frames.append((path, 0))

                case FTS_DP:
                    if let frame = frames.popLast() {
                        result.dirSizes[frame.path] = frame.size
                        if !frames.isEmpty {
                            frames[frames.count - 1].size += frame.size
                        }
                    }

                case FTS_F, FTS_SL, FTS_SLNONE:
                    let st = entry.pointee.fts_statp.pointee
                    // 同一 device/inode 的硬链接整棵树只计一次
                    let key = "\(st.st_dev):\(st.st_ino)"
                    let size = seenObjects.insert(key).inserted
                        ? max(0, Int64(st.st_blocks)) * 512
                        : 0
                    if size > 0, !frames.isEmpty {
                        frames[frames.count - 1].size += size
                    }
                    if level - 1 <= maxDepth {
                        let parent = (path as NSString).deletingLastPathComponent
                        let name = (path as NSString).lastPathComponent
                        result.childRecords[parent, default: []].append((name, path, false, size))
                    }
                    progress.report(path: path)

                default:
                    // FTS_DNR / FTS_ERR / FTS_NS 等：跳过不可读分支
                    continue
                }
            }
            return result
        }

        let dirSizes = traversal.dirSizes
        let childRecords = traversal.childRecords

        guard dirSizes[rootPath] != nil else {
            return DirectoryNode(name: rootName, path: rootPath, size: 0, children: [])
        }

        // 自底向上物化节点；大目录展开到 maxDepth，小目录保留为叶子
        func makeNode(path: String, name: String, depthLeft: Int) -> DirectoryNode {
            let records = childRecords[path] ?? []
            let children: [DirectoryNode] = records.map { rec in
                let dirSize = dirSizes[rec.path] ?? 0
                if rec.isDir && depthLeft > 1 && dirSize > 10 * 1024 * 1024 {
                    return makeNode(path: rec.path, name: rec.name, depthLeft: depthLeft - 1)
                }
                return DirectoryNode(
                    name: rec.name,
                    path: rec.path,
                    size: rec.isDir ? dirSize : rec.size,
                    children: [],
                    isDirectory: rec.isDir
                )
            }
            .sorted { $0.size > $1.size }

            return DirectoryNode(
                name: name,
                path: path,
                size: dirSizes[path] ?? children.reduce(Int64(0)) { $0 + $1.size },
                children: children
            )
        }

        return makeNode(path: rootPath, name: rootName, depthLeft: maxDepth)
    }
}
