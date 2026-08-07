import Testing
import Foundation
@testable import MacCleanerCore

@Suite("Duplicate File Retention Strategy Tests")
struct DuplicateStrategyTests {

    private static func makeGroup() -> DuplicateGroup {
        let files = [
            DuplicateFile(
                path: "/Users/test/Documents/photo.jpg",
                size: 5_000_000,
                modifiedDate: Date(timeIntervalSinceNow: -86400 * 30) // 30 days ago
            ),
            DuplicateFile(
                path: "/Users/test/Downloads/backup/photo.jpg",
                size: 5_000_000,
                modifiedDate: Date(timeIntervalSinceNow: -86400 * 7) // 7 days ago
            ),
            DuplicateFile(
                path: "/Users/test/Desktop/a/b/c/photo.jpg",
                size: 5_000_000,
                modifiedDate: Date() // today
            ),
        ]
        return DuplicateGroup(id: "abc123", fileSize: 5_000_000, files: files)
    }

    @Test("keepNewest preserves the most recently modified file")
    func keepNewest() {
        let group = Self.makeGroup()
        let toRemove = group.keepNewest()

        #expect(toRemove.count == 2)
        // The newest file (Desktop) should be kept
        let removedPaths = Set(toRemove.map(\.path))
        #expect(!removedPaths.contains("/Users/test/Desktop/a/b/c/photo.jpg"))
        #expect(removedPaths.contains("/Users/test/Documents/photo.jpg"))
        #expect(removedPaths.contains("/Users/test/Downloads/backup/photo.jpg"))
    }

    @Test("keepShortestPath preserves the file with shortest path")
    func keepShortestPath() {
        let group = Self.makeGroup()
        let toRemove = group.keepShortestPath()

        #expect(toRemove.count == 2)
        // Documents/photo.jpg has shortest path
        let removedPaths = Set(toRemove.map(\.path))
        #expect(!removedPaths.contains("/Users/test/Documents/photo.jpg"))
    }

    @Test("keepInDirectory preserves file in specified directory")
    func keepInDirectory() {
        let group = Self.makeGroup()
        let toRemove = group.keepInDirectory("/Users/test/Downloads")

        #expect(toRemove.count == 2)
        let removedPaths = Set(toRemove.map(\.path))
        #expect(!removedPaths.contains("/Users/test/Downloads/backup/photo.jpg"))
    }

    @Test("keepInDirectory falls back to keepNewest when no match")
    func keepInDirectoryFallback() {
        let group = Self.makeGroup()
        let toRemove = group.keepInDirectory("/nonexistent/path")

        #expect(toRemove.count == 2)
        // Should fall back to keepNewest behavior
        let removedPaths = Set(toRemove.map(\.path))
        #expect(!removedPaths.contains("/Users/test/Desktop/a/b/c/photo.jpg"))
    }

    @Test("Single file group returns empty removal list")
    func singleFileGroup() {
        let file = DuplicateFile(path: "/a/b.txt", size: 100, modifiedDate: Date())
        let group = DuplicateGroup(id: "x", fileSize: 100, files: [file])

        #expect(group.keepNewest().isEmpty)
        #expect(group.keepShortestPath().isEmpty)
    }

    @Test("DuplicateFile provides directory property")
    func directoryProperty() {
        let file = DuplicateFile(path: "/Users/test/Documents/photo.jpg", size: 100, modifiedDate: Date())
        #expect(file.directory == "/Users/test/Documents")
    }

    @Test("DuplicateRetentionStrategy raw values are stable")
    func strategyRawValues() {
        #expect(DuplicateRetentionStrategy.keepNewest.rawValue == "keep_newest")
        #expect(DuplicateRetentionStrategy.keepShortestPath.rawValue == "keep_shortest_path")
        #expect(DuplicateRetentionStrategy.keepInDirectory.rawValue == "keep_in_directory")
    }
}

@Suite("DuplicateFilesModule Config Tests")
struct DuplicateFilesModuleConfigTests {

