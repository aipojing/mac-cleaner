import Testing
import Foundation
@testable import MacCleanerCore

@Suite("SystemLogsModule Tests")
struct SystemLogsModuleTests {

    @Test("Module has correct identifier")
    func correctIdentifier() {
        let module = SystemLogsModule()
        #expect(module.identifier == .systemLogs)
        #expect(module.displayName == "系统日志")
    }

    @Test("Module is available when ~/Library/Logs exists")
    func availabilityCheck() {
        let module = SystemLogsModule()
        let home = DiskScanner.homeDirectory
        let expected = FileManager.default.fileExists(atPath: "\(home)/Library/Logs")
        #expect(module.isAvailable() == expected)
    }

    @Test("Scan produces items with system-logs category")
    func scanCategory() async throws {
        let module = SystemLogsModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        for item in result.items {
            #expect(item.category == .systemLogs)
        }
    }

    @Test("Scan items have valid subcategories")
    func scanSubcategories() async throws {
        let module = SystemLogsModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        let validSubcategories: Set<String> = [
            "user-logs", "diagnostic-reports", "retired-crashes", "spindump",
        ]
        for item in result.items {
            #expect(
                validSubcategories.contains(item.subcategory ?? ""),
                "Invalid subcategory: \(item.subcategory ?? "nil")"
            )
        }
    }

    @Test("Scan items carry log/diagnostic evidence tags")
    func evidenceTags() async throws {
        let module = SystemLogsModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        for item in result.items {
            #expect(
                item.evidenceTags == ["diagnostic", "log"],
                "Invalid tags: \(item.evidenceTags)"
            )
        }
    }

    @Test("DryRun does not delete logs")
    func dryRunSafety() async throws {
        let module = SystemLogsModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        guard let firstItem = result.items.first else { return }

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
