import Foundation

public struct DuplicateFilesModule: CleanerModule, Sendable {
    public let identifier = ModuleIdentifier.duplicateFiles
    public let displayName = "重复文件"
    public let description = "相同内容的重复文件"

    private let scanRoot: String
    private let minSize: Int64
    private let hasher: FileHasher
    private let skipDirectories: Set<String>
    private let identityProvider: any FileIdentityProviding
    private let hashCache: FileHashCache?

    /// 默认跳过的目录
    public static let defaultSkipDirectories: Set<String> = [
        "Library", ".Trash", ".git", "node_modules",
        ".gradle", ".m2", ".npm", ".cocoapods", ".pub-cache",
        ".cargo", "Pods", ".build", "DerivedData",
        "venv", ".venv", "__pycache__", ".tox",
    ]

    public init(
        scanRoot: String = DiskScanner.homeDirectory,
        minSize: Int64 = 1024,
        hasher: FileHasher = FileHasher(),
        skipDirectories: Set<String>? = nil,
        identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider(),
        hashCache: FileHashCache? = nil
    ) {
        self.scanRoot = scanRoot
        self.minSize = minSize
        self.hasher = hasher
        self.skipDirectories = skipDirectories ?? Self.defaultSkipDirectories
        self.identityProvider = identityProvider
        self.hashCache = hashCache
    }

    public func isAvailable() -> Bool { true }

    /// 同一物理对象（device + inode）：多个硬链接路径共享内容，
    /// hash 只计算一次，但每条路径都独立成为候选。
    struct PhysicalObject: Sendable {
        let metadata: FileMetadata
        var paths: [String]
    }

    /// full hash 确认的重复组：id 为 full SHA-256。
    struct ConfirmedGroup: Sendable {
        let id: String
        let objects: [PhysicalObject]
    }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()

        // Phase 1: fts 枚举，按逻辑大小分桶（内容相同必然大小相同）。
        // 占用一个文件任务许可，枚举与元数据来自同一次 lstat。
        let sizeGroups = try await context.fileTaskLimiter.withPermit {
            self.groupFilesBySize()
        }

        // Phase 2: 同大小桶内按 (device,inode) 合并物理对象；
        // 同 inode 硬链接不形成重复组（组必须包含 ≥2 个不同 inode）。
        let buckets = Self.physicalObjectBuckets(from: sizeGroups)

        // Phase 3: 首/中/尾三段抽样（最多各 64 KiB），hash 并发受限
        let sampledGroups = try await refineBySampledHash(buckets: buckets, context: context)

        // Phase 4: 只对 sampled hash 相同的桶计算 full hash（持久化缓存）
        let confirmedGroups = try await confirmByFullHash(sampledGroups: sampledGroups, context: context)

        // 取消时 hash 阶段传播 CancellationError；此处兜底
        try Task.checkCancellation()

        // 转换为 CleanableItem：身份与 linkCount 来自枚举时的同一次 lstat。
        // 硬链接的每条路径独立成为候选（不隐式合并删除）。
        var items: [CleanableItem] = []
        for group in confirmedGroups {
            for object in group.objects {
                let metadata = object.metadata
                for path in object.paths {
                    items.append(CleanableItem(
                        path: path,
                        displayName: (path as NSString).lastPathComponent,
                        size: metadata.allocatedSize,
                        category: .duplicateFiles,
                        subcategory: group.id,
                        evidenceTags: ["duplicate-file", "content-hash"],
                        fileIdentity: metadata.identity,
                        allocatedSize: metadata.allocatedSize,
                        linkCount: metadata.linkCount
                    ))
                }
            }
        }