    @Test("Default skip directories include common dev folders")
    func defaultSkipDirs() {
        let defaults = DuplicateFilesModule.defaultSkipDirectories
        #expect(defaults.contains("node_modules"))
        #expect(defaults.contains(".git"))
        #expect(defaults.contains("Library"))
        #expect(defaults.contains(".cargo"))
        #expect(defaults.contains("DerivedData"))
        #expect(defaults.contains("__pycache__"))
    }

    @Test("Custom skip directories override defaults")
    func customSkipDirs() {
        let module = DuplicateFilesModule(
            skipDirectories: ["custom_skip"]
        )
        #expect(module.isAvailable())
    }
}

/// 记录三段抽样读取位置的测试 hasher。
actor RecordingFileHasher {
    private(set) var readOffsets: [Int64] = []

    func sampledHash(path: String, logicalSize: Int64, chunkSize: Int64) async -> String? {
        readOffsets = FileHasher.sampleOffsets(logicalSize: logicalSize, chunkSize: chunkSize)
        return "sampled"
    }
}

@Suite("Sampled hash strategy")
struct SampledHashTests {
    @Test("首中尾抽样读取三个区域")
    func sampledHashReadsThreeRegions() async throws {
        let hasher = RecordingFileHasher()
        _ = await hasher.sampledHash(path: "/tmp/a", logicalSize: 12_288, chunkSize: 4_096)
        #expect(await hasher.readOffsets == [0, 4_096, 8_192])
    }

    @Test("小文件只读取一次")
    func smallFileReadsOnce() {
        #expect(FileHasher.sampleOffsets(logicalSize: 4_096, chunkSize: 4_096) == [0])
        #expect(FileHasher.sampleOffsets(logicalSize: 100, chunkSize: 4_096) == [0])
        #expect(FileHasher.sampleOffsets(logicalSize: 0, chunkSize: 4_096).isEmpty)
    }

    @Test("只有中部不同的两个文件 sampled hash 不同")
    func middleDifferenceIsDetected() async throws {
        let dir = NSTemporaryDirectory() + "sampled-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        var bytesA = [UInt8](repeating: 0x41, count: 3 * 65_536)
        var bytesB = bytesA
        bytesB[65_536 + 100] = 0x42 // 只改中部
        try Data(bytesA).write(to: URL(fileURLWithPath: "\(dir)/a.bin"))
        try Data(bytesB).write(to: URL(fileURLWithPath: "\(dir)/b.bin"))

        let hasher = FileHasher()
        let hashA = hasher.sampledHash(path: "\(dir)/a.bin", logicalSize: Int64(bytesA.count))
        let hashB = hasher.sampledHash(path: "\(dir)/b.bin", logicalSize: Int64(bytesB.count))
        #expect(hashA != nil && hashB != nil)
        #expect(hashA != hashB)
    }
}

