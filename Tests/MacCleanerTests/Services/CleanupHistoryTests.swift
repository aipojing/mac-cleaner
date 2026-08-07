import Testing
import Foundation
@testable import MacCleanerCore

@Suite("CleanupHistory Tests")
struct CleanupHistoryTests {

    @Test("CleanupRecord stores module summaries")
    func recordStoresModules() {
        let record = CleanupRecord(
            modules: [
                ModuleCleanupSummary(
                    moduleID: "dev-caches", moduleName: "开发者缓存",
                    freed: 1_000_000, itemCount: 5, failedCount: 0
                ),
                ModuleCleanupSummary(
                    moduleID: "xcode", moduleName: "Xcode",
                    freed: 2_000_000, itemCount: 3, failedCount: 1
                ),
            ],
            totalExpected: 3_500_000,
            totalFreed: 3_000_000,
            totalItems: 8,
            totalFailed: 1
        )

        #expect(record.modules.count == 2)
        #expect(record.totalFreed == 3_000_000)
        #expect(record.totalFailed == 1)
        #expect(!record.dryRun)
    }

    @Test("CleanupRecord is Codable")
    func recordCodable() throws {
        let record = CleanupRecord(
            modules: [
                ModuleCleanupSummary(
                    moduleID: "dev-caches", moduleName: "开发者缓存",
                    freed: 500, itemCount: 1, failedCount: 0
                ),
            ],
            totalExpected: 500,
            totalFreed: 500,
            totalItems: 1,
            totalFailed: 0
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CleanupRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.totalFreed == 500)
        #expect(decoded.modules.count == 1)
    }

    @Test("CleanupHistoryStore records and retrieves")
    func storeRecordAndRetrieve() async {
        let tempPath = NSTemporaryDirectory() + "history-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let store = CleanupHistoryStore(storePath: tempPath)

        let report = CleanupReport(
            module: .developerCaches,
            deletedItems: [CleanedItem(path: "/a", expectedSize: 1000, actualFreed: 1000, verified: true)],
            expectedSize: 1000,
            actualFreed: 1000
        )

        await store.record(reports: [report])

        let count = await store.recordCount
        #expect(count == 1)

        let freed = await store.cumulativeFreed
        #expect(freed == 1000)
    }

    @Test("CleanupHistoryStore excludes dry runs from cumulative")
    func excludesDryRuns() async {
        let tempPath = NSTemporaryDirectory() + "history-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let store = CleanupHistoryStore(storePath: tempPath)

        let report = CleanupReport(
            module: .developerCaches,
            deletedItems: [CleanedItem(path: "/a", size: 5000)],
            dryRun: true,
            expectedSize: 5000,
            actualFreed: 5000
        )

        await store.record(reports: [report], dryRun: true)

        let freed = await store.cumulativeFreed
        #expect(freed == 0) // Dry runs don't count
    }

    @Test("CleanupHistoryStore stats aggregation")
    func statsAggregation() async {
        let tempPath = NSTemporaryDirectory() + "history-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let store = CleanupHistoryStore(storePath: tempPath)

        // Add multiple records
        for _ in 0..<3 {
            let report = CleanupReport(
                module: .xcode,
                deletedItems: [CleanedItem(path: "/a", expectedSize: 1000, actualFreed: 1000, verified: true)],
                expectedSize: 1000,
                actualFreed: 1000
            )
            await store.record(reports: [report])
        }

        let stats = await store.stats(days: 30)
        #expect(stats.totalRecords == 3)
        #expect(stats.cumulativeFreed == 3000)
        #expect(stats.topModulesByFreed.first?.moduleID == "xcode")
        #expect(stats.lastCleanupDate != nil)
    }

    @Test("CleanupHistoryStore persists to disk")
    func persistsToDisk() async {
        let tempPath = NSTemporaryDirectory() + "history-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        // Write
        let store1 = CleanupHistoryStore(storePath: tempPath)
        let report = CleanupReport(
            module: .applicationCaches,
            deletedItems: [CleanedItem(path: "/b", expectedSize: 2000, actualFreed: 2000, verified: true)],
            expectedSize: 2000,
            actualFreed: 2000
        )
        await store1.record(reports: [report])

        // Read from new instance
        let store2 = CleanupHistoryStore(storePath: tempPath)
        let count = await store2.recordCount
        #expect(count == 1)
        let freed = await store2.cumulativeFreed
        #expect(freed == 2000)
    }
}
