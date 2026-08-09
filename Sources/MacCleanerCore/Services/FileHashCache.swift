import Foundation

/// 持久化 full hash 缓存：同一物理对象（device + inode）在 size、mtime
/// 都不变时不重复计算 SHA-256。
///
/// 缓存键包含 schema version、device、inode、logical size 和 mtime 纳秒：
/// 任何一个变化都会得到不同的键，自然失效。符号链接、目录和无法获得
/// 稳定身份的对象不进入缓存（每次直接计算）。最多 50,000 条，LRU 淘汰；
/// 原子写入避免中途崩溃留下半个文件。
///
/// 落盘策略：不再每次 miss 后全量写入（O(n²) IO）——每累计
/// `persistInterval` 个新条目批量落盘一次，或由调用方在扫描阶段结束等
/// 显式 flush 点调用 `flush()`。LRU 用双向链表维护，命中路径的 touch
/// 与淘汰都是 O(1)。
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
    /// 默认每 64 个新条目批量落盘一次。
    public static let defaultPersistInterval = 64

    private let fileURL: URL
    private let hasher: any FileHashComputing
    private let capacity: Int
    private let persistInterval: Int
    private var entries: [String: Entry]
    /// 自上次落盘以来的新条目数。
    private var unsavedInserts = 0

    // LRU 双向链表：head 最旧、tail 最新；nodes 提供 O(1) 定位。
    private final class Node {
        let key: String
        var prev: Node?
        var next: Node?
        init(key: String) { self.key = key }
    }
    private var nodes: [String: Node] = [:]
    private var head: Node?
    private var tail: Node?

    public init(
        fileURL: URL = FileHashCache.defaultFileURL(),
        hasher: any FileHashComputing = FileHasher(),
        capacity: Int = FileHashCache.defaultCapacity,
        persistInterval: Int = FileHashCache.defaultPersistInterval
    ) {
        self.fileURL = fileURL
        self.hasher = hasher
        self.capacity = max(1, capacity)
        self.persistInterval = max(1, persistInterval)
        let store = Self.load(from: fileURL)
        self.entries = store.entries
        // init 是非隔离上下文，不能直接调用隔离的 appendToTail，内联建链
        for key in store.accessOrder {
            let node = Node(key: key)
            node.prev = tail
            tail?.next = node
            tail = node
            if head == nil { head = node }
            nodes[key] = node
        }
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
        unsavedInserts += 1
        if unsavedInserts >= persistInterval {
            flush()
        }
        return hash
    }

    /// 显式落盘点：扫描阶段结束等时机调用，把累计的新条目写盘。
    public func flush() {
        guard unsavedInserts > 0 else { return }
        unsavedInserts = 0
        persist()
    }

    /// 当前缓存条数（测试与诊断用）。
    public var count: Int { entries.count }

    // MARK: - LRU（O(1) touch / evict）

    private func touch(_ key: String) {
        if let node = nodes[key] {
            detach(node)
            appendToTail(node)
        } else {
            appendToTail(Node(key: key))
        }
    }

    private func detach(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func appendToTail(_ node: Node) {
        node.prev = tail
        node.next = nil
        tail?.next = node
        tail = node
        if head == nil { head = node }
        nodes[node.key] = node
    }

    private func evictIfNeeded() {
        while entries.count > capacity, let oldest = head {
            detach(oldest)
            nodes[oldest.key] = nil
            entries[oldest.key] = nil
        }
    }

    // MARK: - 持久化

    private func accessOrder() -> [String] {
        var order: [String] = []
        order.reserveCapacity(entries.count)
        var node = head
        while let current = node {
            order.append(current.key)
            node = current.next
        }
        return order
    }

    private func persist() {
        let store = Store(entries: entries, accessOrder: accessOrder())
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
