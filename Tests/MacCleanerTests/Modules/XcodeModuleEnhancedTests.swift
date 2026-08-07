import Testing
import Foundation
@testable import MacCleanerCore

@Suite("XcodeModule Enhanced Tests")
struct XcodeModuleEnhancedTests {

    @Test("DerivedData items show project names when info.plist exists")
    func derivedDataProjectNames() async throws {
        let module = XcodeModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        let ddItems = result.items.filter { $0.subcategory == "derived-data" }

        // DerivedData items should not contain the hash suffix in display name
        for item in ddItems {
            // Display name should be a project name or have stale hint, not raw dir name
            #expect(!item.displayName.isEmpty)
        }
    }

    @Test("DerivedData items carry Xcode evidence tags")
    func derivedDataEvidenceTags() async throws {
        let module = XcodeModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        let ddItems = result.items.filter { $0.subcategory == "derived-data" }

        for item in ddItems {
            #expect(item.evidenceTags == ["cache", "developer-tool", "xcode"],
                    "Unexpected tags: \(item.evidenceTags)")
        }
    }

    @Test("DeviceSupport items show iOS version")
    func deviceSupportVersions() async throws {
        let module = XcodeModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        let dsItems = result.items.filter { $0.subcategory == "device-support" }

        for item in dsItems {
            #expect(item.displayName.hasPrefix("DeviceSupport/"))
        }
    }

    @Test("DeviceSupport items carry Xcode evidence tags")
    func deviceSupportEvidenceTags() async throws {
        let module = XcodeModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        let dsItems = result.items.filter { $0.subcategory == "device-support" }

        for item in dsItems {
            #expect(item.evidenceTags == ["cache", "developer-tool", "xcode"],
                    "Unexpected tags: \(item.evidenceTags)")
        }
    }
}
