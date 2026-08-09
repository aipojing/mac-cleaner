import Foundation

public struct LargeFileScannerModule: CleanerModule {
    public static let defaultMinimumAllocatedSize: Int64 = 100 * 1024 * 1024

    public let identifier = ModuleIdentifier.largeFiles
    public let displayName = "大文件"
    public var description: String {
        "主目录下 ≥\(minimumAllocatedSize.formattedSize) 的大文件"
    }

    private let scanRoot: String
    public let minimumAllocatedSize: Int64
    private let limit: Int

    public init(
        scanRoot: String = DiskScanner.homeDirectory,
        minAllocatedSize: Int64 = defaultMinimumAllocatedSize,
        limit: Int = 50
    ) {
        self.scanRoot = scanRoot
        self.minimumAllocatedSize = minAllocatedSize
        self.limit = limit
    }

    public func isAvailable() -> Bool { true }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()

        // 顺序型模块：整个枚举过程占用一个文件任务许可。
        return try await context.fileTaskLimiter.withPermit {
            let files = try await collectLargeFiles(onUpdate: context.onLargeFileUpdate)
            let items = files.map { makeItem(from: $0) }

            return ScanResult(
                module: .largeFiles,
                items: items,
                scanDuration: Date().timeIntervalSince(start)
            )
        }
    }

    /// 实时快照与最终结果共用的条目构造，防止分类/身份字段漂移。
    private func makeItem(from file: FileMetadata) -> CleanableItem {
        let name = (file.path as NSString).lastPathComponent
        let dir = ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let kind = classify(path: file.path, fileName: name, dirName: dir)

        return CleanableItem(
            path: file.path,
            displayName: "\(dir)/\(name)",
            // 默认展示磁盘实际占用；逻辑大小保留在 allocatedSize 之外的详情来源
            size: file.allocatedSize,
            category: .largeFiles,
            subcategory: ext.isEmpty ? "unknown-extension" : ext,
            evidenceTags: ["large-file", kind],
            fileIdentity: file.identity,
            allocatedSize: file.allocatedSize,
            linkCount: file.linkCount
        )
    }

    // MARK: - 有界枚举

    /// fts 枚举过程中立即把满足阈值的对象放入最小堆，
    /// 常驻候选不超过 limit，不再全量收集后排序。
    /// 评分与阈值都使用实际占用（st_blocks * 512）。
    /// onUpdate 非 nil 时边枚举边发布限频的实时快照，并以最终快照收尾。
    /// fts 许可等待挂起（可取消）；枚举循环内逐条检查取消。
    private func collectLargeFiles(
        onUpdate: (@Sendable (LargeFileScanUpdate) -> Void)?
    ) async throws -> [FileMetadata] {
        try await FTSTraversalGate.withPermit {
            let cPath = scanRoot.withCString { strdup($0) }
            guard let cPath else { return [] }
            defer { free(cPath) }

            // 与重复文件模块共用排除集合：.git/objects/pack 下的 pack 文件
            // repack 后常超 100MB，删除即损坏仓库；node_modules/Pods 同理。
            let skipDirs: Set<String> = ScanTraversalExclusions.common.union(["Library", ".Trash"])

            var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
                return []
            }
            defer { fts_close(fts) }

            let progress = ScanProgress.shared
            var heap = TopNHeap<FileMetadata>(
                capacity: limit,
                score: \.allocatedSize,
                tieBreak: \.path
            )
            // 首发立即、间隔内合并、结束必发的限频发布器（每秒最多 5 次）
            var publisher = onUpdate.map { handler in
                LargeFileUpdatePublisher<LargeFileScanUpdate>(
                    minimumInterval: 0.2,
                    now: { ProcessInfo.processInfo.systemUptime },
                    deliver: handler
                )
            }
            var matchedFileCount = 0
            var matchedAllocatedSize: Int64 = 0
            var countedIdentities: Set<String> = []

            func snapshot(isFinal: Bool) -> LargeFileScanUpdate {
                LargeFileScanUpdate(
                    items: heap.sortedDescending().map { makeItem(from: $0) },
                    matchedFileCount: matchedFileCount,
                    matchedAllocatedSize: matchedAllocatedSize,
                    isFinal: isFinal
                )
            }

            while let entry = fts_read(fts) {
                if Task.isCancelled { throw CancellationError() }

                let filePath = String(cString: entry.pointee.fts_path)
                let name = (filePath as NSString).lastPathComponent

                if entry.pointee.fts_info == FTS_D && skipDirs.contains(name) {
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }

                guard entry.pointee.fts_info == FTS_F else { continue }
                let st = entry.pointee.fts_statp.pointee
                let metadata = FileMetadata.fromStat(
                    path: filePath,
                    device: UInt64(st.st_dev),
                    inode: UInt64(st.st_ino),
                    mode: st.st_mode,
                    logicalSize: Int64(st.st_size),
                    blocks: Int64(st.st_blocks),
                    linkCount: UInt64(st.st_nlink),
                    modificationTimeNanoseconds: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                        + Int64(st.st_mtimespec.tv_nsec)
                )
                guard metadata.allocatedSize >= minimumAllocatedSize else { continue }
                matchedFileCount += 1
                // 硬链接去重：同一 (device, inode) 的物理占用只计一次
                if countedIdentities.insert("\(st.st_dev):\(st.st_ino)").inserted {
                    matchedAllocatedSize += metadata.allocatedSize
                }
                heap.insert(metadata)
                progress.report(path: filePath)
                publisher?.submit(snapshot(isFinal: false))
            }

            let finalFiles = heap.sortedDescending()
            publisher?.finish(snapshot(isFinal: true))
            return finalFiles
        }
    }

    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        Deleter().delete(items: items, module: .largeFiles, dryRun: dryRun, useTrash: true)
    }

    // MARK: - 事实分类（只输出类型标签，不做风险或推荐判断）

    private func classify(path: String, fileName: String, dirName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()

        // 构建产物（target/ 下的 jar/war/ear，build/ 下的产物）
        if isBuildArtifact(path: path, dirName: dirName, ext: ext) {
            return "build-artifact"
        }

        // 安装包/镜像
        if isInstaller(ext: ext) {
            return "installer"
        }

        // 压缩包
        if isArchive(ext: ext) {
            return "archive"
        }

        // 日志文件
        if ext == "log" {
            return "log"
        }

        // 默认：用户文件
        return "user-file"
    }

    private func isBuildArtifact(path: String, dirName: String, ext: String) -> Bool {
        let buildDirNames: Set<String> = ["target", "build", "dist", "out", "output", ".build"]
        let buildExtensions: Set<String> = ["jar", "war", "ear", "class", "dex", "apk", "aab", "ipa", "o", "a"]

        // 路径中包含 /target/ 或 /build/ 等构建目录
        let pathComponents = Set(path.split(separator: "/").map(String.init))
        let inBuildDir = !buildDirNames.isDisjoint(with: pathComponents)

        if inBuildDir && buildExtensions.contains(ext) {
            return true
        }

        // 直接在 target/ 或 build/ 目录下
        if buildDirNames.contains(dirName) {
            return true
        }

        return false
    }

    private func isInstaller(ext: String) -> Bool {
        ["dmg", "pkg", "iso", "msi", "exe", "app"].contains(ext)
    }

    private func isArchive(ext: String) -> Bool {
        ["zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz"].contains(ext)
    }
}
