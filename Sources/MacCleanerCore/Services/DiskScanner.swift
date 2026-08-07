import Foundation

public struct DiskScanner: Sendable {
    /// 兼容现有测试入口；实际探针归统一的 FTSTraversalGate 所有。
    static var ftsConcurrencyTracker: FTSConcurrencyTracker {
        FTSTraversalGate.tracker
    }

    public init() {}

    public func directorySize(at path: String) -> Int64 {
        directorySizeFTS(at: path)
    }

    public func directorySize(at url: URL) -> Int64 {
        directorySizeFTS(at: url.path)
    }

    /// 使用 POSIX fts 快速计算目录实际占用（st_blocks * 512，比 FileManager.enumerator 快 5-10 倍）。
    /// 同一 device/inode 的硬链接只计一次；符号链接只统计链接对象自身，不跟随目标。
    /// 目录大小遍历在此进入进程级 FTS gate。
    private func directorySizeFTS(at path: String) -> Int64 {
        FTSTraversalGate.withPermit {
            let cPath = path.withCString { strdup($0) }
            guard let cPath else { return 0 }
            defer { free(cPath) }

            var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
                return 0
            }
            defer { fts_close(fts) }

            let progress = ScanProgress.shared
            var totalSize: Int64 = 0
            var seenObjects: Set<String> = []
            while let entry = fts_read(fts) {
                let info = entry.pointee.fts_info
                guard info == FTS_F || info == FTS_SL || info == FTS_SLNONE else { continue }
                let st = entry.pointee.fts_statp.pointee
                let objectKey = "\(st.st_dev):\(st.st_ino)"
                guard seenObjects.insert(objectKey).inserted else { continue }
                totalSize += max(0, Int64(st.st_blocks)) * 512
                progress.report(path: String(cString: entry.pointee.fts_path))
            }
            return totalSize
        }
    }

    /// 并发计算多个目录的大小
    public func directorySizes(at paths: [String]) async -> [String: Int64] {
        await withTaskGroup(of: (String, Int64).self) { group in
            for path in paths {
                group.addTask {
                    (path, self.directorySizeFTS(at: path))
                }
            }
            var results: [String: Int64] = [:]
            for await (path, size) in group {
                results[path] = size
            }
            return results
        }
    }

    /// 同步并发计算多个目录大小（使用 GCD，适合在非 async 上下文中使用）。
    /// fts 并发许可在 directorySizeFTS 统一获取，此处不再单独限流。
    public func directorySizesBatch(paths: [String]) -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }
        // 各线程写不同 index，但 Swift 内存安全模型下并发写数组仍需同步。
        // 用 NSLock 保护写入，避免 UnsafeMutableBufferPointer 的 UB 风险。
        let lock = NSLock()
        var sizes = [Int64](repeating: 0, count: paths.count)

        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let size = directorySizeFTS(at: paths[index])
            lock.lock()
            sizes[index] = size
            lock.unlock()
        }

        var results: [String: Int64] = [:]
        results.reserveCapacity(paths.count)
        for i in 0..<paths.count {
            results[paths[i]] = sizes[i]
        }
        return results
    }

    public func directoryExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func subdirectories(at path: String) -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
            return []
        }
        return contents.compactMap { name in
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return fullPath
        }.sorted()
    }

    public func largeFiles(under path: String, minSize: Int64 = 100 * 1024 * 1024, limit: Int = 50) -> [(path: String, size: Int64)] {
        FTSTraversalGate.withPermit {
            let cPath = path.withCString { strdup($0) }
            guard let cPath else { return [] }
            defer { free(cPath) }

            let skipDirs: Set<String> = ["Library", ".Trash", ".gradle", ".m2", ".npm", ".cocoapods", ".pub-cache"]

            var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
                return []
            }
            defer { fts_close(fts) }

            var results: [(path: String, size: Int64)] = []

            while let entry = fts_read(fts) {
                let filePath = String(cString: entry.pointee.fts_path)
                let name = (filePath as NSString).lastPathComponent

                // 跳过指定目录
                if entry.pointee.fts_info == FTS_D && skipDirs.contains(name) {
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }

                if entry.pointee.fts_info == FTS_F {
                    let fileSize = Int64(entry.pointee.fts_statp.pointee.st_size)
                    if fileSize >= minSize {
                        results.append((path: filePath, size: fileSize))
                    }
                }
            }

            return results
                .sorted { $0.size > $1.size }
                .prefix(limit)
                .map { $0 }
        }
    }

    public static let homeDirectory: String = {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }()
}
