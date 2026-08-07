import Foundation
import Testing
@testable import MacCleanerCore

@Suite("File metadata index")
struct FileMetadataIndexTests {
    @Test("单次扫描同一路径只调用 provider 一次")
    func metadataIndexCoalescesRequests() async throws {
        let provider = CountingMetadataProvider(result: .fixture(path: "/tmp/a"))
        let index = FileMetadataIndex(provider: provider)

        async let first = index.metadata(at: "/tmp/a")
        async let second = index.metadata(at: "/tmp/a")
        async let third = index.metadata(at: "/tmp/./a")
        _ = try await (first, second, third)

        #expect(await provider.callCount(for: "/tmp/a") == 1)
    }

    @Test("不同路径分别调用并缓存")
    func cachesPerPath() async throws {
        let provider = CountingMetadataProvider(result: .fixture())
        let index = FileMetadataIndex(provider: provider)

        _ = try await index.metadata(at: "/tmp/a")
        _ = try await index.metadata(at: "/tmp/b")
        _ = try await index.metadata(at: "/tmp/a")

        #expect(await provider.callCount(for: "/tmp/a") == 1)
        #expect(await provider.callCount(for: "/tmp/b") == 1)
        let cached = await index.cachedMetadata(at: "/tmp/a")
        #expect(cached != nil)
    }

    @Test("确定性错误被缓存，不重复调用 provider")
    func cachesDeterministicErrors() async throws {
        let provider = CountingMetadataProvider(
            result: nil,
            error: MetadataError.notFound(path: "/tmp/missing")
        )
        let index = FileMetadataIndex(provider: provider)

        await #expect(throws: MetadataError.self) {
            _ = try await index.metadata(at: "/tmp/missing")
        }
        await #expect(throws: MetadataError.self) {
            _ = try await index.metadata(at: "/tmp/missing")
        }
        #expect(await provider.callCount(for: "/tmp/missing") == 1)
        let cached = await index.cachedMetadata(at: "/tmp/missing")
        #expect(cached == nil)
    }
}

extension FileMetadata {
    static func fixture(
        path: String = "/tmp/fixture",
        device: UInt64 = 1,
        inode: UInt64 = 2,
        kind: FileObjectKind = .regularFile,
        logicalSize: Int64 = 100,
        allocatedSize: Int64 = 4096,
        linkCount: UInt64 = 1,
        mtime: Int64 = 10
    ) -> FileMetadata {
        FileMetadata(
            path: path,
            identity: FileIdentity(device: device, inode: inode, kind: kind),
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            linkCount: linkCount,
            modificationTimeNanoseconds: mtime
        )
    }
}

/// 记录每个路径调用次数的测试 provider。
actor CountingMetadataProvider: FileMetadataProviding {
    private let result: FileMetadata?
    private let error: MetadataError?
    private var counts: [String: Int] = [:]

    init(result: FileMetadata?, error: MetadataError? = nil) {
        self.result = result
        self.error = error
    }

    nonisolated func metadata(at path: String) async throws -> FileMetadata {
        await record(path: path)
        if let error { throw error }
        if let result { return result }
        throw MetadataError.notFound(path: path)
    }

    func callCount(for path: String) -> Int {
        counts[path] ?? 0
    }

    private func record(path: String) {
        counts[path, default: 0] += 1
    }
}

@Suite("Scan context identity recording")
struct ScanContextIdentityTests {
    @Test("recordIdentities 经共享索引去重：同一路径一次扫描只 lstat 一次")
    func recordIdentitiesDeduplicates() async {
        let provider = CountingMetadataProvider(result: .fixture(path: "/tmp/shared"))
        let context = ScanContext(metadataIndex: FileMetadataIndex(provider: provider))
        let items = [
            CleanableItem(path: "/tmp/shared", displayName: "a", size: 1, category: .developerCaches),
            CleanableItem(path: "/tmp/shared", displayName: "b", size: 1, category: .applicationCaches),
        ]

        let identified = await context.recordIdentities(of: items)

        #expect(identified.allSatisfy { $0.fileIdentity != nil })
        #expect(await provider.callCount(for: "/tmp/shared") == 1)
    }

    @Test("已有身份的条目不触发元数据读取")
    func existingIdentitySkipsRead() async {
        let provider = CountingMetadataProvider(result: .fixture())
        let context = ScanContext(metadataIndex: FileMetadataIndex(provider: provider))
        let item = CleanableItem(
            path: "/tmp/x", displayName: "x", size: 1,
            category: .developerCaches,
            fileIdentity: FileIdentity(device: 1, inode: 1, kind: .regularFile)
        )

        let identified = await context.recordIdentities(of: [item])

        #expect(identified.first?.fileIdentity != nil)
        #expect(await provider.callCount(for: "/tmp/x") == 0)
    }
}

@Suite("Disk scanner bounded batch")
struct DiskScannerBatchTests {
    @Test("批量结果在全局并发限制下仍然正确")
    func boundedBatchStaysCorrect() throws {
        let root = NSTemporaryDirectory().appending("diskscan-batch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        var paths: [String] = []
        for i in 0..<12 {
            let dir = (root as NSString).appendingPathComponent("d\(i)")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(count: 1024).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("f.bin")))
            paths.append(dir)
        }

