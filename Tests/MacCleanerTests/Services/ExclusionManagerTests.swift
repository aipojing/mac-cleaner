import Testing
import Foundation
@testable import MacCleanerCore

@Suite("ExclusionRule Tests")
struct ExclusionRuleTests {

    @Test("Path pattern exclusion factory")
    func pathExclusionFactory() {
        let rule = ExclusionRule.pathExclusion(
            pattern: "*/DerivedData/*",
            label: "忽略 DerivedData"
        )
        #expect(rule.type == .pathPattern)
        #expect(rule.pattern == "*/DerivedData/*")
        #expect(rule.enabled)
    }

    @Test("Recency exclusion factory")
    func recencyFactory() {
        let rule = ExclusionRule.recencyExclusion(days: 7, label: "7 天内不清理")
        #expect(rule.type == .recency)
        #expect(rule.days == 7)
    }

    @Test("Min size exclusion factory")
    func minSizeFactory() {
        let rule = ExclusionRule.minSizeExclusion(
            bytes: 50 * 1024 * 1024,
            label: "低于 50MB 不展示"
        )
        #expect(rule.type == .minSize)
        #expect(rule.minBytes == Int64(50 * 1024 * 1024))
    }

    @Test("Permanent keep factory")
    func permanentKeepFactory() {
        let rule = ExclusionRule.permanentKeep(
            path: "/Users/test/.gradle",
            label: "保留 Gradle"
        )
        #expect(rule.type == .permanentKeep)
        #expect(rule.pattern == "/Users/test/.gradle")
    }

    @Test("Toggle enabled state returns new copy")
    func toggleEnabled() {
        let rule = ExclusionRule.pathExclusion(pattern: "*", label: "test")
        let disabled = rule.withEnabled(false)
        #expect(disabled.enabled == false)
        #expect(disabled.id == rule.id) // 同一 ID
        #expect(rule.enabled == true) // 原始不变
    }

    @Test("ExclusionConfig encodes and decodes")
    func configCodable() throws {
        let config = ExclusionConfig(rules: [
            .pathExclusion(pattern: "*/test", label: "Test rule"),
            .recencyExclusion(days: 3, label: "3 day rule"),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExclusionConfig.self, from: data)

        #expect(decoded.rules.count == 2)
        #expect(decoded.version == 1)
    }
}

@Suite("ExclusionManager Filter Tests")
struct ExclusionManagerFilterTests {

    private func makeItem(path: String, size: Int64, module: ModuleIdentifier = .developerCaches) -> CleanableItem {
        CleanableItem(
            path: path, displayName: (path as NSString).lastPathComponent,
            size: size, category: module
        )
    }

    @Test("Min size filter excludes small items")
    func minSizeFilter() async {
        let tempPath = NSTemporaryDirectory() + "exclusion-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let manager = ExclusionManager(storePath: tempPath)
        await manager.addRule(.minSizeExclusion(bytes: 100, label: "min 100B"))

        let items = [
            makeItem(path: "/a", size: 50),
            makeItem(path: "/b", size: 200),
            makeItem(path: "/c", size: 100),
        ]
        let filtered = await manager.applyExclusions(to: items, module: .developerCaches)

        // size 50 < 100 should be excluded, 100 is not < 100 so kept
        #expect(filtered.count == 2)
        #expect(filtered.contains { $0.path == "/b" })
        #expect(filtered.contains { $0.path == "/c" })
    }

    @Test("Permanent keep excludes exact path")
    func permanentKeep() async {
        let tempPath = NSTemporaryDirectory() + "exclusion-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let manager = ExclusionManager(storePath: tempPath)
        await manager.addRule(.permanentKeep(path: "/keep/this", label: "keep"))

        let items = [
            makeItem(path: "/keep/this", size: 100),
            makeItem(path: "/keep/this/sub", size: 50),
            makeItem(path: "/other", size: 200),
        ]
        let filtered = await manager.applyExclusions(to: items, module: .developerCaches)

        #expect(filtered.count == 1)
        #expect(filtered.first?.path == "/other")
    }

    @Test("Disabled rules are not applied")
    func disabledRulesSkipped() async {
        let tempPath = NSTemporaryDirectory() + "exclusion-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let manager = ExclusionManager(storePath: tempPath)
        let rule = ExclusionRule.minSizeExclusion(bytes: 1000, label: "min 1KB")
        await manager.addRule(rule.withEnabled(false))

        let items = [makeItem(path: "/small", size: 10)]
        let filtered = await manager.applyExclusions(to: items, module: .developerCaches)

        // Rule is disabled, so item should not be filtered
        #expect(filtered.count == 1)
    }

    @Test("Module-scoped rules only apply to matching modules")
    func moduleScopedRules() async {
        let tempPath = NSTemporaryDirectory() + "exclusion-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let manager = ExclusionManager(storePath: tempPath)
        await manager.addRule(ExclusionRule(
            type: .minSize, label: "xcode only",
            minBytes: 100, modules: ["xcode"]
        ))

        let devItem = makeItem(path: "/dev", size: 50, module: .developerCaches)
        let xcodeItem = makeItem(path: "/xcode", size: 50, module: .xcode)

        let devFiltered = await manager.applyExclusions(to: [devItem], module: .developerCaches)
        let xcodeFiltered = await manager.applyExclusions(to: [xcodeItem], module: .xcode)

        #expect(devFiltered.count == 1) // Not affected, rule is xcode-scoped
        #expect(xcodeFiltered.count == 0) // Filtered out
    }

    @Test("Rule CRUD operations")
    func crudOperations() async {
        let tempPath = NSTemporaryDirectory() + "exclusion-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let manager = ExclusionManager(storePath: tempPath)

        // Add
        let rule = ExclusionRule.pathExclusion(pattern: "*", label: "test")
        await manager.addRule(rule)
        #expect(await manager.rules.count == 1)

        // Toggle
        await manager.toggleRule(id: rule.id)
        #expect(await manager.enabledRules.count == 0)

        // Remove
        await manager.removeRule(id: rule.id)
        #expect(await manager.rules.count == 0)
    }
}
