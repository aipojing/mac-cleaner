import Testing
import Foundation
@testable import MacCleanerCore

@Suite("CleaningProfile Tests")
struct CleaningProfileTests {

    @Test("Built-in profiles exist and have valid names")
    func builtInProfiles() {
        let profiles = CleaningProfile.builtInProfiles
        #expect(profiles.count == 3)
        #expect(profiles.allSatisfy { $0.isBuiltIn })
        #expect(profiles.allSatisfy { !$0.name.isEmpty })
        #expect(profiles.allSatisfy { !$0.description.isEmpty })
    }

    @Test("devSlimDown profile filters to dev-related modules")
    func devSlimDownFilters() {
        let profile = CleaningProfile.devSlimDown
        let filtered = profile.filterModules(ModuleIdentifier.allCases)
        #expect(filtered.contains(.developerCaches))
        #expect(filtered.contains(.xcode))
        #expect(filtered.contains(.docker))
        #expect(!filtered.contains(.largeFiles))
        #expect(!filtered.contains(.applicationCaches))
    }

    @Test("清理方案只筛选模块，不筛选条目")
    func profileOnlyFiltersModules() {
        let profile = CleaningProfile(
            name: "日志候选",
            description: "扫描日志候选",
            moduleIDs: [ModuleIdentifier.systemLogs.rawValue],
            isBuiltIn: true,
            icon: "doc.plaintext"
        )
        #expect(profile.filterModules(ModuleIdentifier.allCases) == [.systemLogs])
    }

    @Test("preRelease profile includes all modules")
    func preReleaseAllModules() {
        let profile = CleaningProfile.preRelease
        #expect(profile.moduleIDs == nil)
        let filtered = profile.filterModules(ModuleIdentifier.allCases)
        #expect(filtered.count == ModuleIdentifier.allCases.count)
    }

    @Test("Profile is Codable")
    func profileCodable() throws {
        let profile = CleaningProfile(
            name: "Custom", description: "Test profile",
            moduleIDs: ["dev-caches", "xcode"]
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CleaningProfile.self, from: data)
        #expect(decoded.name == "Custom")
        #expect(decoded.moduleIDs?.count == 2)
    }

    @Test("logsOnly profile targets system-logs module")
    func logsOnlyTargetsLogs() {
        let profile = CleaningProfile.logsOnly
        let filtered = profile.filterModules(ModuleIdentifier.allCases)
        #expect(filtered.count == 1)
        #expect(filtered.first == .systemLogs)
    }
}

@Suite("ProfileManager Tests")
struct ProfileManagerTests {

    @Test("ProfileManager includes built-in profiles")
    func includesBuiltIns() async {
        let tempPath = NSTemporaryDirectory() + "profiles-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let manager = ProfileManager(storePath: tempPath)
        let all = await manager.allProfiles
        #expect(all.count >= CleaningProfile.builtInProfiles.count)
    }

    @Test("ProfileManager CRUD for custom profiles")
    func customProfileCRUD() async {
        let tempPath = NSTemporaryDirectory() + "profiles-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let manager = ProfileManager(storePath: tempPath)

        let custom = CleaningProfile(name: "My Profile", description: "Custom test")
        await manager.addProfile(custom)
        #expect(await manager.customProfiles.count == 1)

        let found = await manager.profile(named: "My Profile")
        #expect(found != nil)

        await manager.removeProfile(id: custom.id)
        #expect(await manager.customProfiles.count == 0)
    }

    @Test("ProfileManager persists to disk")
    func persistsToDisk() async {
        let tempPath = NSTemporaryDirectory() + "profiles-test-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let manager1 = ProfileManager(storePath: tempPath)
        await manager1.addProfile(CleaningProfile(name: "Saved", description: "Test"))

        let manager2 = ProfileManager(storePath: tempPath)
        let customs = await manager2.customProfiles
        #expect(customs.count == 1)
        #expect(customs.first?.name == "Saved")
    }
}
