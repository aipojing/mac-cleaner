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
    private let deleter: Deleter
    /// 最近一次扫描的组记录，供 clean 做执行层不变量与漂移校验。
    private let scanRegistry = DuplicateScanRegistry()

    /// 默认跳过的目录：与所有递归扫描共用 ScanTraversalExclusions，
    /// 另加构建产物与虚拟环境目录。
    public static let defaultSkipDirectories: Set<String> =
        ScanTraversalExclusions.common.union([
            "Library", ".Trash",
            ".build", "DerivedData",
            "venv", ".venv", "__pycache__", ".tox",
        ])

    public init(
        scanRoot: String = DiskScanner.homeDirectory,
        minSize: Int64 = 1024,
        hasher: FileHasher = FileHasher(),
        skipDirectories: Set<String>? = nil,
        identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider(),
        hashCache: FileHashCache? = nil,
        deleter: Deleter = Deleter()
    ) {
        self.scanRoot = scanRoot
        self.minSize = minSize
        self.hasher = hasher
        self.skipDirectories = skipDirectories ?? Self.defaultSkipDirectories
        self.identityProvider = identityProvider
        self.hashCache = hashCache
        self.deleter = deleter
    }

    public func isAvailable() -> Bool { true }

    /// 同一物理对象（device + inode）：多个硬链接路径共享内容，
    /// hash 只计算一次，但每条路径都独立成为候选。
    struct PhysicalObject: Sendable {
        let metadata: FileMetadata
        var paths: [String]
    }

    /// full hash 确认的重复组：id 为 full SHA-256；每个对象携带扫描时的
    /// sampled hash，供 clean 前的内容漂移重验比对。
    struct ConfirmedGroup: Sendable {
        let id: String
        let objects: [(object: PhysicalObject, sampledHash: String)]
    }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()

        // Phase 1: fts 枚举，按逻辑大小分桶（内容相同必然大小相同）。
        // 占用一个文件任务许可，枚举与元数据来自同一次 lstat。
        let sizeGroups = try await context.fileTaskLimiter.withPermit {
            try await self.groupFilesBySize()
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
            for entry in group.objects {
                let metadata = entry.object.metadata
                for path in entry.object.paths {
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

        // 记录执行层校验所需的组成员与抽样指纹
        // （clean 的“每组至少保留一份”不变量与删除前漂移重验）。
        var memberMap: [String: Set<String>] = [:]
        var recordMap: [String: DuplicateScanRegistry.FileRecord] = [:]
        for group in confirmedGroups {
            for entry in group.objects {
                for path in entry.object.paths {
                    memberMap[group.id, default: []].insert(path)
                    recordMap[path] = DuplicateScanRegistry.FileRecord(
                        groupHash: group.id,
                        logicalSize: entry.object.metadata.logicalSize,
                        sampledHash: entry.sampledHash
                    )
                }
            }
        }
        await scanRegistry.replace(groupMembers: memberMap, fileRecords: recordMap)

        return ScanResult(
            module: .duplicateFiles,
            items: items,
            scanDuration: Date().timeIntervalSince(start)
        )
    }

    /// 执行层防护（不依赖 UI 层的 keptFiles 选择）：
    /// 1. 组保留不变量：按 subcategory（组 hash）分组，某组的所有已知路径
    ///    都在删除列表中时整组拒绝删除。组的已知成员来自本模块最近一次扫描；
    ///    无扫描记录时按“传入 items 构成完整一组”处理（同组 ≥2 条即拒绝，
    ///    单条目无法证明属于重复组则放行）。
    /// 2. 内容漂移重验：扫描记录在案的路径，删除前重新计算 sampled hash，
    ///    与扫描时不一致（扫描后内容已变，可能不再是重复）则拒绝该文件。
    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        let groupMembers = await scanRegistry.groupMembers
        let fileRecords = await scanRegistry.fileRecords

        var rejectedGroups: Set<String> = []
        for (hash, groupItems) in Dictionary(grouping: items, by: { $0.subcategory ?? "" }) {
            guard !hash.isEmpty else { continue }
            if let known = groupMembers[hash] {
                if known.isSubset(of: Set(groupItems.map(\.path))) {
                    rejectedGroups.insert(hash)
                }
            } else if groupItems.count >= 2 {
                rejectedGroups.insert(hash)
            }
        }

        var allowed: [CleanableItem] = []
        var rejected: [FailedItem] = []
        for item in items {
            if rejectedGroups.contains(item.subcategory ?? "") {
                rejected.append(FailedItem(
                    path: item.path,
                    error: "整组删除会破坏“每组至少保留一份”不变量，已拒绝",
                    reason: .unsafeTarget,
                    expectedSize: item.size
                ))
                continue
            }
            if let record = fileRecords[item.path] {
                let current = hasher.sampledHash(path: item.path, logicalSize: record.logicalSize)
                if current != record.sampledHash {
                    rejected.append(FailedItem(
                        path: item.path,
                        error: "扫描后文件内容已变化，可能不再是重复文件，已拒绝",
                        reason: .contentModified,
                        expectedSize: item.size
                    ))
                    continue
                }
            }
            allowed.append(item)
        }

        let report = deleter.delete(items: allowed, module: .duplicateFiles, dryRun: dryRun, useTrash: true)
        if !dryRun {
            // 已删路径移出组记录：组内只剩一份时后续删除会被不变量拦截
            await scanRegistry.removePaths(report.deletedItems.map(\.path))
        }
        return CleanupReport(
            module: .duplicateFiles,
            deletedItems: report.deletedItems,
            failedItems: report.failedItems + rejected,
            dryRun: dryRun,
            expectedSize: items.reduce(Int64(0)) { $0 + $1.size },
            actualFreed: report.actualFreed
        )
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

    private func groupFilesBySize() async throws -> [Int64: [FileMetadata]] {
        try await FTSTraversalGate.withPermit {
            let cPath = scanRoot.withCString { strdup($0) }
            guard let cPath else { return [:] }
            defer { free(cPath) }

            let skipDirs = self.skipDirectories

            var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return [:] }
            defer { fts_close(fts) }

            var groups: [Int64: [FileMetadata]] = [:]

            while let entry = fts_read(fts) {
                if Task.isCancelled { throw CancellationError() }

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
            let sampled: [(object: PhysicalObject, hash: String)?] = try await withThrowingTaskGroup(
                of: (Int, (object: PhysicalObject, hash: String)?).self
            ) { group in
                for (index, object) in objects.enumerated() {
                    group.addTask {
                        let hash: String?
                        do {
                            hash = try await context.hashTaskLimiter.withPermit {
                                hasher.sampledHash(
                                    path: object.metadata.path,
                                    logicalSize: object.metadata.logicalSize
                                )
                            }
                        } catch is CancellationError {
                            // 取消必须传播，不能吞成 nil 当成读取失败
                            throw CancellationError()
                        } catch {
                            hash = nil
                        }
                        guard let hash else { return (index, nil) }
                        return (index, (object, hash))
                    }
                }
                var collected: [(Int, (object: PhysicalObject, hash: String)?)] = []
                for try await pair in group {
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
            let confirmed: [(object: PhysicalObject, sampledHash: String, fullHash: String)?] = try await withThrowingTaskGroup(
                of: (Int, (object: PhysicalObject, sampledHash: String, fullHash: String)?).self
            ) { group in
                for (index, entry) in sampled.enumerated() {
                    group.addTask {
                        do {
                            let fullHash = try await context.hashTaskLimiter.withPermit {
                                try await cache.fullHash(for: entry.object.metadata)
                            }
                            return (index, (entry.object, entry.hash, fullHash))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // 单个文件读取失败跳过该对象，不影响整组
                            return (index, nil)
                        }
                    }
                }
                var collected: [(Int, (object: PhysicalObject, sampledHash: String, fullHash: String)?)] = []
                for try await pair in group {
                    collected.append(pair)
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            // 按 full hash 分组，≥2 个不同物理对象才形成重复组
            var byHash: [String: [(object: PhysicalObject, sampledHash: String)]] = [:]
            var hashOrder: [String] = []
            for case let entry? in confirmed {
                if byHash[entry.fullHash] == nil { hashOrder.append(entry.fullHash) }
                byHash[entry.fullHash, default: []].append((entry.object, entry.sampledHash))
            }

            for hash in hashOrder {
                guard let objects = byHash[hash], objects.count >= 2 else { continue }
                // 组内必须含 ≥2 个不同 inode（同 inode 硬链接不构成重复组）
                let distinctInodes = Set(objects.map {
                    "\($0.object.metadata.identity.device):\($0.object.metadata.identity.inode)"
                })
                guard distinctInodes.count >= 2 else { continue }
                groups.append(ConfirmedGroup(id: hash, objects: objects))
            }
        }

        try Task.checkCancellation()
        // 显式落盘点：本阶段累计的新 hash 一次性批量写盘
        await cache.flush()
        return groups
    }
}
