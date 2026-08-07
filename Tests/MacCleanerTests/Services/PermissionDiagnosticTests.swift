import Testing
import Foundation
@testable import MacCleanerCore

@Suite("PermissionDiagnostic Tests")
struct PermissionDiagnosticTests {

    @Test("Diagnose returns a report")
    func diagnoseReturnsReport() {
        let diagnostic = PermissionDiagnostic()
        let report = diagnostic.diagnose()

        #expect(!report.results.isEmpty)
        #expect(report.timestamp <= Date())
        #expect(report.completeness >= 0 && report.completeness <= 1)
    }

    @Test("Accessible directories have accessible status")
    func accessibleDirectories() {
        let diagnostic = PermissionDiagnostic()
        let report = diagnostic.diagnose()

        // /tmp and home Library/Caches should generally be accessible
        let cachesResult = report.results.first { $0.displayName == "应用缓存目录" }
        if let result = cachesResult {
            // If the directory exists on this machine, it should be accessible
            if FileManager.default.fileExists(atPath: result.path) {
                #expect(result.isAccessible)
            }
        }
    }

    @Test("Non-existent directories have notFound status")
    func nonExistentDirectories() {
        let diagnostic = PermissionDiagnostic()
        let report = diagnostic.diagnose()

        // Some probe targets may not exist on CI/test machines
        let notFoundResults = report.results.filter { $0.status == .notFound }
        for result in notFoundResults {
            #expect(!FileManager.default.fileExists(atPath: result.path))
        }
    }

    @Test("Report completeness is fraction of accessible results")
    func completenessCalculation() {
        let report = PermissionDiagnosticReport(
            hasFullDiskAccess: false,
            results: [
                DirectoryAccessResult(
                    path: "/a", displayName: "A",
                    status: .accessible, relatedModule: nil
                ),
                DirectoryAccessResult(
                    path: "/b", displayName: "B",
                    status: .denied, relatedModule: .xcode
                ),
            ],
            timestamp: Date()
        )

        #expect(report.completeness == 0.5)
        #expect(report.accessibleCount == 1)
        #expect(report.deniedCount == 1)
    }

    @Test("Affected modules computed from denied results")
    func affectedModules() {
        let report = PermissionDiagnosticReport(
            hasFullDiskAccess: false,
            results: [
                DirectoryAccessResult(
                    path: "/a", displayName: "A",
                    status: .denied, relatedModule: .xcode
                ),
                DirectoryAccessResult(
                    path: "/b", displayName: "B",
                    status: .denied, relatedModule: .xcode
                ),
                DirectoryAccessResult(
                    path: "/c", displayName: "C",
                    status: .denied, relatedModule: .developerCaches
                ),
                DirectoryAccessResult(
                    path: "/d", displayName: "D",
                    status: .accessible, relatedModule: .applicationCaches
                ),
            ],
            timestamp: Date()
        )

        #expect(report.affectedModules.count == 2)
        #expect(report.affectedModules.contains(.xcode))
        #expect(report.affectedModules.contains(.developerCaches))
        #expect(!report.affectedModules.contains(.applicationCaches))
    }
}
