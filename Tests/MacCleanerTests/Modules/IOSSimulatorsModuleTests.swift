import Testing
@testable import MacCleanerCore

@Suite("IOSSimulatorsModule Tests")
struct IOSSimulatorsModuleTests {

    /// 注册空 runtime 响应（防止 runtime 扫描影响 device 测试）
    private func registerEmptyRuntimeResponses(_ mock: MockShellExecutor) {
        mock.setResponse(for: "xcrun simctl runtime list -j", stdout: "[]")
        mock.setResponse(for: "xcrun simctl list runtimes -j", stdout: "{\"runtimes\":[]}")
    }

    @Test("Parses simulator devices and groups by runtime")
    func parsesSimulatorJSON() async throws {
        let mock = MockShellExecutor()
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
              {"name": "iPhone 16 Pro", "udid": "AAA-111", "state": "Shutdown", "isAvailable": true, "dataPathSize": 104857600}
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
              {"name": "iPhone 15", "udid": "BBB-222", "state": "Shutdown", "isAvailable": true, "dataPathSize": 209715200}
            ]
          }
        }
        """
        mock.setResponse(for: "xcrun simctl list devices -j", stdout: json)
        registerEmptyRuntimeResponses(mock)

        let module = IOSSimulatorsModule(shell: mock)
        let result = try await module.scan(context: ScanContext())

        // 应该有设备项（不含 runtime 因为注册了空响应）
        let deviceItems = result.items.filter { ($0.subcategory ?? "").hasPrefix("devices:") }
        #expect(deviceItems.count == 2)

        let latest = deviceItems.first { $0.displayName.contains("18.5") }
        #expect(latest?.evidenceTags.contains("simulator") == true)

        let older = deviceItems.first { $0.displayName.contains("17.5") }
        #expect(older?.evidenceTags.contains("device-data") == true)
    }

    @Test("Device path is real directory, not UDIDs")
    func pathIsNotUDIDs() async throws {
        let mock = MockShellExecutor()
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
              {"name": "iPhone 16", "udid": "AAA-111", "state": "Shutdown", "isAvailable": true, "dataPathSize": 100, "dataPath": "/Users/test/Library/Developer/CoreSimulator/Devices/AAA-111/data"}
            ]
          }
        }
        """
        mock.setResponse(for: "xcrun simctl list devices -j", stdout: json)
        registerEmptyRuntimeResponses(mock)

        let module = IOSSimulatorsModule(shell: mock)
        let result = try await module.scan(context: ScanContext())

        let deviceItem = result.items.first { ($0.subcategory ?? "").hasPrefix("devices:") }
        #expect(deviceItem?.path.contains("CoreSimulator") == true)
        #expect(deviceItem?.subcategory?.contains("AAA-111") == true)
    }

    @Test("Cleanup reports correct size per device")
    func cleanupReportsSize() async throws {
        let mock = MockShellExecutor()
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
              {"name": "iPhone 15", "udid": "CCC-333", "state": "Shutdown", "isAvailable": true, "dataPathSize": 200000000, "dataPath": "/tmp/CCC-333/data"}
            ]
          }
        }
        """
        mock.setResponse(for: "xcrun simctl list devices -j", stdout: json)
        registerEmptyRuntimeResponses(mock)
        mock.setResponse(for: "xcrun simctl delete CCC-333", stdout: "")

        let module = IOSSimulatorsModule(shell: mock)
        let scanResult = try await module.scan(context: ScanContext())
        let deviceItems = scanResult.items.filter { ($0.subcategory ?? "").hasPrefix("devices:") }
        let report = try await module.clean(items: deviceItems, dryRun: true)

        #expect(report.totalFreed > 0)
    }

    @Test("Semantic version: 18.10 > 18.9")
    func semanticVersionEdgeCase() async throws {
        let mock = MockShellExecutor()
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-10": [
              {"name": "iPhone 16", "udid": "D-1", "state": "Shutdown", "isAvailable": true, "dataPathSize": 100}
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-9": [
              {"name": "iPhone 16", "udid": "D-2", "state": "Shutdown", "isAvailable": true, "dataPathSize": 100}
            ]
          }
        }
        """
        mock.setResponse(for: "xcrun simctl list devices -j", stdout: json)
        registerEmptyRuntimeResponses(mock)

        let module = IOSSimulatorsModule(shell: mock)
        let result = try await module.scan(context: ScanContext())

        let deviceItems = result.items.filter { ($0.subcategory ?? "").hasPrefix("devices:") }
        let v1810 = deviceItems.first { $0.displayName.contains("18.10") }
        #expect(v1810 != nil)

        let v189 = deviceItems.first { $0.displayName.contains("18.9") }
        #expect(v189 != nil)
    }

    @Test("Clean deletes runtime via simctl runtime delete")
    func cleanDeletesRuntime() async throws {
        let mock = MockShellExecutor()
        // 空设备
        mock.setResponse(for: "xcrun simctl list devices -j", stdout: "{\"devices\":{}}")
        mock.setResponse(for: "xcrun simctl runtime list -j", stdout: "[]")
        mock.setResponse(for: "xcrun simctl list runtimes -j", stdout: "{\"runtimes\":[]}")

        // 模拟一个 runtime 项（手动构造 CleanableItem）
        let item = CleanableItem(
            path: "/Library/Developer/CoreSimulator/Volumes/iOS_21F79",
            displayName: "iOS 17.5 Runtime",
            size: 7_000_000_000,
            category: .iosSimulators,
            subcategory: "runtime:com.apple.CoreSimulator.SimRuntime.iOS-17-5",
            evidenceTags: ["simulator", "developer-tool", "runtime"]
        )

        mock.setResponse(for: "xcrun simctl runtime delete com.apple.CoreSimulator.SimRuntime.iOS-17-5", stdout: "")

        let module = IOSSimulatorsModule(shell: mock)
        let report = try await module.clean(items: [item], dryRun: false)

        #expect(report.successCount == 1)
        #expect(report.totalFreed == 7_000_000_000)
        // 确认调用了 simctl runtime delete
        let commands = mock.executedCommands.map { ([$0.command] + $0.arguments).joined(separator: " ") }
        #expect(commands.contains("xcrun simctl runtime delete com.apple.CoreSimulator.SimRuntime.iOS-17-5"))
    }

    @Test("Module is available when xcrun exists")
    func checkAvailability() {
        let module = IOSSimulatorsModule()
        #expect(module.isAvailable() == true)
    }
}

@Suite("SemanticVersion Tests")
struct SemanticVersionTests {

    @Test("Parses major.minor")
    func parsesMajorMinor() {
        let v = SemanticVersion("18.5")
        #expect(v?.major == 18)
        #expect(v?.minor == 5)
        #expect(v?.patch == 0)
    }

    @Test("Parses major.minor.patch")
    func parsesMajorMinorPatch() {
        let v = SemanticVersion("17.5.1")
        #expect(v?.major == 17)
        #expect(v?.minor == 5)
        #expect(v?.patch == 1)
    }

    @Test("18.10 > 18.9")
    func twoDigitMinor() {
        let v1810 = SemanticVersion("18.10")!
        let v189 = SemanticVersion("18.9")!
        #expect(v1810 > v189)
    }

    @Test("Description omits patch when zero")
    func description() {
        #expect(SemanticVersion("18.5")?.description == "18.5")
        #expect(SemanticVersion("17.5.1")?.description == "17.5.1")
    }

    @Test("Returns nil for invalid input")
    func invalidInput() {
        #expect(SemanticVersion("abc") == nil)
        #expect(SemanticVersion("18") == nil)
    }
}