        return ScanResult(
            module: .duplicateFiles,
            items: items,
            scanDuration: Date().timeIntervalSince(start)
        )
    }

    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        Deleter().delete(items: items, module: .duplicateFiles, dryRun: dryRun, useTrash: true)
    }

    /// 从 ScanResult 重建 DuplicateGroup 列表
    public func groups(from result: ScanResult) -> [DuplicateGroup] {
        var grouped: [String: [DuplicateFile]] = [:]
        let fm = FileManager.default

        for item in result.items {
            let hash = item.subcategory ?? ""
            let attrs = try? fm.attributesOfItem(atPath: item.path)
            let modDate = attrs?[.modificationDate] as? Date ?? Date()
            let file = DuplicateFile(
                path: item.path, size: item.size, modifiedDate: modDate,
                fileIdentity: item.fileIdentity
            )
            grouped[hash, default: []].append(file)
        }

        return grouped.compactMap { hash, files in
            guard files.count >= 2 else { return nil }
            return DuplicateGroup(id: hash, fileSize: files[0].size, files: files)
        }.sorted { $0.totalWastedSpace > $1.totalWastedSpace }
    }

    // MARK: - Phase 1: 大小分桶

    private func groupFilesBySize() -> [Int64: [FileMetadata]] {
        FTSTraversalGate.withPermit {
            let cPath = scanRoot.withCString { strdup($0) }
            guard let cPath else { return [:] }
            defer { free(cPath) }

            let skipDirs = self.skipDirectories

            var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return [:] }
            defer { fts_close(fts) }

            var groups: [Int64: [FileMetadata]] = [:]

            while let entry = fts_read(fts) {
                if entry.pointee.fts_info == FTS_D {
                    let dirPath = String(cString: entry.pointee.fts_path)
                    let dirName = (dirPath as NSString).lastPathComponent
                    if skipDirs.contains(dirName) {
                        fts_set(fts, entry, FTS_SKIP)
                        continue
                    }
                }

                if entry.pointee.fts_info == FTS_F {
                    let st = entry.pointee.fts_statp.pointee
                    let size = Int64(st.st_size)
                    guard size >= minSize else { continue }
                    let filePath = String(cString: entry.pointee.fts_path)
                    let metadata = FileMetadata.fromStat(
                        path: filePath,
                        device: UInt64(st.st_dev),
                        inode: UInt64(st.st_ino),
                        mode: st.st_mode,
                        logicalSize: size,
                        blocks: Int64(st.st_blocks),
                        linkCount: UInt64(st.st_nlink),
                        modificationTimeNanoseconds: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                            + Int64(st.st_mtimespec.tv_nsec)
                    )
                    groups[size, default: []].append(metadata)
                }
            }

            // 只保留可能有重复的桶（>=2 个同大小文件）
            return groups.filter { $0.value.count >= 2 }
        }
    }

    // MARK: - Phase 2: 物理对象合并

    /// 同大小桶内按 (device,inode) 合并硬链接为物理对象；
    /// 只保留含 ≥2 个不同物理对象的桶。
    static func physicalObjectBuckets(
        from sizeGroups: [Int64: [FileMetadata]]
    ) -> [(size: Int64, objects: [PhysicalObject])] {
        var buckets: [(size: Int64, objects: [PhysicalObject])] = []

        for (size, metadatas) in sizeGroups.sorted(by: { $0.key < $1.key }) {
            var byInode: [String: PhysicalObject] = [:]
            var order: [String] = []
            for metadata in metadatas {
                let key = "\(metadata.identity.device):\(metadata.identity.inode)"
                if byInode[key] == nil {
                    byInode[key] = PhysicalObject(metadata: metadata, paths: [metadata.path])
                    order.append(key)
                } else {
                    byInode[key]?.paths.append(metadata.path)
                }
            }
            let objects = order.compactMap { byInode[$0] }
            if objects.count >= 2 {
                buckets.append((size, objects))
            }
        }

        return buckets
    }

    // MARK: - Phase 3: 三段抽样

    private func refineBySampledHash(
        buckets: [(size: Int64, objects: [PhysicalObject])],
        context: ScanContext
    ) async throws -> [(size: Int64, sampled: [(object: PhysicalObject, hash: String)])] {
        let hasher = self.hasher
        var result: [(size: Int64, sampled: [(object: PhysicalObject, hash: String)])] = []

        for (size, objects) in buckets {
            let sampled: [(object: PhysicalObject, hash: String)?] = await withTaskGroup(
                of: (Int, (object: PhysicalObject, hash: String)?).self
            ) { group in
                for (index, object) in objects.enumerated() {
                    group.addTask {
                        let hash = try? await context.hashTaskLimiter.withPermit {
                            hasher.sampledHash(
                                path: object.metadata.path,
                                logicalSize: object.metadata.logicalSize
                            )
                        }
                        guard let hash = hash ?? nil else { return (index, nil) }
                        return (index, (object, hash))
                    }
                }
                var collected: [(Int, (object: PhysicalObject, hash: String)?)] = []
                for await pair in group {
                    collected.append(pair)
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            // 按 sampled hash 再分桶，只保留 ≥2 个对象的
            var byHash: [String: [(object: PhysicalObject, hash: String)]] = [:]
            var hashOrder: [String] = []
            for case let object? in sampled {
                if byHash[object.hash] == nil { hashOrder.append(object.hash) }
                byHash[object.hash, default: []].append(object)
            }
            for hash in hashOrder {
                if let group = byHash[hash], group.count >= 2 {
                    result.append((size, group))
                }
            }
        }

        try Task.checkCancellation()
        return result
    }

    // MARK: - Phase 4: full hash 确认（持久化缓存）

    private func confirmByFullHash(
        sampledGroups: [(size: Int64, sampled: [(object: PhysicalObject, hash: String)])],
        context: ScanContext
    ) async throws -> [ConfirmedGroup] {
        let cache = hashCache ?? FileHashCache()
        var groups: [ConfirmedGroup] = []

        for (_, sampled) in sampledGroups {
            let confirmed: [(object: PhysicalObject, fullHash: String)?] = try await withThrowingTaskGroup(
                of: (Int, (object: PhysicalObject, fullHash: String)?).self
            ) { group in
                for (index, entry) in sampled.enumerated() {
                    group.addTask {
                        do {
                            let fullHash = try await context.hashTaskLimiter.withPermit {
                                try await cache.fullHash(for: entry.object.metadata)
                            }
                            return (index, (entry.object, fullHash))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // 单个文件读取失败跳过该对象，不影响整组
                            return (index, nil)
                        }
                    }
                }
                var collected: [(Int, (object: PhysicalObject, fullHash: String)?)] = []
                for try await pair in group {
                    collected.append(pair)
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            // 按 full hash 分组，≥2 个不同物理对象才形成重复组
            var byHash: [String: [PhysicalObject]] = [:]
            var hashOrder: [String] = []
            for case let entry? in confirmed {
                if byHash[entry.fullHash] == nil { hashOrder.append(entry.fullHash) }
                byHash[entry.fullHash, default: []].append(entry.object)
            }

            for hash in hashOrder {
                guard let objects = byHash[hash], objects.count >= 2 else { continue }
                // 组内必须含 ≥2 个不同 inode（同 inode 硬链接不构成重复组）
                let distinctInodes = Set(objects.map {
                    "\($0.metadata.identity.device):\($0.metadata.identity.inode)"
                })
                guard distinctInodes.count >= 2 else { continue }
                groups.append(ConfirmedGroup(id: hash, objects: objects))
            }
        }

        try Task.checkCancellation()
        return groups
    }
}
