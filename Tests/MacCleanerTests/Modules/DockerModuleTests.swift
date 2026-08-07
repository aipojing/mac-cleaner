import Testing
import Foundation
@testable import MacCleanerCore

@Suite("DockerModule Tests")
struct DockerModuleTests {

    @Test("Docker module has correct identifier")
    func correctIdentifier() {
        let module = DockerModule()
        #expect(module.identifier == .docker)
        #expect(module.displayName == "Docker")
    }

    @Test("Docker module availability depends on Docker data directory")
    func availabilityCheck() {
        let module = DockerModule()
        let home = DiskScanner.homeDirectory
        let dockerPath = "\(home)/Library/Containers/com.docker.docker"
        let expected = FileManager.default.fileExists(atPath: dockerPath)
        #expect(module.isAvailable() == expected)
    }

    @Test("Scan produces items with docker category")
    func scanCategory() async throws {
        let module = DockerModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        for item in result.items {
            #expect(item.category == .docker)
        }
    }

    @Test("Scan items have valid subcategories")
    func scanSubcategories() async throws {
        let module = DockerModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        let validSubcategories: Set<String> = ["disk-image", "build-cache", "app-cache", "logs"]
        for item in result.items {
            #expect(
                validSubcategories.contains(item.subcategory ?? ""),
                "Invalid subcategory: \(item.subcategory ?? "nil")"
            )
        }
    }

    @Test("DryRun does not delete Docker files")
    func dryRunSafety() async throws {
        let module = DockerModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        guard let firstItem = result.items.first else { return }

        let report = try await module.clean(items: [firstItem], dryRun: true)
        #expect(report.dryRun)
        if firstItem.path.hasPrefix("/") {
            #expect(FileManager.default.fileExists(atPath: firstItem.path))
        }
    }

    @Test("ModuleIdentifier.docker has correct raw value")
    func moduleIdentifierRawValue() {
        #expect(ModuleIdentifier.docker.rawValue == "docker")
        #expect(ModuleIdentifier.docker.displayName == "Docker")
    }

    @Test("Docker registered in ModuleRegistry")
    func registeredInRegistry() {
        let module = ModuleRegistry.module(for: .docker)
        #expect(module != nil)
        #expect(module?.identifier == .docker)
    }

    @Test("Docker contexts 不作为缓存候选")
    func excludesDockerContexts() async throws {
        let home = try TemporaryHome.fixture(
            files: [
                ".docker/buildx/cache.db": "buildx-cache-content-for-size",
                ".docker/contexts/meta/ctx/meta.json": "{\"name\":\"ctx\"}",
            ]
        )
        defer { home.remove() }

        let module = DockerModule(homeDirectory: home.url)
        let result = try await module.scan(context: ScanContext())
        let paths = Set(result.items.map(\.path))

        #expect(paths.contains(home.path(".docker/buildx")))
        #expect(!paths.contains(home.path(".docker/contexts")))
    }
}