        let sizes = DiskScanner().directorySizesBatch(paths: paths)

        #expect(sizes.count == 12)
        #expect(sizes.values.allSatisfy { $0 > 0 })
    }
}

@Suite("FTS traversal global limit")
struct FTSGlobalLimitTests {
    /// 构造若干含大量文件的临时目录，让 fts 遍历足够慢以产生并发重叠
    private func makeFixtureDirs(count: Int, filesPerDir: Int) throws -> (root: String, dirs: [String]) {
        let root = NSTemporaryDirectory().appending("fts-limit-\(UUID().uuidString)")
        var dirs: [String] = []
        for i in 0..<count {
            let dir = (root as NSString).appendingPathComponent("d\(i)")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for j in 0..<filesPerDir {
                FileManager.default.createFile(
                    atPath: (dir as NSString).appendingPathComponent("f\(j)"),
                    contents: Data(count: 64)
                )
            }
            dirs.append(dir)
        }
        return (root, dirs)
    }

    @Test("单目录、async 批量、GCD 批量混合调用时 fts 并发不超上限")
    func mixedCallsStayWithinGlobalLimit() async throws {
        let (root, dirs) = try makeFixtureDirs(count: 24, filesPerDir: 400)
        defer { try? FileManager.default.removeItem(atPath: root) }

        DiskScanner.ftsConcurrencyTracker.reset()
        let scanner = DiskScanner()

        await withTaskGroup(of: Void.self) { group in
            // GCD 批量（两个并发批次）
            group.addTask { _ = scanner.directorySizesBatch(paths: Array(dirs.prefix(12))) }
            group.addTask { _ = scanner.directorySizesBatch(paths: Array(dirs.suffix(12))) }
            // async 批量
            group.addTask { _ = await scanner.directorySizes(at: dirs) }
            // 单目录入口
            for dir in dirs {
                group.addTask { _ = scanner.directorySize(at: dir) }
            }
        }

        let peak = DiskScanner.ftsConcurrencyTracker.peak
        #expect(peak > 0)
        #expect(
            peak <= ScanContext.defaultFileTaskLimit,
            "fts 并发峰值 \(peak) 超过全局限流 \(ScanContext.defaultFileTaskLimit)"
        )
    }

    @Test("目录大小与原始模块遍历都经过同一个全局许可")
    func rawTraversalCallSitesShareGlobalPermit() async throws {
        let (root, dirs) = try makeFixtureDirs(count: 6, filesPerDir: 40)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let tracker = FTSTraversalGate.tracker
        let entriesBefore = tracker.snapshot().totalEntries
        let scanner = DiskScanner()
        let context = ScanContext()

        async let directorySizes = scanner.directorySizes(at: dirs)
        async let directLargeFiles = scanner.largeFiles(under: root, minSize: 1, limit: 20)
        async let largeFileResult = LargeFileScannerModule(
            scanRoot: root,
            minAllocatedSize: 1,
            limit: 20
        ).scan(context: context)
        async let duplicateResult = DuplicateFilesModule(
            scanRoot: root,
            minSize: 1,
            skipDirectories: []
        ).scan(context: context)

        _ = try await (directorySizes, directLargeFiles, largeFileResult, duplicateResult)

        let snapshot = tracker.snapshot()
        #expect(
            snapshot.totalEntries - entriesBefore >= dirs.count + 3,
            "所有直接 fts_open 调用都必须进入统一 gate"
        )
        #expect(snapshot.peak <= ScanContext.defaultFileTaskLimit)
    }
}

extension PhysicalSpaceAccountingTests {
    @Test("同一 inode 分布在两个 ScanResult 时集合级总量只计一次")
    func crossModuleCollectionDeduplicates() {
        // 见 PhysicalSpaceAccountingTests：集合级总量必须 flatMap 后统一去重，
        // 不能逐模块相加 totalSize。
        let shared = FileIdentity(device: 1, inode: 100, kind: .regularFile)
        let resultA = ScanResult(
            module: .duplicateFiles,
            items: [CleanableItem(path: "/a/x", displayName: "x", size: 500,
                                  category: .duplicateFiles, fileIdentity: shared,
                                  allocatedSize: 4096)],
            scanDuration: 0
        )
        let resultB = ScanResult(
            module: .applicationCaches,
            items: [CleanableItem(path: "/b/x", displayName: "x", size: 500,
                                  category: .applicationCaches, fileIdentity: shared,
                                  allocatedSize: 4096)],
            scanDuration: 0
        )
        let results = [resultA, resultB]

        let perModuleSum = results.reduce(Int64(0)) { $0 + $1.totalSize }
        let collectionTotal = PhysicalSizeCalculator.uniqueAllocatedBytes(
            in: results.flatMap(\.items)
        )

        #expect(perModuleSum == 8192, "逐模块相加会重复计数（本测试固定这一差异）")
        #expect(collectionTotal == 4096, "集合级总量必须只计一次")
    }
}
