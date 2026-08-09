import Testing
import Foundation
@testable import MacCleanerCore

@Suite("DockerModule Tests")
struct DockerModuleTests {

    /// 隔离的临时主目录 fixture：虚拟磁盘、buildx 构建缓存、
    /// 应用缓存（>100KB）、容器日志各一份，不触碰真实主目录。
    private func makeDockerHome() throws -> TemporaryHome {
        try TemporaryHome.fixture(files: [
            "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw": "disk-image-content",
            ".docker/buildx/cache.db": "buildx-cache-content-for-size",
            "Library/Caches/com.docker.docker/blob.bin": String(repeating: "c", count: 200_000),
            "Library/Containers/com.docker.docker/Data/log/vm/docker.log": "docker-log-content",
        ])
    }

    @Test("Docker module has correct identifier")
    func correctIdentifier() {
        let module = DockerModule()
        #expect(module.identifier == .docker)
        #expect(module.displayName == "Docker")
    }

    @Test("Docker module availability follows fixture data directory")
    func availabilityCheck() throws {
        let withDocker = try makeDockerHome()
        defer { withDocker.remove() }
        #expect(DockerModule(homeDirectory: withDocker.url).isAvailable())

        let withoutDocker = try TemporaryHome.fixture()
        defer { withoutDocker.remove() }
        #expect(!DockerModule(homeDirectory: withoutDocker.url).isAvailable())
    }

    @Test("Scan produces items with docker category")
    func scanCategory() async throws {
        let home = try makeDockerHome()
        defer { home.remove() }

        let result = try await DockerModule(homeDirectory: home.url).scan(context: ScanContext())
        #expect(!result.items.isEmpty)
        for item in result.items {
            #expect(item.category == .docker)
        }
    }

    @Test("Scan items have valid subcategories")
    func scanSubcategories() async throws {
        let home = try makeDockerHome()
        defer { home.remove() }

        let result = try await DockerModule(homeDirectory: home.url).scan(context: ScanContext())
        let validSubcategories: Set<String> = ["disk-image", "build-cache", "app-cache", "logs"]
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

    @Test("DryRun does not delete Docker files")
    func dryRunSafety() async throws {
        let home = try makeDockerHome()
        defer { home.remove() }

        let module = DockerModule(homeDirectory: home.url)
        let result = try await module.scan(context: ScanContext())
        let firstItem = try #require(result.items.first)

        let report = try await module.clean(items: [firstItem], dryRun: true)
        #expect(report.dryRun)
        #expect(FileManager.default.fileExists(atPath: firstItem.path))
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
