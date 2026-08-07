import Foundation

/// 持久化 full hash 缓存：同一物理对象（device + inode）在 size、mtime
/// 都不变时不重复计算 SHA-256。
///
/// 缓存键包含 schema version、device、inode、logical size 和 mtime 纳秒：
/// 任何一个变化都会得到不同的键，自然失效。符号链接、目录和无法获得
/// 稳定身份的对象不进入缓存（每次直接计算）。最多 50,000 条，LRU 淘汰；
/// 原子写入避免中途崩溃留下半个文件。
public actor FileHashCache {
    public struct Entry: Codable, Sendable {
        public let sha256: String
        public let computedAt: Date

        public init(sha256: String, computedAt: Date) {
            self.sha256 = sha256
            self.computedAt = computedAt
        }
    }

    private struct Store: Codable {
        var entries: [String: Entry]
        /// 访问顺序，最旧的在前面（LRU 淘汰从头删除）。
        var accessOrder: [String]
    }

    public static let schemaVersion = 1
    public static let defaultCapacity = 50_000

    private let fileURL: URL
    private let hasher: any FileHashComputing
    private let capacity: Int
    private var entries: [String: Entry]
    private var accessOrder: [String]

    public init(
        fileURL: URL = FileHashCache.defaultFileURL(),
        hasher: any FileHashComputing = FileHasher(),
        capacity: Int = FileHashCache.defaultCapacity
    ) {
        self.fileURL = fileURL
        self.hasher = hasher
        self.capacity = max(1, capacity)
        let store = Self.load(from: fileURL)
        self.entries = store.entries
        self.accessOrder = store.accessOrder
    }

    public static func defaultFileURL() -> URL {
        let home = DiskScanner.homeDirectory
        return URL(fileURLWithPath:
            "\(home)/Library/Application Support/DevClean/Scan/file-hashes-v1.json")
    }

    /// 缓存键：schema version + device + inode + logical size + mtime ns。
    static func key(for metadata: FileMetadata) -> String {
        "v\(schemaVersion):\(metadata.identity.device):\(metadata.identity.inode)"
            + ":\(metadata.logicalSize):\(metadata.modificationTimeNanoseconds)"
    }

    /// 返回 metadata 对应物理对象的 full SHA-256。缓存命中不触发任何 IO。
    /// 只有常规文件进入缓存；其他类型每次直接计算。
    public func fullHash(for metadata: FileMetadata) async throws -> String {
        guard metadata.kind == .regularFile else {
            return try await hasher.computeFullHash(at: metadata.path)
        }

        let key = Self.key(for: metadata)
        if let entry = entries[key] {
            touch(key)
            return entry.sha256
        }

        let hash = try await hasher.computeFullHash(at: metadata.path)
        entries[key] = Entry(sha256: hash, computedAt: Date())
        touch(key)
        evictIfNeeded()
        persist()
        return hash
    }

    /// 当前缓存条数（测试与诊断用）。
    public var count: Int { entries.count }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictIfNeeded() {
        while entries.count > capacity, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            entries[oldest] = nil
        }
    }

    private func persist() {
        let store = Store(entries: entries, accessOrder: accessOrder)
        guard let data = try? JSONEncoder().encode(store) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> Store {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(Store.self, from: data)
        else {
            return Store(entries: [:], accessOrder: [])
        }
        // 清理 accessOrder 中已不存在于 entries 的残留键
        let cleanedOrder = store.accessOrder.filter { store.entries[$0] != nil }
        return Store(entries: store.entries, accessOrder: cleanedOrder)
    }
}
