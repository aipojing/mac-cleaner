import Testing
import Foundation
@testable import MacCleanerCore

@Suite("Module Scan/Clean Semantic Alignment Tests")
struct ModuleSemanticTests {

    // MARK: - iOS Simulators

    @Test("Simulator device items use subcategory for deletion, not path")
    func simulatorDeviceUsesSubcategory() async throws {
        let mock = MockShellExecutor()
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
              {"name": "iPhone 16", "udid": "AAA-111", "state": "Shutdown", "isAvailable": true, "dataPathSize": 100, "dataPath": "/tmp/CoreSimulator/Devices/AAA-111/data"},
              {"name": "iPhone 16 Pro", "udid": "BBB-222", "state": "Shutdown", "isAvailable": true, "dataPathSize": 200, "dataPath": "/tmp/CoreSimulator/Devices/BBB-222/data"}
            ]
          }
        }
        """
        mock.setResponse(for: "xcrun simctl list devices -j", stdout: json)
        mock.setResponse(for: "xcrun simctl runtime list -j", stdout: "[]")
        mock.setResponse(for: "xcrun simctl list runtimes -j", stdout: "{\"runtimes\":[]}")
        mock.setResponse(for: "xcrun simctl delete AAA-111")
        mock.setResponse(for: "xcrun simctl delete BBB-222")

        let module = IOSSimulatorsModule(shell: mock)
        let scanResult = try await module.scan(context: ScanContext())
        let deviceItems = scanResult.items.filter { ($0.subcategory ?? "").hasPrefix("devices:") }

        // Verify subcategory contains ALL UDIDs
        let item = deviceItems.first!
        let udids = item.subcategory!.replacingOccurrences(of: "devices:", with: "").split(separator: ",")
        #expect(udids.count == 2)
        #expect(udids.contains("AAA-111"))
        #expect(udids.contains("BBB-222"))

        // Clean should invoke simctl delete for each UDID
        let report = try await module.clean(items: deviceItems, dryRun: false)
        let deleteCommands = mock.executedCommands.filter { $0.arguments.first == "simctl" && $0.arguments.contains("delete") }
        #expect(deleteCommands.count == 2)
        #expect(report.successCount == 2)
    }

    @Test("Simulator runtime items use subcategory identifier for deletion")
    func simulatorRuntimeUsesSubcategory() async throws {
        let mock = MockShellExecutor()
        mock.setResponse(for: "xcrun simctl list devices -j", stdout: "{\"devices\":{}}")
        mock.setResponse(for: "xcrun simctl runtime list -j", stdout: "[]")
        mock.setResponse(for: "xcrun simctl list runtimes -j", stdout: "{\"runtimes\":[]}")

        let runtimeID = "com.apple.CoreSimulator.SimRuntime.iOS-17-0"
        let item = CleanableItem(
            path: "/Library/Developer/CoreSimulator/Volumes/iOS_21A328",
            displayName: "iOS 17.0 Runtime",
            size: 7_000_000_000,
            category: .iosSimulators,
            subcategory: "runtime:\(runtimeID)",
            evidenceTags: ["simulator", "developer-tool", "runtime"]
        )

        mock.setResponse(for: "xcrun simctl runtime delete \(runtimeID)")

        let module = IOSSimulatorsModule(shell: mock)
        let report = try await module.clean(items: [item], dryRun: false)

        #expect(report.successCount == 1)
        #expect(report.actualFreed == 7_000_000_000)
        #expect(report.expectedSize == 7_000_000_000)
    }

    @Test("Simulator clean reports failures with structured reasons")
    func simulatorCleanFailureReasons() async throws {
        let mock = MockShellExecutor()
        mock.setResponse(for: "xcrun simctl list devices -j", stdout: "{\"devices\":{}}")
        mock.setResponse(for: "xcrun simctl runtime list -j", stdout: "[]")
        mock.setResponse(for: "xcrun simctl list runtimes -j", stdout: "{\"runtimes\":[]}")

        let item = CleanableItem(
            path: "device-path",
            displayName: "Test Device",
            size: 100,
            category: .iosSimulators,
            subcategory: "devices:FAIL-UDID"
        )

        mock.setResponse(
            for: "xcrun simctl delete FAIL-UDID",
            stderr: "Unable to delete device: permission denied",
            exitCode: 1
        )

        let module = IOSSimulatorsModule(shell: mock)
        let report = try await module.clean(items: [item], dryRun: false)

        #expect(report.failureCount == 1)
        #expect(report.failedItems.first?.reason == .permissionDenied)
        #expect(report.failedItems.first?.expectedSize == 100)
    }

    // MARK: - AI Tool Caches

    @Test("AI tool cache items use exact directory paths for deletion")
    func aiToolPathAlignment() async throws {
        // AI tool module uses Deleter which deletes by item.path
        // Verify scan produces paths that are real directories
        let module = AIToolCachesModule()
        let result = try await module.scan(context: ScanContext())

        for item in result.items {
            // Every scanned item path should be an existing directory
            #expect(
                FileManager.default.fileExists(atPath: item.path),
                "Scanned path does not exist: \(item.path)"
            )
        }
    }

    @Test("AI tool cache paths are narrowed to cache subdirectories")
    func aiToolNarrowedPaths() async throws {
        let module = AIToolCachesModule()
        let result = try await module.scan(context: ScanContext())

        // None of the paths should be a bare home directory tool folder
        // like ~/.codex or ~/.gemini (those contain config)
        let home = DiskScanner.homeDirectory
        let dangerousPaths = [
            "\(home)/.codex",
            "\(home)/.gemini",
            "\(home)/.aider",
            "\(home)/.claude",
        ]

        for item in result.items {
            #expect(
                !dangerousPaths.contains(item.path),
                "Item path is too broad (would delete config): \(item.path)"
            )
        }
    }

    // MARK: - General Module Protocol

    @Test("All file-based modules produce paths that Deleter can act on")
    func fileBasedModulesProduceValidPaths() async throws {
        // Modules that use Deleter (not shell commands) should produce file paths
        let fileBasedModules: [any CleanerModule] = [
            DeveloperCachesModule(),
            XcodeModule(),
            AIToolCachesModule(),
            ApplicationCachesModule(),
        ]

        for module in fileBasedModules {
            guard module.isAvailable() else { continue }
            let result = try await module.scan(context: ScanContext())
            for item in result.items {
                // Path should start with / (absolute)
                #expect(
                    item.path.hasPrefix("/"),
                    "\(module.displayName): item path is not absolute: \(item.path)"
                )
            }
        }
    }

    /// 支持注入扫描根/主目录的模块，用 TemporaryHome fixture 验证，
    /// 不再扫描真实用户主目录。DeveloperCaches/Xcode/AIToolCaches/
    /// ApplicationCaches/AndroidSDK 目前不支持注入 home，不在此列。
    private func fixtureBackedModules(home: TemporaryHome) -> [any CleanerModule] {
        [
            SystemLogsModule(homeDirectory: home.url),
            DockerModule(homeDirectory: home.url),
            LargeFileScannerModule(scanRoot: home.path, minAllocatedSize: 1),
            DuplicateFilesModule(scanRoot: home.path, minSize: 1),
        ]
    }

    private func makeSemanticFixture() throws -> TemporaryHome {
        try TemporaryHome.fixture(files: [
            "Library/Logs/MyApp/big.log": String(repeating: "x", count: 1_300_000),
            "Library/Containers/com.docker.docker/Data/log/vm/docker.log": "docker-log-content",
            ".docker/buildx/cache.db": "buildx-cache-content-for-size",
            "Downloads/big.bin": String(repeating: "y", count: 64 * 1024),
            "Documents/copy1.txt": "duplicate-content",
            "Desktop/copy2.txt": "duplicate-content",
        ])
    }

    @Test("所有存在的文件候选都记录了扫描身份")
    func scannedFileCandidatesCarryIdentity() async throws {
        let home = try makeSemanticFixture()
        defer { home.remove() }

        for module in fixtureBackedModules(home: home) {
            guard module.isAvailable() else { continue }
            let result = try await module.scan(context: ScanContext())
            #expect(!result.items.isEmpty, "\(module.displayName): fixture 应产生候选")
            for item in result.items {
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
                guard exists else { continue }
                // 存在的文件候选必须带身份，否则删除 guard 无法确认目标
                #expect(
                    item.fileIdentity != nil,
                    "\(module.displayName): 存在的候选缺少身份: \(item.path)"
                )
            }
        }
    }

    @Test("DryRun clean never deletes files across all modules")
    func dryRunNeverDeletes() async throws {
        let home = try makeSemanticFixture()
        defer { home.remove() }

        for module in fixtureBackedModules(home: home) {
            guard module.isAvailable() else { continue }
            let result = try await module.scan(context: ScanContext())
            guard !result.items.isEmpty else { continue }

            let firstItem = result.items[0]
            let report = try await module.clean(items: [firstItem], dryRun: true)

            // File should still exist after dry run
            if firstItem.path.hasPrefix("/") {
                #expect(
                    FileManager.default.fileExists(atPath: firstItem.path),
                    "\(module.displayName): dryRun deleted \(firstItem.path)!"
                )
            }
            #expect(report.successCount >= 0)
        }
    }

    // MARK: - Large Files

    @Test("大文件模块常驻候选不超过 N，按实际占用保留最大项")
    func largeFilesBoundedRetention() async throws {
        let root = NSTemporaryDirectory() + "large-files-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        // 写入真实数据确保 st_blocks 反映大小
        let sizes: [(String, Int)] = [
            ("a.bin", 8 * 1024),
            ("b.bin", 64 * 1024),
            ("c.bin", 16 * 1024),
            ("d.bin", 128 * 1024),
            ("e.bin", 32 * 1024),
        ]
        for (name, size) in sizes {
            let data = Data(repeating: 0xAB, count: size)
            try data.write(to: URL(fileURLWithPath: "\(root)/\(name)"))
        }

        let module = LargeFileScannerModule(scanRoot: root, minAllocatedSize: 1, limit: 3)
        let result = try await module.scan(context: ScanContext())

        #expect(result.items.count == 3)
        #expect(result.items.map(\.path) == [
            "\(root)/d.bin", "\(root)/b.bin", "\(root)/e.bin",
        ])
        // 展示大小为实际占用，且身份与硬链接计数已记录
        for item in result.items {
            #expect(item.fileIdentity != nil)
            #expect(item.allocatedSize == item.size)
            #expect(item.linkCount >= 1)
        }
    }

    @Test("大文件模块同大小按路径稳定排序")
    func largeFilesStableOrder() async throws {
        let root = NSTemporaryDirectory() + "large-stable-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        for name in ["z.bin", "y.bin", "x.bin"] {
            try Data(repeating: 0xCD, count: 8 * 1024).write(to: URL(fileURLWithPath: "\(root)/\(name)"))
        }

        let module = LargeFileScannerModule(scanRoot: root, minAllocatedSize: 1, limit: 10)
        let first = try await module.scan(context: ScanContext())
        let second = try await module.scan(context: ScanContext())
        #expect(first.items.map(\.path) == second.items.map(\.path))
        #expect(first.items.map(\.path) == ["\(root)/x.bin", "\(root)/y.bin", "\(root)/z.bin"])
    }
}
