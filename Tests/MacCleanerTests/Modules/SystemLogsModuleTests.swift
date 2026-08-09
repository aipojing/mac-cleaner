import Testing
import Foundation
@testable import MacCleanerCore

@Suite("SystemLogsModule Tests")
struct SystemLogsModuleTests {

    /// 隔离的临时主目录 fixture：用户日志（>1MB）、诊断报告、
    /// 已归档崩溃报告、Spindump 各一份，不触碰真实主目录。
    private func makeLogHome() throws -> TemporaryHome {
        try TemporaryHome.fixture(files: [
            "Library/Logs/MyApp/big.log": String(repeating: "x", count: 1_300_000),
            "Library/Logs/DiagnosticReports/a.crash": "a-crash-content-for-size",
            "Library/Logs/DiagnosticReports/Retired/old.crash": "old-crash-content",
            "Library/Logs/Spindump/sample.spindump": "spindump-content",
        ])
    }

    @Test("Module has correct identifier")
    func correctIdentifier() {
        let module = SystemLogsModule()
        #expect(module.identifier == .systemLogs)
        #expect(module.displayName == "系统日志")
    }

    @Test("Module availability follows fixture home Library/Logs")
    func availabilityCheck() throws {
        let withLogs = try makeLogHome()
        defer { withLogs.remove() }
        #expect(SystemLogsModule(homeDirectory: withLogs.url).isAvailable())

        let withoutLogs = try TemporaryHome.fixture()
        defer { withoutLogs.remove() }
        #expect(!SystemLogsModule(homeDirectory: withoutLogs.url).isAvailable())
    }

    @Test("Scan produces items with system-logs category")
    func scanCategory() async throws {
        let home = try makeLogHome()
        defer { home.remove() }

        let result = try await SystemLogsModule(homeDirectory: home.url).scan(context: ScanContext())
        #expect(!result.items.isEmpty)
        for item in result.items {
            #expect(item.category == .systemLogs)
        }
    }

    @Test("Scan items have valid subcategories")
    func scanSubcategories() async throws {
        let home = try makeLogHome()
        defer { home.remove() }

        let result = try await SystemLogsModule(homeDirectory: home.url).scan(context: ScanContext())
        let validSubcategories: Set<String> = [
            "user-logs", "diagnostic-reports", "retired-crashes", "spindump",
        ]
        #expect(!result.items.isEmpty)
        for item in result.items {
            #expect(
                validSubcategories.contains(item.subcategory ?? ""),
                "Invalid subcategory: \(item.subcategory ?? "nil")"
            )
        }
        // fixture 覆盖全部四类来源
        #expect(Set(result.items.compactMap(\.subcategory)) == validSubcategories)
    }

    @Test("Scan items carry log/diagnostic evidence tags")
    func evidenceTags() async throws {
        let home = try makeLogHome()
        defer { home.remove() }

        let result = try await SystemLogsModule(homeDirectory: home.url).scan(context: ScanContext())
        #expect(!result.items.isEmpty)
        for item in result.items {
            #expect(
                item.evidenceTags == ["diagnostic", "log"],
                "Invalid tags: \(item.evidenceTags)"
            )
        }
    }

    @Test("DryRun does not delete logs")
    func dryRunSafety() async throws {
        let home = try makeLogHome()
        defer { home.remove() }

        let module = SystemLogsModule(homeDirectory: home.url)
        let result = try await module.scan(context: ScanContext())
        let firstItem = try #require(result.items.first)

        let report = try await module.clean(items: [firstItem], dryRun: true)
        #expect(report.dryRun)
        #expect(FileManager.default.fileExists(atPath: firstItem.path))
    }

    @Test("Module registered in ModuleRegistry")
    func registeredInRegistry() {
        let module = ModuleRegistry.module(for: .systemLogs)
        #expect(module != nil)
        #expect(module?.identifier == .systemLogs)
    }

    @Test("ModuleIdentifier.systemLogs has correct raw value")
    func moduleIdentifierRawValue() {
        #expect(ModuleIdentifier.systemLogs.rawValue == "system-logs")
    }

    @Test("诊断报告只返回非 Retired 的直接子项")
    func diagnosticReportsPreserveRetired() async throws {
        let home = try TemporaryHome.fixture(
            files: [
                "Library/Logs/DiagnosticReports/a.crash": "a-crash-content-for-size",
                "Library/Logs/DiagnosticReports/Retired/old.crash": "old-crash-content",
            ]
        )
        defer { home.remove() }

        let module = SystemLogsModule(homeDirectory: home.url)
        let result = try await module.scan(context: ScanContext())
        let paths = Set(result.items.map(\.path))

        #expect(paths.contains(home.path("Library/Logs/DiagnosticReports/a.crash")))
        #expect(!paths.contains(home.path("Library/Logs/DiagnosticReports")))
        #expect(!paths.contains(home.path("Library/Logs/DiagnosticReports/Retired")))
    }
}
