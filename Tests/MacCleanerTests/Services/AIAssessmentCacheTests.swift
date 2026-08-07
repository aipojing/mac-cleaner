import Foundation
import Testing
@testable import MacCleanerCore

@Suite("AI assessment cache")
struct AIAssessmentCacheTests {
    @Test("按指纹命中并原子覆盖")
    func storesAndOverwrites() async throws {
        let cache = AIAssessmentCache(fileURL: temporaryURL(), maxRecords: 3)
        try await cache.put(.fixture(fingerprint: "a", summary: "old"))
        try await cache.put(.fixture(fingerprint: "a", summary: "new"))
        #expect(try await cache.lookup(fingerprint: "a")?.summary == "new")
        #expect(try await cache.stats().recordCount == 1)
    }

    @Test("损坏文件隔离后返回空缓存")
    func quarantinesCorruptFile() async throws {
        let url = temporaryURL(contents: Data("not-json".utf8))
        let cache = AIAssessmentCache(fileURL: url, maxRecords: 100)
        #expect(try await cache.lookup(fingerprint: "a") == nil)
        #expect(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("超过容量淘汰最久未访问项")
    func evictsLeastRecentlyUsed() async throws {
        let cache = AIAssessmentCache(fileURL: temporaryURL(), maxRecords: 2)
        try await cache.put(.fixture(fingerprint: "a"))
        try await cache.put(.fixture(fingerprint: "b"))
        _ = try await cache.lookup(fingerprint: "a")
        try await cache.put(.fixture(fingerprint: "c"))
        #expect(try await cache.lookup(fingerprint: "b") == nil)
        #expect(try await cache.lookup(fingerprint: "a") != nil)
        #expect(try await cache.lookup(fingerprint: "c") != nil)
    }

    @Test("缓存跨实例持久化")
    func persistsAcrossInstances() async throws {
        let url = temporaryURL()
        let first = AIAssessmentCache(fileURL: url, maxRecords: 10)
        try await first.put(.fixture(fingerprint: "a", summary: "kept"))

        let second = AIAssessmentCache(fileURL: url, maxRecords: 10)
        #expect(try await second.lookup(fingerprint: "a")?.summary == "kept")
    }

    @Test("removeAll 清空记录并删除文件")
    func removeAllClears() async throws {
        let url = temporaryURL()
        let cache = AIAssessmentCache(fileURL: url, maxRecords: 10)
        try await cache.put(.fixture(fingerprint: "a"))
        try await cache.removeAll()
        #expect(try await cache.lookup(fingerprint: "a") == nil)
        #expect(try await cache.stats().recordCount == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("缓存文件不含敏感字段")
    func cacheFileContainsOnlyValidatedData() async throws {
        let url = temporaryURL()
        let cache = AIAssessmentCache(fileURL: url, maxRecords: 10)
        try await cache.put(.fixture(fingerprint: "a"))

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("\"schemaVersion\""))
        #expect(!raw.contains("Authorization"))
        #expect(!raw.contains("api-key"))
        #expect(!raw.contains("sk-"))
        #expect(!raw.contains("fileContent"))
        #expect(!raw.contains("environment"))
    }

    private func temporaryURL(contents: Data? = nil) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-ai-cache-\(UUID().uuidString).json")
        if let contents {
            try? contents.write(to: url)
        }
        return url
    }
}
