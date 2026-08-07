import Testing
import Foundation
@testable import MacCleanerCore

@Suite("ScheduledScanConfig Tests")
struct ScheduledScanConfigTests {

    @Test("Default config is disabled")
    func defaultDisabled() {
        let config = ScheduledScanConfig.disabled
        #expect(!config.enabled)
    }

    @Test("Daily preset has 86400 second interval")
    func dailyPreset() {
        let config = ScheduledScanConfig.daily
        #expect(config.enabled)
        #expect(config.intervalSeconds == 86400)
    }

    @Test("Weekly preset has 604800 second interval")
    func weeklyPreset() {
        let config = ScheduledScanConfig.weekly
        #expect(config.enabled)
        #expect(config.intervalSeconds == 604800)
    }

    @Test("withLastScanDate returns new copy with date set")
    func withLastScanDate() {
        let config = ScheduledScanConfig.daily
        let now = Date()
        let updated = config.withLastScanDate(now)
        #expect(updated.lastScanDate == now)
        #expect(updated.enabled == config.enabled)
        #expect(config.lastScanDate == nil) // original unchanged
    }

    @Test("withEnabled returns new copy toggled")
    func withEnabled() {
        let config = ScheduledScanConfig.daily
        let disabled = config.withEnabled(false)
        #expect(!disabled.enabled)
        #expect(config.enabled) // original unchanged
    }

    @Test("Config is Codable")
    func configCodable() throws {
        let config = ScheduledScanConfig(
            enabled: true,
            intervalSeconds: 3600,
            lowSpaceThresholdPercent: 15,
            notifyOnLowSpace: true,
            lastScanDate: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduledScanConfig.self, from: data)

        #expect(decoded.enabled)
        #expect(decoded.intervalSeconds == 3600)
        #expect(decoded.lowSpaceThresholdPercent == 15)
    }
}

@Suite("ScheduledScanService Tests")
struct ScheduledScanServiceTests {

    @Test("Service starts with loaded or default config")
    func serviceStartup() async {
        let tempPath = NSTemporaryDirectory() + "sched-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let service = ScheduledScanService(storePath: tempPath)
        let config = await service.currentConfig
        #expect(!config.enabled) // default is disabled
    }

    @Test("Service persists config updates")
    func persistsConfig() async {
        let tempPath = NSTemporaryDirectory() + "sched-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let service1 = ScheduledScanService(storePath: tempPath)
        await service1.updateConfig(.daily)

        let service2 = ScheduledScanService(storePath: tempPath)
        let loaded = await service2.currentConfig
        #expect(loaded.enabled)
        #expect(loaded.intervalSeconds == 86400)
    }
}

@Suite("Scheduled scan candidate stats")
struct ScheduledScanCandidateTests {
    @Test("定时扫描统计全部过滤后候选，不称为推荐空间")
    func scheduledScanStoresCandidateBytes() async {
        let tempPath = NSTemporaryDirectory() + "sched-cand-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let service = ScheduledScanService(storePath: tempPath)
        let module = FixtureCleanerModule(
            identifier: .systemLogs,
            items: [
                CleanableItem(
                    path: "/tmp/log-a",
                    displayName: "log-a",
                    size: 42,
                    category: .systemLogs,
                    evidenceTags: ["log", "diagnostic"]
                ),
            ]
        )
        _ = await service.performScanForTesting(modules: [module])
        #expect(await service.lastScanCandidateBytes == 42)
    }
}
