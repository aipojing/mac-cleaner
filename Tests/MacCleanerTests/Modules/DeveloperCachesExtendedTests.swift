import Testing
import Foundation
@testable import MacCleanerCore

@Suite("DeveloperCaches Extended Scanner Tests")
struct DeveloperCachesExtendedTests {

    @Test("Module description includes new tools")
    func descriptionIncludesNewTools() {
        let module = DeveloperCachesModule()
        let desc = module.description
        #expect(desc.contains("Cargo"))
        #expect(desc.contains("Go"))
        #expect(desc.contains("pip"))
        #expect(desc.contains("SwiftPM"))
        #expect(desc.contains("Homebrew"))
    }

    @Test("Scan produces items with correct subcategories for new tools")
    func scanProducesCorrectSubcategories() async throws {
        let module = DeveloperCachesModule()
        let result = try await module.scan(context: ScanContext())

        let subcategories = Set(result.items.compactMap(\.subcategory))
        // At minimum, some of these should be present on a dev machine
        let allKnown: Set<String> = [
            "gradle", "maven", "npm", "yarn", "pnpm", "cocoapods", "pub",
            "homebrew", "cargo", "go", "pip", "swiftpm",
        ]
        // Every subcategory produced should be in our known set
        for subcat in subcategories {
            #expect(allKnown.contains(subcat), "Unknown subcategory: \(subcat)")
        }
    }

    @Test("All scanned items have valid absolute paths")
    func allItemsHaveAbsolutePaths() async throws {
        let module = DeveloperCachesModule()
        let result = try await module.scan(context: ScanContext())
        for item in result.items {
            #expect(item.path.hasPrefix("/"), "Non-absolute path: \(item.path)")
        }
    }

    @Test("All scanned items have positive sizes")
    func allItemsHavePositiveSizes() async throws {
        let module = DeveloperCachesModule()
        let result = try await module.scan(context: ScanContext())
        for item in result.items {
            #expect(item.size > 0, "Zero-size item: \(item.displayName)")
        }
    }

    @Test("All scanned items carry developer cache evidence tags")
    func allItemsHaveEvidenceTags() async throws {
        let module = DeveloperCachesModule()
        let result = try await module.scan(context: ScanContext())
        for item in result.items {
            #expect(item.evidenceTags.contains("cache"), "Missing cache tag: \(item.displayName)")
            #expect(item.evidenceTags.contains("developer-tool"),
                    "Missing developer-tool tag: \(item.displayName)")
        }
    }
}
