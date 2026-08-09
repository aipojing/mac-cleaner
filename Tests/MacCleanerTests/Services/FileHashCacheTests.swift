import Testing
import Foundation
@testable import MacCleanerCore

extension FileMetadata {
    /// 测试构造：fromStat 语义，默认常规文件。
    static func fixture(
        path: String = "/tmp/hash-me",
        device: UInt64 = 1,
        inode: UInt64 = 2,
        logicalSize: Int64 = 100,
        mtime: Int64 = 10,
        mode: mode_t = S_IFREG | 0o644,
        linkCount: UInt64 = 1
    ) -> FileMetadata {
        FileMetadata.fromStat(
            path: path,
            device: device,
            inode: inode,
            mode: mode,
            logicalSize: logicalSize,
            blocks: 8,
            linkCount: linkCount,
            modificationTimeNanoseconds: mtime
        )
    }
}

/// 记录 full hash 调用次数的测试 hasher。
actor CountingFileHasher: FileHashComputing {
    let fullHash: String
    private(set) var fullHashCalls = 0

    init(fullHash: String) {
        self.fullHash = fullHash
    }

    func computeFullHash(at path: String) async throws -> String {
        fullHashCalls += 1
        return fullHash
    }
}

private func temporaryCacheURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory() + "hash-cache-\(UUID().uuidString).json")
}

@Suite("File hash cache")
struct FileHashCacheTests {
    @Test("相同实例第二次读取不重复 full hash")
    func reusesFullHash() async throws {
        let hasher = CountingFileHasher(fullHash: "full")
        let cache = FileHashCache(fileURL: temporaryCacheURL(), hasher: hasher)
        let metadata = FileMetadata.fixture(device: 1, inode: 2, logicalSize: 100, mtime: 10)
        _ = try await cache.fullHash(for: metadata)
        _ = try await cache.fullHash(for: metadata)
        #expect(await hasher.fullHashCalls == 1)
    }

    @Test("大小或 mtime 变化后重新 hash")
    func invalidatesChangedFile() async throws {
        let hasher = CountingFileHasher(fullHash: "full")
        let cache = FileHashCache(fileURL: temporaryCacheURL(), hasher: hasher)
        _ = try await cache.fullHash(for: .fixture(logicalSize: 100, mtime: 10))
        _ = try await cache.fullHash(for: .fixture(logicalSize: 101, mtime: 10))
        _ = try await cache.fullHash(for: .fixture(logicalSize: 100, mtime: 11))
        #expect(await hasher.fullHashCalls == 3)
    }

    @Test("新实例从磁盘恢复缓存，不重复计算")
    func persistsAcrossInstances() async throws {
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let hasher = CountingFileHasher(fullHash: "full")
        let first = FileHashCache(fileURL: url, hasher: hasher)
        let metadata = FileMetadata.fixture(device: 7, inode: 8, logicalSize: 64, mtime: 42)
        _ = try await first.fullHash(for: metadata)
        // 批量落盘策略：单条插入不立即写盘，需显式 flush
        await first.flush()

        let second = FileHashCache(fileURL: url, hasher: hasher)
        let hash = try await second.fullHash(for: metadata)
        #expect(hash == "full")
        #expect(await hasher.fullHashCalls == 1)
    }

    @Test("累计达到批量间隔的新条目自动落盘")
    func batchesPersistsAfterInterval() async throws {
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let hasher = CountingFileHasher(fullHash: "full")
        let first = FileHashCache(fileURL: url, hasher: hasher, persistInterval: 3)
        for i in 0..<3 {
            _ = try await first.fullHash(
                for: .fixture(device: 1, inode: UInt64(100 + i), logicalSize: 64, mtime: 1)
            )
        }

        let second = FileHashCache(fileURL: url, hasher: hasher)
        #expect(await second.count == 3)
    }

    @Test("符号链接和目录不进入缓存")
    func skipsNonRegularFiles() async throws {
        let hasher = CountingFileHasher(fullHash: "full")
        let cache = FileHashCache(fileURL: temporaryCacheURL(), hasher: hasher)
        let symlink = FileMetadata.fixture(mode: S_IFLNK | 0o755)
        _ = try await cache.fullHash(for: symlink)
        _ = try await cache.fullHash(for: symlink)
        #expect(await hasher.fullHashCalls == 2)
    }
}