@Suite("Duplicate files three-phase scan")
struct DuplicateFilesScanTests {
    private func makeFixture(files: [(String, Int)]) throws -> String {
        let dir = NSTemporaryDirectory() + "dup-scan-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, size) in files {
            try Data(repeating: 0x55, count: size).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        }
        return dir
    }

    @Test("同 inode 硬链接不形成重复组")
    func hardlinksAloneDoNotFormGroup() async throws {
        let dir = try makeFixture(files: [("original.bin", 4_096)])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.linkItem(atPath: "\(dir)/original.bin", toPath: "\(dir)/hardlink.bin")

        let module = DuplicateFilesModule(scanRoot: dir, minSize: 1)
        let result = try await module.scan(context: ScanContext())
        #expect(result.items.isEmpty, "只有硬链接关系的对象不应产生重复组")
    }

    @Test("硬链接加真实拷贝形成一个包含全部路径的组")
    func hardlinkPlusCopyFormsOneGroup() async throws {
        let dir = try makeFixture(files: [("original.bin", 4_096), ("copy.bin", 4_096)])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.linkItem(atPath: "\(dir)/original.bin", toPath: "\(dir)/hardlink.bin")

        let module = DuplicateFilesModule(scanRoot: dir, minSize: 1)
        let result = try await module.scan(context: ScanContext())

        #expect(result.items.count == 3)
        let groupIDs = Set(result.items.compactMap(\.subcategory))
        #expect(groupIDs.count == 1)
        // 每个硬链接路径独立成为候选，不合并
        let paths = Set(result.items.map(\.path))
        #expect(paths.contains("\(dir)/original.bin"))
        #expect(paths.contains("\(dir)/hardlink.bin"))
        #expect(paths.contains("\(dir)/copy.bin"))
        // 硬链接候选记录了 linkCount，供物理空间估算
        let hardlinkItem = result.items.first { $0.path == "\(dir)/hardlink.bin" }
        #expect(hardlinkItem?.linkCount == 2)
    }

    @Test("缓存未变化时第二次扫描不重复 full hash")
    func secondScanUsesHashCache() async throws {
        let dir = try makeFixture(files: [("a.bin", 4_096), ("b.bin", 4_096)])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory() + "dup-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let hasher = CountingFileHasher(fullHash: "same-full-hash")
        let cache = FileHashCache(fileURL: cacheURL, hasher: hasher)
        let module = DuplicateFilesModule(scanRoot: dir, minSize: 1, hashCache: cache)

        _ = try await module.scan(context: ScanContext())
        let callsAfterFirst = await hasher.fullHashCalls
        #expect(callsAfterFirst == 2)

        _ = try await module.scan(context: ScanContext())
        #expect(await hasher.fullHashCalls == callsAfterFirst, "缓存命中不应重复 full hash")
    }

    @Test("不同内容的同大小文件不形成重复组")
    func differentContentNoGroup() async throws {
        let dir = NSTemporaryDirectory() + "dup-diff-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        try Data(repeating: 0x11, count: 4_096).write(to: URL(fileURLWithPath: "\(dir)/a.bin"))
        try Data(repeating: 0x22, count: 4_096).write(to: URL(fileURLWithPath: "\(dir)/b.bin"))

        let module = DuplicateFilesModule(scanRoot: dir, minSize: 1)
        let result = try await module.scan(context: ScanContext())
        #expect(result.items.isEmpty)
    }
}

@Suite("Physical space accounting")
struct PhysicalSpaceAccountingTests {
    @Test("重复组的浪费空间按物理对象去重，硬链接不重复计")
    func wastedSpaceDeduplicatesHardLinks() {
        let shared = FileIdentity(device: 1, inode: 100, kind: .regularFile)
        let other = FileIdentity(device: 1, inode: 200, kind: .regularFile)
        let files = [
            // 同一 inode 的两条硬链接路径：共享一个物理对象
            DuplicateFile(path: "/a/x.bin", size: 1000, modifiedDate: Date(), fileIdentity: shared),
            DuplicateFile(path: "/b/x.bin", size: 1000, modifiedDate: Date(), fileIdentity: shared),
            DuplicateFile(path: "/c/x.bin", size: 1000, modifiedDate: Date(), fileIdentity: other),
        ]
        let group = DuplicateGroup(id: "h", fileSize: 1000, files: files)

        // 2 个物理对象，保留 1 个 → 只浪费 1 份，而不是 (3-1) 份
        #expect(group.totalWastedSpace == 1000)
    }

    @Test("ScanResult.totalSize 按 device/inode 去重")
    func scanResultTotalDeduplicatesInodes() {
        let shared = FileIdentity(device: 1, inode: 100, kind: .regularFile)
        let result = ScanResult(
            module: .duplicateFiles,
            items: [
                CleanableItem(path: "/a/x", displayName: "x", size: 500, category: .duplicateFiles,
                              fileIdentity: shared, allocatedSize: 4096),
                CleanableItem(path: "/b/x", displayName: "x", size: 500, category: .duplicateFiles,
                              fileIdentity: shared, allocatedSize: 4096),
                CleanableItem(path: "/c/y", displayName: "y", size: 100, category: .duplicateFiles,
                              fileIdentity: FileIdentity(device: 1, inode: 101, kind: .regularFile),
                              allocatedSize: 4096),
            ],
            scanDuration: 0
        )
        #expect(result.totalSize == 8192, "同一 inode 只计一次 allocatedSize")
    }
}
