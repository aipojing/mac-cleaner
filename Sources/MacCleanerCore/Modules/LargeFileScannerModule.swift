import Foundation

public struct LargeFileScannerModule: CleanerModule {
    public let identifier = ModuleIdentifier.largeFiles
    public let displayName = "大文件"
    public let description = "主目录下 >100MB 的大文件"

    private let scanRoot: String
    private let minAllocatedSize: Int64
    private let limit: Int

    public init(
        scanRoot: String = DiskScanner.homeDirectory,
        minAllocatedSize: Int64 = 100 * 1024 * 1024,
        limit: Int = 50
    ) {
        self.scanRoot = scanRoot
        self.minAllocatedSize = minAllocatedSize
        self.limit = limit
    }

    public func isAvailable() -> Bool { true }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()

        // 顺序型模块：整个枚举过程占用一个文件任务许可。
        return try await context.fileTaskLimiter.withPermit {
            let files = collectLargeFiles()
            let items = files.map { file in
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

            return ScanResult(
                module: .largeFiles,
                items: items,
                scanDuration: Date().timeIntervalSince(start)
            )
        }
    }

    // MARK: - 有界枚举

    /// fts 枚举过程中立即把满足阈值的对象放入最小堆，
    /// 常驻候选不超过 limit，不再全量收集后排序。
    /// 评分与阈值都使用实际占用（st_blocks * 512）。
    private func collectLargeFiles() -> [FileMetadata] {
        FTSTraversalGate.withPermit {
            let cPath = scanRoot.withCString { strdup($0) }
            guard let cPath else { return [] }
            defer { free(cPath) }

            let skipDirs: Set<String> = ["Library", ".Trash", ".gradle", ".m2", ".npm", ".cocoapods", ".pub-cache"]

            var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
                return []
            }
            defer { fts_close(fts) }

            let progress = ScanProgress.shared
            var heap = TopNHeap<FileMetadata>(
                capacity: limit,
                score: \.allocatedSize,
                tieBreak: \.path
            )

            while let entry = fts_read(fts) {
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
                guard metadata.allocatedSize >= minAllocatedSize else { continue }
                heap.insert(metadata)
                progress.report(path: filePath)
            }

            return heap.sortedDescending()
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
