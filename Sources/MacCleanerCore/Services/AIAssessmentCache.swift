import Foundation

/// 本地 AI 结论缓存。actor 管理的 JSON 文件，原子写入，
/// 损坏时隔离原文件并从空文档恢复，超出容量按最久未访问淘汰。
/// 只保存校验通过的 AI 结论、指纹和时间戳，不保存 API Key、
/// 请求头、原始文件内容或完整命令行。
public actor AIAssessmentCache {
    public struct Stats: Equatable, Sendable {
        public let recordCount: Int
        public let byteCount: UInt64

        public init(recordCount: Int, byteCount: UInt64) {
            self.recordCount = recordCount
            self.byteCount = byteCount
        }
    }

    public static let schemaVersion = 1

    /// 默认缓存路径：`~/Library/Application Support/DevClean/AI/assessments-v1.json`。
    public static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevClean/AI/assessments-v1.json", isDirectory: false)
    }

    private let fileURL: URL
    private let maxRecords: Int
    private let now: @Sendable () -> Date
    private var document: CacheDocument
    private var loaded = false

    public init(
        fileURL: URL = AIAssessmentCache.defaultFileURL,
        maxRecords: Int = 5_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.maxRecords = maxRecords
        self.now = now
        self.document = CacheDocument(schemaVersion: Self.schemaVersion, records: [:])
    }

    /// 按指纹查找。命中会刷新访问时间（用于 LRU 淘汰）。
    public func lookup(fingerprint: String) throws -> AIAssessment? {
        try loadIfNeeded()
        guard var record = document.records[fingerprint] else { return nil }
        record.lastAccessedAt = now()
        document.records[fingerprint] = record
        return record.assessment
    }

    /// 写入一条已校验的结论。同指纹覆盖，超出容量淘汰最久未访问项。
    public func put(_ assessment: AIAssessment) throws {
        try loadIfNeeded()
        document.records[assessment.fingerprint] = CacheRecord(
            assessment: assessment,
            lastAccessedAt: now()
        )
        evictIfNeeded()
        try persist()
    }

    public func removeAll() throws {
        document = CacheDocument(schemaVersion: Self.schemaVersion, records: [:])
        loaded = true
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public func stats() throws -> Stats {
        try loadIfNeeded()
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size])
            .flatMap { ($0 as? NSNumber)?.uint64Value } ?? 0
        return Stats(recordCount: document.records.count, byteCount: byteCount)
    }

    // MARK: - 私有

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(CacheDocument.self, from: data)
            guard decoded.schemaVersion == Self.schemaVersion else { return }
            document = decoded
        } catch {
            // 首次解码失败：把原文件原子移动为固定的 .corrupt 路径后从空文档继续。
            let quarantine = URL(fileURLWithPath: fileURL.path + ".corrupt")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            document = CacheDocument(schemaVersion: Self.schemaVersion, records: [:])
        }
    }

    private func evictIfNeeded() {
        while document.records.count > maxRecords {
            guard let oldest = document.records.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt }) else {
                break
            }
            document.records.removeValue(forKey: oldest.key)
        }
    }

    /// 同目录临时文件写入后原子替换正式文件。
    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)

        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }
}

private struct CacheDocument: Codable {
    var schemaVersion: Int
    var records: [String: CacheRecord]
}

private struct CacheRecord: Codable {
    var assessment: AIAssessment
    var lastAccessedAt: Date
}
